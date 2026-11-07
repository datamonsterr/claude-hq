#!/usr/bin/env bash
# Bounded, parallel Git snapshots. Temporary results are discarded after each scan.
scan_repos() {
  [[ -z $REPO_DATA ]] || return 0
  local scan_dir files scan_base=${TMPDIR:-/tmp} scan_seconds=3600
  if [[ -n ${WORKTREE_CUTOFF:-} ]]; then scan_seconds=$((NOW-WORKTREE_CUTOFF)); fi
  if [[ ${HQ_JANITOR_CONTEXT:-0} == 1 && -n ${JANITOR_LOG:-} ]]; then scan_base=${JANITOR_LOG%/*}; fi
  scan_dir=$(external mktemp -d "$scan_base/hq-scan.XXXXXX")
  if [[ $HQ_ACTION == janitor ]]; then
    jq -r '.[]|select(.state!="done" and .state!="completed" and .state!="stopped")|.cwd // empty' <<<"$ALL_AGENTS" >"$scan_dir/live-cwds"
  fi
  if (( ${#REPOS[@]} )); then
    if ! printf '%s\0' "${REPOS[@]}" | HQ_SCAN_MODE=$HQ_ACTION HQ_WORKTREE_SCAN_SECONDS=$scan_seconds external xargs -0 -r -P 4 -n 1 \
        timeout --kill-after=1 5 "$HQ_DIR/bin/hq" _scan-repo "$scan_dir"; then
      printf 'hq: some repository scans failed or exceeded 5s; skipped incomplete snapshots\n' >&2
    fi
  fi
  files=("$scan_dir"/*.json)
  if [[ -f ${files[0]:-} ]]; then
    REPO_DATA=$(jq -s 'sort_by(.name,.path)' "${files[@]}")
  else REPO_DATA='[]'; fi
  external rm -f -- "$scan_dir"/repo.* "$scan_dir/live-cwds"
  external rmdir -- "$scan_dir"
}

repo_row() {
  local output_dir=$1 dir=$2 temp branch='(unborn)' dirty=0 ahead=0 behind=0 stamp age=null base='' field oid=''
  local wt='' wtbranch='' commit='' wt_dirty merged recent status refs='' ref_name ref_commit cwd live
  local mode=${HQ_SCAN_MODE:-cleanup}
  local -a wt_fields=() live_cwds=()
  local -A merged_refs=()
  temp=$(external mktemp "$output_dir/repo.XXXXXX")
  # One status call supplies branch, dirty count and upstream divergence.
  status=$(git -C "$dir" status --porcelain=v2 --branch --ahead-behind --untracked-files=all)
  while IFS= read -r field; do
    case $field in
      '# branch.head '*) branch=${field#\# branch.head } ;;
      '# branch.oid '*) oid=${field#\# branch.oid } ;;
      '# branch.ab '*) read -r ahead behind <<<"${field#\# branch.ab }"; ahead=${ahead#+}; behind=${behind#-} ;;
      '# '*|'') ;;
      *) dirty=$((dirty+1)) ;;
    esac
  done <<<"$status"
  [[ $branch != '(detached)' ]] || branch=${oid:0:7}
  if stamp=$(git -C "$dir" log -1 --format=%ct 2>/dev/null) && [[ -n $stamp ]]; then
    age=$((NOW > stamp ? NOW-stamp : 0))
  fi
  if [[ $mode != projects ]]; then
    base=$(git -C "$dir" symbolic-ref -q refs/remotes/origin/HEAD || true)
    if [[ -z $base && $oid != '(initial)' ]]; then
      if [[ $branch == main || $branch == master ]]; then base=$branch
      else
        for field in main master; do
          if git -C "$dir" show-ref --verify --quiet "refs/heads/$field"; then base=$field; break; fi
        done
      fi
    fi
    if [[ -n $base ]]; then
      refs=$(git -C "$dir" for-each-ref --merged="$base" --format='%(refname:short)%09%(objectname)' refs/heads/)
      while IFS=$'\t' read -r ref_name ref_commit; do
        [[ -z $ref_name ]] || merged_refs[$ref_name]=$ref_commit
      done <<<"$refs"
    fi
    if [[ $mode == janitor && -f $output_dir/live-cwds ]]; then mapfile -t live_cwds <"$output_dir/live-cwds"; fi
    local cutoff
    cutoff=$((NOW-${HQ_WORKTREE_SCAN_SECONDS:-3600}))
    while IFS= read -r -d '' field; do
      case $field in
        'worktree '*) wt=${field#worktree } ;;
        'branch '*) wtbranch=${field#branch refs/heads/} ;;
        'HEAD '*) commit=${field#HEAD } ;;
        '')
          if [[ -n $wt && -d $wt && ! -L $wt ]]; then
            wt_dirty=-1; merged=false; recent=true; live=false
            if [[ $wt == "$dir" ]]; then wt_dirty=$dirty
            else
              if [[ -n $wtbranch && ${merged_refs[$wtbranch]:-} == "$commit" ]]; then merged=true
              elif [[ -z $wtbranch && -n $base ]] && git -C "$dir" merge-base --is-ancestor "$commit" "$base" 2>/dev/null; then merged=true; fi
              for cwd in "${live_cwds[@]}"; do
                if [[ $cwd == "$wt" || $cwd == "$wt/"* ]]; then live=true; break; fi
              done
              if [[ $mode == janitor ]] && $merged && ! $live; then
                if status=$(external find -P "$wt" -xdev -newermt "@$cutoff" -print -quit) && [[ -z $status ]]; then recent=false; fi
              fi
              # Brief only counts metadata candidates. Janitor inspects eligible
              # old, merged, non-live trees; apply still rechecks before deletion.
              if [[ $mode == cleanup || ( $mode == janitor && $merged == true && $recent == false ) ]]; then
                status=$(git -C "$wt" status --porcelain=v1 --untracked-files=all --ignored=matching)
                wt_dirty=0
                while IFS= read -r ref_name; do [[ -z $ref_name ]] || wt_dirty=$((wt_dirty+1)); done <<<"$status"
              fi
            fi
            wt_fields+=("$wt" "$wtbranch" "$commit" "$wt_dirty" "$merged" "$recent")
          fi
          wt=''; wtbranch=''; commit='' ;;
      esac
    done < <(git -C "$dir" worktree list --porcelain -z)
  fi
  { if (( ${#wt_fields[@]} )); then printf '%s\0' "${wt_fields[@]}"; fi; } |
    jq -Rsc --arg name "${dir##*/}" --arg path "$dir" --arg branch "$branch" --arg base "$base" \
      --argjson dirty "$dirty" --argjson ahead "$ahead" --argjson behind "$behind" --argjson age "$age" --arg refs "$refs" '
      (split("\u0000")[:-1]) as $fields |
      {name:$name,path:$path,branch:$branch,base:$base,dirty:$dirty,ahead:$ahead,behind:$behind,lastCommitAgeSeconds:$age,
       worktrees:([range(0;($fields|length);6) as $i|$fields[$i:$i+6]|
         {path:.[0],branch:.[1],commit:.[2],dirty:(.[3]|tonumber),merged:(.[4]=="true"),recent:(.[5]=="true")}]),
       mergedBranches:($refs|split("\n")|map(select(length>0)|split("\t")[0]))}' >"$temp"
  external mv -- "$temp" "$temp.json"
}
