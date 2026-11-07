#!/usr/bin/env bash
disk_sample() {
  local path=$1 output line
  DISK_USE=-1; DISK_TYPE=unknown
  if output=$(external df -PT -- "$path" 2>/dev/null); then
    while IFS= read -r line; do
      local -a fields
      read -r -a fields <<<"$line"
      if [[ ${fields[5]:-} =~ ^[0-9]+%$ ]]; then
        DISK_USE=${fields[5]%\%}; DISK_TYPE=${fields[1]}
      fi
    done <<<"$output"
  fi
}

collect_capacity() {
  local key kb rest mem=-1 load=-1 cores disk=-1 tmp=0 unknown=false target
  load_activity_index
  collect_process_memory
  if [[ -r ${HQ_MEMINFO_FILE:-/proc/meminfo} ]]; then
    while read -r key kb rest; do
      if [[ $key == MemAvailable: && $kb =~ ^[0-9]+$ ]]; then mem=$((kb/1024)); break; fi
    done <"${HQ_MEMINFO_FILE:-/proc/meminfo}"
  fi
  if [[ -r ${HQ_LOADAVG_FILE:-/proc/loadavg} ]]; then
    read -r load rest <"${HQ_LOADAVG_FILE:-/proc/loadavg}" || load=-1
  fi
  cores=$(external nproc 2>/dev/null) || cores=0
  [[ $cores =~ ^[1-9][0-9]*$ ]] || cores=0
  for target in / "$HOME"; do
    disk_sample "$target"
    if (( DISK_USE < 0 )); then unknown=true; elif (( DISK_USE > disk )); then disk=$DISK_USE; fi
  done
  for target in /tmp "${TMPDIR:-$HOME/.cache/tmp}"; do
    # A not-yet-created default scratch directory lives on HOME's filesystem.
    [[ -d $target ]] || target=$HOME
    disk_sample "$target"
    if (( DISK_USE < 0 )); then unknown=true
    elif [[ $DISK_TYPE == tmpfs ]] && (( DISK_USE > tmp )); then tmp=$DISK_USE; fi
  done
  CAPACITY_JSON=$(jq -cn --argjson sessions "$LIVE_SESSION_COUNT" --argjson idle "$OLD_IDLE_COUNT" \
    --argjson rss "$CLAUDE_RSS_KB" --arg idleHours "${HQ_INTERACTIVE_HOURS:-72}" --arg max "${HQ_MAX_SESSIONS:-40}" \
    --argjson mem "$mem" --arg min "${HQ_MIN_MEM_MB:-3072}" --arg load "$load" --argjson cores "$cores" \
    --arg maxLoad "${HQ_MAX_LOAD:-1.5}" --argjson disk "$disk" --argjson tmp "$tmp" --argjson unknown "$unknown" '
    ($max|tonumber) as $max | ($min|tonumber) as $min | ($maxLoad|tonumber) as $maxLoad |
    (try ($load|tonumber) catch -1) as $load |
    (if $cores>0 then $load/$cores else -1 end) as $perCore |
    {sessions:$sessions,maxSessions:$max,idleOverThreshold:$idle,idleHours:($idleHours|tonumber),rssKB:$rss,memoryMB:$mem,loadPerCore:$perCore,disk:$disk,tmp:$tmp,
      reasons:([if $sessions >= $max then "sessions \($sessions)/\($max) (\($idle) idle>\($idleHours)h); run hq janitor to review cleanup" else empty end,
        if $mem<0 then "memory availability unknown" elif $mem<$min then "memory \($mem)MB available, minimum \($min)MB" else empty end,
        if $perCore<0 then "load unavailable" elif $perCore>$maxLoad then "load \($perCore)/core exceeds \($maxLoad)" else empty end,
        if $unknown or $disk<0 then "disk usage unavailable" elif $disk>=90 then "disk \($disk)% (limit <90%)" else empty end,
        if $tmp>=80 then "tmpfs \($tmp)% (limit <80%)" else empty end])}')
}

capacity_line() {
  jq -r '"sessions \(.sessions)/\(.maxSessions) (\((.rssKB/1048576*10|round)/10)G rss, \(.idleOverThreshold) idle>\(.idleHours)h) · mem \(if .memoryMB<0 then "?" else ((.memoryMB/1024|floor)|tostring)+"G" end) avail · load \(if .loadPerCore<0 then "?" else ((.loadPerCore*100|round)/100|tostring) end)/core · disk \(.disk)% · tmp \(.tmp)%"' <<<"$CAPACITY_JSON"
}
