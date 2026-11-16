#!/usr/bin/env bash
# Build-cache and worktree GC. Gated on disk pressure; build caches are never
# touched while a build runs. Deletes only fixed cache paths under the user's
# cache directory, plus clean merged worktrees through the janitor's checks.

gc_human() {
  local kb=${1:-0}
  if (( kb >= 1048576 )); then printf '%d.%dG' $((kb/1048576)) $((kb%1048576*10/1048576))
  else printf '%dM' $((kb/1024)); fi
}

gc_size_kb() {
  local out
  out=$(command timeout --kill-after=1 120 du -sxk -- "$1" 2>/dev/null) || true
  out=${out%%[[:space:]]*}
  printf '%s' "${out:-0}"
}

# Prints matching build commands; exit 0 means a build is running.
gc_active_builds() {
  local bin='(^|[^ ]*/)'
  command pgrep -a -u "$(id -u)" -f -- \
    "${bin}(cargo|rustc)( |$)|${bin}go (build|test|run|install|vet|generate)( |$)|${bin}docker( compose| buildx)? build( |$)|${bin}docker-buildx( |$)"
}

gc_idle() {
  local recent
  recent=$(command timeout --kill-after=1 120 find -P "$1" -xdev -newermt "@$GC_CUTOFF" -print -quit 2>/dev/null) || return 1
  [[ -z $recent ]]
}

gc_remove_dir() {
  local path=$1
  [[ -d $path && ! -L $path && $path == "$GC_CACHE/"* ]] || return 1
  command rm -rf --one-file-system -- "$path"
}

gc_dir() {
  local summary=$1 path=$2 kb
  kb=$(gc_size_kb "$path")
  GC_PLANNED_KB=$((GC_PLANNED_KB+kb))
  janitor_action "$summary $path ($(gc_human "$kb"))" gc_remove_dir "$path" || true
}

gc_caches() {
  local path builds
  if builds=$(gc_active_builds); then
    while IFS= read -r path; do
      [[ -z $path ]] || report_item builds 'skip build caches: build running' "${path:0:120}"
    done <<<"$builds"
    return 0
  fi
  if [[ -d $GC_CACHE/go-build && ! -L $GC_CACHE/go-build ]]; then
    gc_dir 'clear go build cache' "$GC_CACHE/go-build"
  fi
  for path in "$GC_CACHE"/*-target "$GC_CACHE"/tmp/go-build*; do
    [[ -d $path && ! -L $path ]] || continue
    if ! gc_idle "$path"; then
      report_item recent "keep build dirs used <${HQ_GC_IDLE_MINUTES:-60}m" "$path"
    elif [[ $path == "$GC_CACHE"/tmp/* ]]; then gc_dir 'remove stale go temp' "$path"
    else gc_dir 'remove stale build target' "$path"; fi
  done
  if type -P docker >/dev/null && command timeout 10 docker info >/dev/null 2>&1; then
    janitor_action 'docker builder prune -f' command timeout 600 docker builder prune -f || true
    janitor_action 'docker image prune -f (dangling only)' command timeout 600 docker image prune -f || true
  fi
}

gc_worktrees() {
  # Same checks as the janitor (clean, merged, unlocked, idle, no live cwd),
  # including process cwds of non-Claude agents. Skipped while janitor runs.
  HQ_ACTION=janitor
  if ! janitor_state; then report_item janitor 'skip worktrees: janitor running' 'next timer run covers them'; return 0; fi
  janitor_load
  janitor_worktrees
}

gc() {
  local apply=false verbose=false force=false used_before state_dir go_kb=-1 reason
  local -a args=(gc)
  while (( $# )); do
    case $1 in
      --apply) apply=true ;; -v|--verbose) verbose=true ;; --force) force=true ;;
      *) die 'usage: hq gc [--apply] [--force] [-v]' ;;
    esac
    shift
  done
  if [[ ${HQ_JANITOR_CONTEXT:-0} != 1 ]]; then
    if $apply; then args+=(--apply); fi
    if $verbose; then args+=(-v); fi
    if $force; then args+=(--force); fi
    # Leave the caller's cwd so a session-end hook never pins its own worktree.
    cd /
    exec timeout --kill-after=10 "${HQ_GC_TIMEOUT:-900}" nice -n 19 ionice -c3 \
      env HQ_JANITOR_CONTEXT=1 "$HQ_DIR/bin/hq" "${args[@]}"
  fi
  [[ ${HQ_GC_DISK_PCT:-70} =~ ^[0-9]+$ && ${HQ_GC_GO_GB:-10} =~ ^[0-9]+$ && ${HQ_GC_IDLE_MINUTES:-60} =~ ^[0-9]+$ ]] ||
    die 'HQ_GC_DISK_PCT, HQ_GC_GO_GB and HQ_GC_IDLE_MINUTES must be nonnegative integers'
  GC_CACHE=${XDG_CACHE_HOME:-$HOME/.cache}
  [[ ! -L $GC_CACHE ]] || die 'refusing symlinked cache directory'
  GC_CUTOFF=$((NOW-${HQ_GC_IDLE_MINUTES:-60}*60))
  GC_PLANNED_KB=0
  disk_sample /
  if $force; then reason=forced
  elif (( DISK_USE >= ${HQ_GC_DISK_PCT:-70} )); then reason="disk ${DISK_USE}% >= ${HQ_GC_DISK_PCT:-70}%"
  else
    if [[ -d $GC_CACHE/go-build ]]; then go_kb=$(gc_size_kb "$GC_CACHE/go-build"); fi
    if (( go_kb > ${HQ_GC_GO_GB:-10}*1048576 )); then reason="go-build $(gc_human "$go_kb") > ${HQ_GC_GO_GB:-10}G"
    else
      printf 'GC skipped: disk %s%% < %s%%; go-build %s <= %sG\n' "$DISK_USE" "${HQ_GC_DISK_PCT:-70}" \
        "$(if (( go_kb >= 0 )); then gc_human "$go_kb"; else printf none; fi)" "${HQ_GC_GO_GB:-10}"
      return 0
    fi
  fi
  JANITOR_APPLY=$apply
  # Consumed by the shared report renderer.
  # shellcheck disable=SC2034
  REPORT_VERBOSE=$verbose
  report_init
  state_dir=${XDG_STATE_HOME:-$HOME/.local/state}/claude-hq
  [[ ! -L $state_dir && ! -L $state_dir/gc.lock ]] || die 'refusing symlinked gc state'
  external mkdir -p -- "$state_dir"
  JANITOR_LOG=$state_dir/janitor.log
  exec 8>"$state_dir/gc.lock"
  if ! external flock -n 8; then printf 'gc: another run holds the lock\n'; return 0; fi
  used_before=$DISK_USED_KB
  printf 'GC %s · %s' "$(if $apply; then printf apply; else printf dry-run; fi)" "$reason"
  if ! $verbose; then printf ' · up to 3 samples/rule; -v for all'; fi
  printf '\n'
  if $apply; then janitor_log gc "start: $reason"; fi
  gc_caches
  gc_worktrees
  report_render
  if $apply; then
    disk_sample /
    reason="freed $(gc_human $((used_before > DISK_USED_KB ? used_before-DISK_USED_KB : 0))) (disk now ${DISK_USE}%)"
    janitor_log gc "$reason"
    printf 'GC %s\n' "$reason"
  else
    printf 'GC would free about %s from listed directories, plus docker caches\n' "$(gc_human "$GC_PLANNED_KB")"
  fi
}
