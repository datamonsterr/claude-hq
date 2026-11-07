#!/usr/bin/env bash
# Transcript mtimes are joined once by load_activity_index; no content is read.

janitor_log() {
  local result=$1 summary=$2 bytes=0
  [[ ! -L $JANITOR_LOG && ! -L $JANITOR_LOG.1 ]] || die 'refusing symlinked janitor log'
  if [[ -f $JANITOR_LOG ]]; then bytes=$(external stat -c %s -- "$JANITOR_LOG"); fi
  if (( bytes >= 1048576 )); then external mv -f -- "$JANITOR_LOG" "$JANITOR_LOG.1"; fi
  printf '%s %s %s\n' "$(external date -u +%FT%TZ)" "$result" "$summary" >>"$JANITOR_LOG"
}

janitor_action() {
  local summary=$1
  shift
  if ! $JANITOR_APPLY; then report_action "$summary" "plan: $summary"; return 0; fi
  janitor_log attempt "$summary"
  if "$@" >>"$JANITOR_LOG" 2>&1; then
    report_action "$summary" "applied: $summary"
    janitor_log applied "$summary"
  else
    report_item failed 'failed actions (kept)' "$summary" '' true
    janitor_log failed "$summary"
    return 1
  fi
}

janitor_signal() {
  local pid=$1
  [[ $pid =~ ^[0-9]+$ && $pid -gt 1 && $pid -ne $$ && $pid -ne $PPID ]] || return 1
  kill -INT "$pid" 2>/dev/null || true
  external sleep 0.2
  kill -INT "$pid" 2>/dev/null || true
}

janitor_remove_session() {
  local id=$1 pid=$2
  if (( pid > 1 )); then janitor_signal "$pid" || return 1; fi
  claude rm "$id"
}

protected_memory() {
  local path=$1
  [[ $path == "$HQ_DIR/memory" || $path == "$HQ_DIR/memory/"* || "$HQ_DIR/memory" == "$path/"* ]]
}

has_live_cwd() {
  local path=$1 cwd
  for cwd in "${LIVE_CWDS[@]}"; do
    [[ $cwd != "$path" && $cwd != "$path/"* ]] || return 0
  done
  return 1
}

session_work_safe() {
  local cwd=$1 row path dirty merged primary known=false top
  local -a status_args=(--porcelain=v1 --untracked-files=all)
  protected_memory "$cwd" && return 1
  top=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) || return 1
  while IFS=$'\t' read -r path dirty merged primary; do
    [[ $top == "$path" ]] || continue
    known=true
    (( dirty == 0 )) || return 1
    [[ $primary == true || $merged == true ]] || return 1
    if [[ $primary != true ]]; then
      status_args+=(--ignored=matching)
      has_live_cwd "$path" && return 1
    fi
  done <<<"$WORKTREE_ROWS"
  $known || return 1
  # Recheck dirty state before claude rm, which may remove its built-in worktree.
  if [[ -d $cwd ]]; then
    if row=$(git -C "$cwd" status "${status_args[@]}" 2>/dev/null); then
      [[ -z $row ]] || return 1
    fi
  fi
}

