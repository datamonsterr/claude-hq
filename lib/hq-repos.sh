#!/usr/bin/env bash
# Bounded, parallel Git snapshots. Temporary results are discarded after each scan.
scan_repos() {
  [[ -z $REPO_DATA ]] || return 0
  local scan_dir files scan_base=${TMPDIR:-/tmp}
  if [[ ${HQ_JANITOR_CONTEXT:-0} == 1 && -n ${JANITOR_LOG:-} ]]; then scan_base=${JANITOR_LOG%/*}; fi
  scan_dir=$(external mktemp -d "$scan_base/hq-scan.XXXXXX")
  if (( ${#REPOS[@]} )); then
    if ! printf '%s\0' "${REPOS[@]}" | external xargs -0 -r -P 4 -n 1 \
        timeout --kill-after=1 5 "$HQ_DIR/bin/hq" _scan-repo "$scan_dir"; then
      printf 'hq: some repository scans failed or exceeded 5s; skipped incomplete snapshots\n' >&2
    fi
  fi
  files=("$scan_dir"/*.json)
  if [[ -f ${files[0]:-} ]]; then
    REPO_DATA=$(jq -s 'sort_by(.name,.path)' "${files[@]}")
  else REPO_DATA='[]'; fi
  external rm -f -- "$scan_dir"/repo.*
  external rmdir -- "$scan_dir"
}

repo_row() {
  local output_dir=$1 dir=$2 temp branch dirty ahead=0 behind=0 counts stamp age=null base field
  local wt='' wtbranch='' commit='' wt_dirty merged recent worktrees='' branches='[]' status cutoff
  temp=$(external mktemp "$output_dir/repo.XXXXXX")
  branch=$(git -C "$dir" symbolic-ref --short -q HEAD || git -C "$dir" rev-parse --short HEAD 2>/dev/null || printf '(unborn)')
  status=$(git -C "$dir" status --porcelain=v1 --untracked-files=all)
  dirty=0
  while IFS= read -r field; do [[ -z $field ]] || dirty=$((dirty+1)); done <<<"$status"
  if counts=$(git -C "$dir" rev-list --left-right --count 'HEAD...@{upstream}' 2>/dev/null); then
    read -r ahead behind <<<"$counts"
  fi
  if stamp=$(git -C "$dir" log -1 --format=%ct 2>/dev/null) && [[ -n $stamp ]]; then
    age=$((NOW > stamp ? NOW-stamp : 0))
  fi
  base=$(git -C "$dir" symbolic-ref -q refs/remotes/origin/HEAD || true)
  if [[ -z $base ]]; then
    for field in main master; do
      if git -C "$dir" rev-parse --verify "$field^{commit}" >/dev/null 2>&1; then base=$field; break; fi
    done
  fi
  cutoff=$(jq -nr --argjson now "$NOW" --arg hours "${HQ_WORKTREE_HOURS:-1}" '$now-($hours|tonumber)*3600')
  while IFS= read -r -d '' field; do
    case $field in
      'worktree '*) wt=${field#worktree } ;;
      'branch '*) wtbranch=${field#branch refs/heads/} ;;
      'HEAD '*) commit=${field#HEAD } ;;
      '')
        if [[ -n $wt && -d $wt && ! -L $wt ]]; then
          wt_dirty=$dirty; merged=false; recent=true
          if [[ $wt != "$dir" ]]; then
            status=$(git -C "$wt" status --porcelain=v1 --untracked-files=all --ignored=matching)
            wt_dirty=0
            while IFS= read -r counts; do [[ -z $counts ]] || wt_dirty=$((wt_dirty+1)); done <<<"$status"
            if [[ -n $base && -n $commit ]] && git -C "$dir" merge-base --is-ancestor "$commit" "$base" 2>/dev/null; then merged=true; fi
            # -P and -xdev neither follow symlinks nor cross nested mounts.
            if status=$(external find -P "$wt" -xdev -newermt "@$cutoff" -print -quit); then
              [[ -n $status ]] || recent=false
            fi
          fi
          worktrees+=$(jq -cn --arg path "$wt" --arg branch "$wtbranch" --arg commit "$commit" \
            --argjson dirty "$wt_dirty" --argjson merged "$merged" --argjson recent "$recent" \
            '{path:$path,branch:$branch,commit:$commit,dirty:$dirty,merged:$merged,recent:$recent}')$'\n'
        fi
        wt=''; wtbranch=''; commit='' ;;
    esac
  done < <(git -C "$dir" worktree list --porcelain -z)
  if [[ -n $base ]]; then
    branches=$(git -C "$dir" for-each-ref --merged="$base" --format='%(refname:short)' refs/heads/ |
      jq -Rsc 'split("\n")|map(select(length>0))')
  fi
  jq -cn --arg name "${dir##*/}" --arg path "$dir" --arg branch "$branch" --arg base "$base" \
    --argjson dirty "$dirty" --argjson ahead "$ahead" --argjson behind "$behind" --argjson age "$age" \
    --argjson worktrees "$(jq -s '.' <<<"$worktrees")" --argjson branches "$branches" \
    '{name:$name,path:$path,branch:$branch,base:$base,dirty:$dirty,ahead:$ahead,behind:$behind,
      lastCommitAgeSeconds:$age,worktrees:$worktrees,mergedBranches:$branches}' >"$temp"
  external mv -- "$temp" "$temp.json"
}
