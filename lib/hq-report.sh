#!/usr/bin/env bash
# Bounded samples in stdout; --apply always logs every full action separately.
report_init() {
  REPORT_ORDER=()
  declare -gA REPORT_COUNT=() REPORT_SAMPLES=() REPORT_LABEL=() REPORT_NOTE=()
}

report_item() {
  local rule=$1 label=$2 detail=$3 note=${4:-} logged=${5:-false} count
  if [[ ${JANITOR_APPLY:-false} == true && $logged != true ]]; then janitor_log report "$detail"; fi
  if [[ ! ${REPORT_COUNT[$rule]+yes} ]]; then
    REPORT_ORDER+=("$rule")
    REPORT_COUNT[$rule]=0
    REPORT_SAMPLES[$rule]=''
    REPORT_LABEL[$rule]=$label
    REPORT_NOTE[$rule]=$note
  fi
  count=$((REPORT_COUNT[$rule]+1))
  REPORT_COUNT[$rule]=$count
  if [[ ${REPORT_VERBOSE:-false} == true ]] || (( count <= 3 )); then
    REPORT_SAMPLES[$rule]+="  $detail"$'\n'
  fi
}

report_render() {
  local rule
  for rule in "${REPORT_ORDER[@]}"; do
    printf '%s: %s%s\n' "${REPORT_LABEL[$rule]}" "${REPORT_COUNT[$rule]}" "${REPORT_NOTE[$rule]}"
    printf '%s' "${REPORT_SAMPLES[$rule]}"
  done
}

report_action() {
  local summary=$1 detail=$2 rule label
  case $summary in
    'remove done session '*) rule='done'; label="remove done background sessions >${HQ_DONE_HOURS:-2}h" ;;
    'stop idle background '*) rule=background; label="stop idle background >${HQ_IDLE_HOURS:-12}h (conversation kept)" ;;
    'stop idle interactive '*) rule=interactive; label="stop idle interactive >${HQ_INTERACTIVE_HOURS:-72}h" ;;
    'remove merged worktree '*) rule=worktrees; label='remove merged worktrees' ;;
    'prune worktrees '*) rule=prune; label='prune worktree metadata' ;;
    'delete merged branch '*) rule=branches; label='delete merged branches' ;;
    'remove stale Claude temp '*) rule=scratch; label='remove stale Claude temp directories' ;;
    'remove old tmpfs file '*) rule=tmpfs; label='remove old tmpfs files' ;;
    'trim go build cache '*) rule=gotrim; label="trim Go build cache entries unused >${HQ_GC_GO_AGE_H:-24}h" ;;
    'clear go build cache '*) rule=gocache; label="clear Go build cache (over ${HQ_GC_GO_GB:-10}G after trim)" ;;
    'remove stale build target '*) rule=targets; label="remove build targets idle >${HQ_GC_IDLE_MINUTES:-60}m" ;;
    'remove stale go temp '*) rule=gotmp; label="remove Go temp dirs idle >${HQ_GC_IDLE_MINUTES:-60}m" ;;
    'docker '*) rule=docker; label='docker prune (build cache, dangling images; never volumes)' ;;
    *) rule=other; label='other actions' ;;
  esac
  report_item "$rule" "$label" "$detail" '' true
}