janitor_sessions() {
  local id sid kind state status pid cwd activity age display
  while IFS=$'\t' read -r id sid kind state status pid cwd activity; do
    (( activity > 0 )) || continue
    age=$((NOW-activity))
    if [[ $kind == background && $state == 'done' && $id != '-' ]] && (( age > DONE_SECONDS )); then
      if session_work_safe "$cwd"; then
        janitor_action "remove done session $id" janitor_remove_session "$id" "$pid" || true
      else report_item protected 'keep dirty/unmerged/protected sessions' "$id"; fi
    elif [[ $kind == background && $state != 'done' && $status != busy && $status != running && $state != busy && $state != working ]] && (( age > IDLE_SECONDS && pid > 1 )); then
      display=$id; [[ $display != '-' ]] || display=$sid
      janitor_action "stop idle background $display (conversation kept)" janitor_signal "$pid" || true
    elif [[ $kind != background && $status == idle ]] && (( age > INTERACTIVE_SECONDS && pid > 1 )); then
      if [[ ${HQ_JANITOR_STOP_INTERACTIVE:-0} == 1 ]]; then
        janitor_action "stop idle interactive $sid (conversation kept)" janitor_signal "$pid" || true
      else report_item interactive "stop idle interactive >${HQ_INTERACTIVE_HOURS:-24}h" \
        "report: idle interactive $sid" ' (report-only; HQ_JANITOR_STOP_INTERACTIVE=1)'; fi
    fi
  done < <(jq -r '.[]|[(.id // "-"),(.sessionId // "-"),(.kind // "unknown"),(.state // "-"),
    (.status // "unknown"),(.pid // 0),(.cwd // ""),.lastActivity]|@tsv' <<<"$ALL_AGENTS")
}

remove_worktree_checked() {
  local repo=$1 path=$2 base=$3 commit=$4 status head recent
  [[ -d $path && ! -L $path ]] || return 1
  protected_memory "$path" && return 1
  has_live_cwd "$path" && return 1
  status=$(git -C "$path" status --porcelain=v1 --untracked-files=all --ignored=matching) || return 1
  [[ -z $status ]] || return 1
  head=$(git -C "$path" rev-parse HEAD) || return 1
  [[ $head == "$commit" ]] || return 1
  git -C "$repo" merge-base --is-ancestor "$head" "$base" || return 1
  recent=$(external find -P "$path" -xdev -newermt "@$WORKTREE_CUTOFF" -print -quit) || return 1
  [[ -z $recent ]] || return 1
  git -C "$repo" worktree remove -- "$path"
}

delete_branch_checked() {
  local repo=$1 branch=$2 base=$3 current default
  current=$(git -C "$repo" symbolic-ref --short -q HEAD || true)
  default=$(git -C "$repo" symbolic-ref -q refs/remotes/origin/HEAD || printf '%s' "$base")
  [[ $branch != "$current" && $branch != "${default#refs/remotes/origin/}" && $default == "$base" ]] || return 1
  git -C "$repo" merge-base --is-ancestor "$branch" "$base" || return 1
  git -C "$repo" branch -d -- "$branch"
}

janitor_worktrees() {
  local repo path base commit branch matched prefix checked wtbranch wtpath key
  local -a prefixes
  local -A removed=() pruned=() occupied=()
  read -r -a prefixes <<<"${HQ_BRANCH_PREFIXES-hq/ so/ claude/ worktree-}"
  while IFS=$'\t' read -r repo wtpath wtbranch; do
    [[ -z $wtbranch ]] || occupied["$repo/$wtbranch"]+="$wtpath"$'\n'
  done < <(jq -r '.[]|. as $p|.worktrees[]|select(.branch!="")|[$p.path,.path,.branch]|@tsv' <<<"$REPO_DATA")
  while IFS=$'\t' read -r repo path base commit; do
    [[ -n $repo && -n $base ]] || continue
    protected_memory "$path" && continue
    has_live_cwd "$path" && { report_item live 'keep live worktrees' "$path"; continue; }
    if janitor_action "remove merged worktree $path" remove_worktree_checked "$repo" "$path" "$base" "$commit"; then
      removed[$path]=1
      if [[ ! ${pruned[$repo]+yes} ]]; then
        janitor_action "prune worktrees $repo" git -C "$repo" worktree prune || true
        pruned[$repo]=1
      fi
    fi
  done < <(jq -r '.[]|. as $p|.worktrees[]|select(.path!=$p.path and .dirty==0 and .merged and (.recent|not))|
    [$p.path,.path,$p.base,.commit]|@tsv' <<<"$REPO_DATA")
  while IFS=$'\t' read -r repo branch base; do
    [[ -n $repo && -n $branch ]] || continue
    matched=false
    for prefix in "${prefixes[@]}"; do [[ $branch != "$prefix"* ]] || matched=true; done
    $matched || continue
    checked=false
    key=$repo/$branch
    while IFS= read -r wtpath; do
      if [[ -n $wtpath && ! ${removed[$wtpath]+yes} ]]; then checked=true; break; fi
    done <<<"${occupied[$key]:-}"
    $checked && continue
    janitor_action "delete merged branch $branch in $repo" delete_branch_checked "$repo" "$branch" "$base" || true
  done < <(jq -r '.[]|. as $p|.mergedBranches[]|
    select(.!=$p.branch and .!=($p.base|sub("^refs/remotes/[^/]+/";"")) and .!="main" and .!="master")|
    [$p.path,.,$p.base]|@tsv' <<<"$REPO_DATA")
}

temp_protected() {
  local path=$1 parent=$1 sid cwd
  protected_memory "$path" && return 0
  has_live_cwd "$path" && return 0
  for cwd in "${LIVE_CWDS[@]}"; do
    [[ $path != "$cwd" && $path != "$cwd/"* ]] || return 0
  done
  for sid in "${LIVE_IDS[@]}"; do
    [[ -n $sid && $path == *"$sid"* ]] && return 0
  done
  # Protect Git work, including repositories outside HQ_ROOTS.
  [[ -d $parent ]] || parent=${parent%/*}
  while [[ $parent != / && -n $parent ]]; do
    [[ ! -e $parent/.git ]] || return 0
    parent=${parent%/*}
  done
  return 1
}

remove_temp_checked() {
  local path=$1 root=$2 cutoff=$3 tree=$4 fresh sid owner stamp device root_device
  [[ $path == "$root/"* && ! -L $path && -e $path ]] || return 1
  temp_protected "$path" && return 1
  device=$(external stat -c %d -- "$path") || return 1
  root_device=$(external stat -c %d -- "$root") || return 1
  [[ $device == "$root_device" ]] || return 1
  owner=$(external stat -c %u -- "$path") || return 1
  [[ $owner == "$EUID" ]] || return 1
  stamp=$(external stat -c %Y -- "$path") || return 1
  (( stamp < cutoff )) || return 1
  if $tree; then
    fresh=$(external find -P "$path" -xdev \( -newermt "@$cutoff" -o ! -uid "$EUID" -o -name .git \) -print -quit) || return 1
    [[ -z $fresh ]] || return 1
    for sid in "${LIVE_IDS[@]}"; do
      fresh=$(external find -P "$path" -xdev -name "*$sid*" -print -quit) || return 1
      [[ -z $fresh ]] || return 1
    done
    external rm -rf --one-file-system -- "$path"
  else
    [[ -f $path ]] || return 1
    external rm -f -- "$path"
  fi
}

janitor_temp() {
  local root=${TMPDIR:-$HOME/.cache/tmp} path cutoff fresh sid keep root_device device
  cutoff=$((NOW-TMP_SECONDS))
  if [[ -d $root && ! -L $root ]]; then
    root=$(cd -P -- "$root" && pwd)
    root_device=$(external stat -c %d -- "$root")
    while IFS= read -r -d '' path; do
      [[ $path == "$root/"* && ! -L $path ]] || continue
      device=$(external stat -c %d -- "$path") || continue
      [[ $device == "$root_device" ]] || continue
      temp_protected "$path" && continue
      keep=false
      fresh=$(external find -P "$path" -xdev \( -newermt "@$cutoff" -o ! -uid "$EUID" -o -name .git \) -print -quit) || continue
      [[ -z $fresh ]] || continue
      for sid in "${LIVE_IDS[@]}"; do
        fresh=$(external find -P "$path" -xdev -name "*$sid*" -print -quit) || { keep=true; break; }
        [[ -z $fresh ]] || { keep=true; break; }
      done
      $keep && continue
      janitor_action "remove stale Claude temp $path" remove_temp_checked "$path" "$root" "$cutoff" true || true
    done < <(external find -P "$root" -xdev -mindepth 1 -type d -uid "$EUID" \
      \( -name 'claude-*' -o -name '*scratchpad*' -o -name 'session-*' \) ! -newermt "@$cutoff" -print0 -prune)
  fi
  disk_sample /tmp
  if [[ $DISK_TYPE == tmpfs ]] && (( DISK_USE > ${HQ_TMP_PRESSURE_PCT:-70} )); then
    cutoff=$((NOW-SYSTEM_TMP_SECONDS))
    while IFS= read -r -d '' path; do
      [[ $path == /tmp/* && ! -L $path ]] || continue
      temp_protected "$path" && continue
      janitor_action "remove old tmpfs file $path" remove_temp_checked "$path" /tmp "$cutoff" false || true
    done < <(external find -P /tmp -xdev -mindepth 1 -type f -uid "$EUID" ! -newermt "@$cutoff" -print0)
  fi
}

janitor() {
  local apply=false verbose=false state_dir settings key
  local -a args=(janitor)
  while (( $# )); do
    case $1 in --apply) apply=true ;; -v|--verbose) verbose=true ;; *) die 'usage: hq janitor [--apply] [-v]' ;; esac
    shift
  done
  for key in flock nice ionice stat find; do need "$key"; done
  if [[ ${HQ_JANITOR_CONTEXT:-0} != 1 ]]; then
    if $apply; then args+=(--apply); fi
    if $verbose; then args+=(-v); fi
    exec timeout --kill-after=5 "${HQ_JANITOR_TIMEOUT:-120}" nice -n 19 ionice -c3 \
      env HQ_JANITOR_CONTEXT=1 "$HQ_DIR/bin/hq" "${args[@]}"
  fi
  JANITOR_APPLY=$apply
  # Consumed by the shared report renderer.
  # shellcheck disable=SC2034
  REPORT_VERBOSE=$verbose
  report_init
  state_dir=${XDG_STATE_HOME:-$HOME/.local/state}/claude-hq
  [[ ! -L $state_dir && ! -L $state_dir/janitor.lock ]] || die 'refusing symlinked janitor state'
  external mkdir -p -- "$state_dir"
  exec 9>"$state_dir/janitor.lock"
  if ! external flock -n 9; then printf 'janitor: another run holds the lock\n'; return 0; fi
  JANITOR_LOG=$state_dir/janitor.log
  settings=$(jq -nr --arg 'done' "${HQ_DONE_HOURS:-2}" --arg idle "${HQ_IDLE_HOURS:-12}" \
    --arg interactive "${HQ_INTERACTIVE_HOURS:-24}" --arg worktree "${HQ_WORKTREE_HOURS:-1}" \
    --arg tmp "${HQ_TMP_DAYS:-3}" --arg systemTmp "${HQ_SYSTEM_TMP_DAYS:-2}" '
    [$done,$idle,$interactive,$worktree,$tmp,$systemTmp]|map(tonumber)|
    if any(.[]; .<0) then error("janitor ages must be nonnegative") else
    [.[0]*3600,.[1]*3600,.[2]*3600,.[3]*3600,.[4]*86400,.[5]*86400]|map(floor)|@tsv end')
  read -r DONE_SECONDS IDLE_SECONDS INTERACTIVE_SECONDS key TMP_SECONDS SYSTEM_TMP_SECONDS <<<"$settings"
  WORKTREE_CUTOFF=$((NOW-key))
  load_agents all
  load_activity_index
  discover; scan_repos
  mapfile -t LIVE_CWDS < <(jq -r '.[]|select(.state!="done" and .state!="completed" and .state!="stopped")|.cwd // empty' <<<"$ALL_AGENTS")
  mapfile -t LIVE_IDS < <(jq -r '.[]|select(.state!="done" and .state!="completed" and .state!="stopped")|(.sessionId // empty),(.id // empty)' <<<"$ALL_AGENTS")
  WORKTREE_ROWS=$(jq -r '.[]|. as $p|.worktrees[]|[.path,.dirty,.merged,(.path==$p.path)]|@tsv' <<<"$REPO_DATA")
  printf 'Janitor %s' "$(if $apply; then printf apply; else printf dry-run; fi)"
  if ! $verbose; then printf ' · up to 3 samples/rule; -v for all'; fi
  printf '\n'
  janitor_sessions
  janitor_worktrees
  janitor_temp
  report_render
}
