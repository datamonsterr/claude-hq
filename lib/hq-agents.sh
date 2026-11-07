#!/usr/bin/env bash
# One metadata walk and one join, regardless of the number of sessions/projects.
load_activity_index() {
  [[ ${ACTIVITY_LOADED:-false} != true ]] || return 0
  local root=${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects index='{}' ids
  ACTIVITY_LOADED=true
  ids=$(jq '[.[].sessionId // empty]' <<<"$ALL_AGENTS")
  if [[ -d $root ]]; then
    # NUL records preserve filename boundaries. Never open transcript contents.
    if ! index=$(external find -P "$root" -mindepth 2 -maxdepth 2 -type f \
        -name '*.jsonl' -printf '%T@\t%f\0' | jq -Rsc --argjson ids "$ids" '
        (reduce $ids[] as $id ({}; .[$id]=true)) as $wanted |
        split("\u0000")|map(capture("^(?<time>[0-9.]+)\\t(?<id>[A-Za-z0-9_-]+)\\.jsonl$")?|
          select($wanted[.id]))|
        reduce .[] as $r ({}; .[$r.id]=([(.[$r.id] // 0),($r.time|tonumber|floor)]|max))'); then
      die 'transcript metadata scan failed; no session actions were taken'
    fi
  fi
  ALL_AGENTS=$(jq --argjson times "$index" '
    map(. + {lastActivity:($times[.sessionId // ""] // ((.startedAt // 0)/1000|floor))})' <<<"$ALL_AGENTS")
}

# Globals below are consumed by hq-capacity.sh.
# shellcheck disable=SC2034
collect_process_memory() {
  local pid key value rest file tag
  CLAUDE_RSS_KB=0
  LIVE_SESSION_COUNT=0; OLD_IDLE_COUNT=0
  while IFS=$'\t' read -r tag pid; do
    case $tag in count) LIVE_SESSION_COUNT=$pid; continue ;; idle) OLD_IDLE_COUNT=$pid; continue ;; esac
    [[ $pid =~ ^[0-9]+$ && $pid -gt 0 ]] || continue
    file=${HQ_PROC_ROOT:-/proc}/$pid/status
    [[ -r $file ]] || continue
    # A process may disappear after agents was queried. Missing status is benign.
    { while read -r key value rest; do
        if [[ $key == VmRSS: ]]; then
          if [[ $value =~ ^[0-9]+$ ]]; then CLAUDE_RSS_KB=$((CLAUDE_RSS_KB+value)); fi
          break
        fi
      done <"$file"
    } 2>/dev/null || true
  done < <(jq -r --argjson now "$NOW" --arg hours "${HQ_INTERACTIVE_HOURS:-72}" '[.[]|
    select(.state!="done" and .state!="completed" and .state!="stopped" and .pid!=null)] as $live |
    "count\t\($live|length)","idle\t\([$live[]|select(.status=="idle" and .lastActivity>0 and ($now-.lastActivity)>(($hours|tonumber)*3600))]|length)",
    ([$live[].pid|select(type=="number")]|unique[]|"pid\t\(.)")' <<<"$ALL_AGENTS")
}
