#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
fixture=$(mktemp -d /tmp/claude-hq-tests.XXXXXX)
trap 'rm -rf -- "$fixture"' EXIT
export HOME=$fixture/home
export XDG_CONFIG_HOME=$HOME/.config
export XDG_STATE_HOME=$HOME/.local/state
export XDG_CACHE_HOME=$HOME/.cache
export TMPDIR=$fixture/tmp
export CLAUDE_CONFIG_DIR=$HOME/.claude
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export HQ_ROOTS=$HOME/dev:$HOME/other
export BESZEL_URL='' BESZEL_EMAIL='' BESZEL_PASSWORD=''
# Legacy report fixtures opt out; the dedicated default-policy case unsets this.
export HQ_JANITOR_STOP_INTERACTIVE=0
unset HQ_INTERACTIVE_HOURS
export CALL_LOG=$fixture/claude-calls.jsonl CURL_LOG=$fixture/curl-calls.jsonl
export AGENTS_FILE=$fixture/agents.json
export SYSTEMS_FILE=$fixture/systems.json ALERTS_FILE=$fixture/alerts.json
export SIGNAL_LOG=$fixture/signals
export HQ_TEST_REPO_ROOT=$repo
export HQ_MEMINFO_FILE=$fixture/meminfo HQ_LOADAVG_FILE=$fixture/loadavg
export HQ_PROC_ROOT=$fixture/proc FIND_LOG=$fixture/find-calls
mkdir -p "$HQ_PROC_ROOT/999999" "$HQ_PROC_ROOT/999998" "$HQ_PROC_ROOT/999994"
printf 'Name:\tfixture\nVmRSS:\t1048576 kB\n' >"$HQ_PROC_ROOT/999999/status"
printf 'VmRSS:\t2621440 kB\n' >"$HQ_PROC_ROOT/999998/status"
printf 'VmRSS:\tunknown kB\n' >"$HQ_PROC_ROOT/999994/status"
: >"$FIND_LOG"
printf 'MemAvailable: 16777216 kB\n' >"$HQ_MEMINFO_FILE"
printf '0.4 0.3 0.2 1/20 1\n' >"$HQ_LOADAVG_FILE"
mkdir -p "$HOME/dev" "$HOME/other" "$fixture/stubs" "$TMPDIR" "$fixture/system-tmp"
export PATH=$fixture/stubs:$PATH
# Tests never invoke a real Claude command or access the network.
cat >"$fixture/stubs/claude" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
jq -cn --arg cwd "$PWD" --args '{cwd:$cwd,args:$ARGS.positional}' -- "$@" >>"$CALL_LOG"
case ${1:-} in
  agents)
    [[ ${AGENTS_FAIL:-0} != 1 ]] || exit 1
    if [[ " $* " == *' --all '* ]]; then cat "$AGENTS_FILE";
    else jq '[.[]|select(.state != "done" and .state != "completed")]' "$AGENTS_FILE"; fi ;;
  --bg)
    if [[ ${SPAWN_TRUST:-0} == 1 ]]; then printf 'Workspace not trusted. Trust this workspace first.\n'; exit 3; fi
    printf 'Remote Control: https://claude.ai/code/session_fixture\nbackgrounded · abc123\n' ;;
  rm) printf 'Removed %s\n' "$2" ;;
  *) printf 'Unexpected Claude invocation\n' >&2; exit 90 ;;
esac
STUB
cat >"$fixture/stubs/curl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
jq -cn --args '$ARGS.positional' -- "$@" >>"$CURL_LOG"
[[ ${CURL_FAIL:-0} != 1 ]] || exit 22
case " $* " in
  */users/auth-with-password*)
    body=$(cat)
    jq -e 'has("identity") and has("password")' <<<"$body" >/dev/null
    printf '{"token":"fixture-token"}\n' ;;
  */systems/records*)
    [[ " $* " == *' Authorization: fixture-token '* ]] || exit 91
    if [[ ${PAGINATE:-0} == 1 && " $* " != *' page=2 '* ]]; then
      jq '{items:.items[0:1],totalPages:2}' "$SYSTEMS_FILE"
    elif [[ ${PAGINATE:-0} == 1 ]]; then jq '{items:.items[1:],totalPages:2}' "$SYSTEMS_FILE"
    else cat "$SYSTEMS_FILE"; fi ;;
  */alerts/records*)
    [[ " $* " == *' filter=triggered=true '* ]] || exit 92
    cat "$ALERTS_FILE" ;;
  *) printf 'Unexpected network request\n' >&2; exit 93 ;;
esac
STUB
cat >"$fixture/stubs/df" <<'STUB'
#!/usr/bin/env bash
if [[ " $* " == *' -PT '* ]]; then
  target=${*: -1}
  kind=ext4; pct=${DISK_PCT:-20}
  [[ $target != / ]] || pct=${ROOT_DISK_PCT:-$pct}
  [[ $target != "$HOME" ]] || pct=${HOME_DISK_PCT:-$pct}
  if [[ $target == /tmp ]]; then kind=${TMP_FS:-tmpfs}; pct=${SYSTEM_TMP_PCT:-${TMP_PCT:-20}};
  elif [[ $target == "${TMPDIR:-$HOME/.cache/tmp}" ]]; then kind=${TMP_FS:-tmpfs}; pct=${CUSTOM_TMP_PCT:-${TMP_PCT:-20}}; fi
  printf 'Filesystem Type 1024-blocks Used Available Capacity Mounted on\n'
  printf 'fixture %s 100 20 80 %s%% /\n' "$kind" "$pct"
  exit 0
fi
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf 'fixture 100 20 80 %s%% /\n' "${DISK_PCT:-20}"
STUB
cat >"$fixture/stubs/nproc" <<'STUB'
#!/usr/bin/env bash
printf '1\n'
STUB
REAL_FIND=$(type -P find); REAL_NICE=$(type -P nice); REAL_IONICE=$(type -P ionice)
REAL_TIMEOUT=$(type -P timeout)
export REAL_FIND REAL_NICE REAL_IONICE REAL_TIMEOUT SYSTEM_TMP_FIXTURE=$fixture/system-tmp
export SCHED_LOG=$fixture/scheduling TIMEOUT_LOG=$fixture/timeouts
cat >"$fixture/stubs/find" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FIND_LOG"
args=("$@")
for i in "${!args[@]}"; do
  if [[ ${args[$i]} == /tmp ]]; then args[$i]=$SYSTEM_TMP_FIXTURE; break; fi
done
exec "$REAL_FIND" "${args[@]}"
STUB
cat >"$fixture/stubs/nice" <<'STUB'
#!/usr/bin/env bash
printf 'nice %s\n' "$*" >>"$SCHED_LOG"
exec "$REAL_NICE" "$@"
STUB
cat >"$fixture/stubs/ionice" <<'STUB'
#!/usr/bin/env bash
printf 'ionice %s\n' "$*" >>"$SCHED_LOG"
exec "$REAL_IONICE" "$@"
STUB
cat >"$fixture/stubs/timeout" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TIMEOUT_LOG"
if [[ ${TRACE_ANCESTORS:-0} == 1 && ! -f $HQ_PROC_ROOT/$$/status ]]; then
  mkdir -p "$HQ_PROC_ROOT/$$"
  printf 'PPid:\t%s\n' "$PPID" >"$HQ_PROC_ROOT/$$/status"
fi
if [[ ${FAIL_REPO_SCAN:-0} == 1 && " $* " == *' _scan-repo '* ]]; then exit 124; fi
exec "$REAL_TIMEOUT" "$@"
STUB
cat >"$fixture/stubs/systemctl" <<'STUB'
#!/usr/bin/env bash
[[ ${SYSTEMCTL_FAIL:-0} != 1 ]] || exit 1
if [[ ${FAILED_UNITS:-0} == 1 ]]; then printf 'fixture.service loaded failed failed Fixture\n'; fi
exit 0
STUB
export DOCKER_LOG=$fixture/docker-calls
: >"$DOCKER_LOG"
cat >"$fixture/stubs/ps" <<'STUB'
#!/usr/bin/env bash
[[ -z ${PS_ROWS:-} ]] || printf '%s\n' "$PS_ROWS"
STUB
cat >"$fixture/stubs/pgrep" <<'STUB'
#!/usr/bin/env bash
[[ -n ${BUILD_PROCS:-} ]] || exit 1
printf '%s\n' "$BUILD_PROCS"
STUB
cat >"$fixture/stubs/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$DOCKER_LOG"
[[ ${DOCKER_DOWN:-0} != 1 ]] || exit 1
[[ $1 != info ]] || exit 0
printf 'Total reclaimed space: 0B\n'
STUB
cat >"$fixture/stubs/hq" <<'STUB'
#!/usr/bin/env bash
exec "$HQ_TEST_REPO_ROOT/bin/hq" "$@"
STUB
chmod +x "$fixture/stubs/"*
# Bash kill is a builtin; override it only inside the fixture's child shells.
kill() { printf '%s\n' "$*" >>"$SIGNAL_LOG"; }
export -f kill

tests=0
ok() { tests=$((tests+1)); printf 'ok %s - %s\n' "$tests" "$1"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
contains() { [[ $1 == *"$2"* ]] || fail "missing output: $2"; }
assert_json() { jq -e "$2" <<<"$1" >/dev/null || fail "$3"; }
hq() { "$repo/bin/hq" "$@"; }
init_repo() {
  git init -q -b main "$1"
  git -C "$1" -c user.name=Fixture -c user.email=fixture.invalid commit -q --allow-empty -m init
}

init_repo "$HOME/dev/alpha"
init_repo "$HOME/dev/alpha-more"
init_repo "$HOME/dev/space project"
init_repo "$HOME/dev/skip-worktrees"
init_repo "$HOME/other/beta"
git -C "$HOME/dev/alpha" branch merged-topic
git -C "$HOME/dev/alpha" worktree add -q "$HOME/dev/skip-worktrees/alpha-merged" merged-topic
git -C "$HOME/dev/alpha" update-ref refs/remotes/fixture/main HEAD
git -C "$HOME/dev/alpha" config branch.main.remote fixture
git -C "$HOME/dev/alpha" config branch.main.merge refs/heads/main
git -C "$HOME/dev/alpha" config remote.fixture.fetch '+refs/heads/*:refs/remotes/fixture/*'
git -C "$HOME/dev/alpha" -c user.name=Fixture -c user.email=fixture.invalid commit -q --allow-empty -m ahead
printf 'dirty\n' >"$HOME/dev/alpha/untracked"
now=$(date +%s)
jq -n --arg root "$HOME/dev" --argjson now "$now" '[
  {pid:999999,id:"live1",cwd:($root+"/alpha"),kind:"background",startedAt:(($now-3600)*1000),sessionId:"session-live",name:"alpha task",status:"running",state:"working"},
  {pid:999998,id:"idle1",cwd:($root+"/alpha/.claude/worktrees/topic"),kind:"background",startedAt:(($now-90000)*1000),sessionId:"session-idle",name:"idle task",status:"idle",state:"waiting"},
  {id:"done1",cwd:($root+"/alpha"),kind:"background",startedAt:(($now-90000)*1000),sessionId:"session-done",name:"done task",status:"idle",state:"done"},
  {pid:999997,id:"neighbor",cwd:($root+"/alpha-more"),kind:"background",startedAt:($now*1000),sessionId:"session-neighbor",name:"neighbor task",status:"running",state:"working"},
  {pid:999996,id:"other",cwd:($root+"/unregistered"),kind:"background",startedAt:($now*1000),sessionId:"session-other",name:"unregistered task",status:"running",state:"working"},
  {pid:999995,cwd:($root+"/alpha"),kind:"interactive",startedAt:(($now-3600)*1000),sessionId:"12345678-recent",name:"recent interactive",status:"idle"},
  {pid:999994,cwd:($root+"/alpha"),kind:"interactive",startedAt:(($now-90000)*1000),sessionId:"87654321-older",name:"older interactive",status:"idle"},
  {pid:999993,cwd:($root+"/alpha"),kind:"interactive",startedAt:(($now-90000)*1000),sessionId:"feedface-busy",name:"busy interactive",status:"running"}
]' >"$AGENTS_FILE"
cat >"$SYSTEMS_FILE" <<'JSON'
{"items":[
  {"id":"system-one","name":"Fixture one","status":"up","info":{"cpu":12,"mp":25,"dp":30}},
  {"id":"system-two","name":"Fixture two","status":"down","info":{"cpu":94,"mp":86,"dp":87}}
],"totalPages":1}
JSON
cat >"$ALERTS_FILE" <<'JSON'
{"items":[
  {"id":"alert-one","system":"system-two","name":"CPU","value":90,"triggered":true},
  {"id":"alert-two","system":"system-one","name":"Disk","value":85,"triggered":false}
],"totalPages":1}
JSON

out=$(hq projects --json)
assert_json "$out" 'length==4 and ([.[].name]|index("skip-worktrees")|not)' 'project discovery / skipped worktree root'
assert_json "$out" '.[]|select(.name=="alpha")|.dirty==1 and .ahead==1 and .behind==0 and .liveSessions==3 and .branch=="main"' 'project status and idle-aware live count'
contains "$(hq projects)" 'AHEAD/BEHIND'
assert_json "$(HQ_ROOTS='' hq projects --json)" 'length==3' 'default project root'
assert_json "$(HQ_ROOTS="$HOME/missing" hq projects --json)" 'length==0' 'empty discovery'
ok 'projects: roots, dirty/ahead, worktrees excluded, live session boundary'

# Deliberately literal shell syntax: spawn must pass this as data.
# shellcheck disable=SC2016
prompt='fix the quoted "value" and $(do-not-run) with care'
out=$(hq spawn alpha -n 'Quoted task' -w topic --mode plan -- "$prompt")
contains "$out" 'abc123 · Quoted task'
call=$(tail -1 "$CALL_LOG")
jq -e --arg cwd "$HOME/dev/alpha" --arg prompt "$prompt" '.cwd==$cwd and .args==["--bg","--remote-control","Quoted task","--name","Quoted task","-w","topic","--permission-mode","plan","--",$prompt]' <<<"$call" >/dev/null || fail 'spawn argv'
out=$(hq spawn 'space project' -w -- 'one two three four five six seven eight')
contains "$out" 'space project: one two three four five six'
assert_json "$(tail -1 "$CALL_LOG")" '.args==["--bg","--remote-control","space project: one two three four five six","--name","space project: one two three four five six","-w","--","one two three four five six seven eight"]' 'bare worktree option / six-word title'
if out=$(SPAWN_TRUST=1 hq spawn alpha -- test 2>&1); then fail 'untrusted spawn succeeded'; fi
contains "$out" 'Workspace not trusted'
if hq spawn missing -- test >/dev/null 2>&1; then fail 'unknown project accepted'; fi
ok 'spawn: exact argv, spaces, shell characters, title, worktree, trust diagnostics'

out=$(hq sessions)
contains "$out" 'alpha ('
contains "$out" $'idle1\twaiting\t'
contains "$out" $'12345678\tidle\t'
contains "$out" 'feedface'
contains "$out" '1 older idle hidden, -a to show'
[[ $out != *87654321* && $out != *null* && $out != *'?/idle'* ]] || fail 'interactive display / idle filtering'
contains "$out" '(other)'
[[ $out != *done1* ]] || fail 'completed session leaked without --all'
out=$(hq sessions alpha -a --json)
assert_json "$out" 'length==6 and all(.[];.project=="alpha") and any(.[];.id=="done1") and any(.[];.id=="87654321" and .state=="idle")' 'sessions filtering / --all'
assert_json "$(tail -1 "$CALL_LOG")" '.args==["agents","--json","--all"]' 'built-in --all'
if AGENTS_FAIL=1 hq sessions >/dev/null 2>&1; then fail 'failed agent listing accepted'; fi
ok 'sessions: grouping, filter, status/state, age, completed sessions'

before=$(git -C "$HOME/dev/alpha" status --porcelain=v1)
out=$(hq cleanup --idle-hours 12)
contains "$out" 'report only'
contains "$out" "claude stop 'idle1'"
contains "$out" "claude rm 'done1'"
contains "$out" 'worktree remove'
contains "$out" 'branch -d'
contains "$out" 'dirty entries'
contains "$out" "hq stop '87654321'"
[[ $out != *'claude rm 87654321'* ]] || fail 'interactive cleanup suggested background remove'
[[ $(git -C "$HOME/dev/alpha" status --porcelain=v1) == "$before" ]] || fail 'cleanup modified repository'
git -C "$HOME/dev/alpha" show-ref --verify --quiet refs/heads/merged-topic || fail 'cleanup deleted branch'
[[ -d $HOME/dev/skip-worktrees/alpha-merged ]] || fail 'cleanup removed worktree'
assert_json "$(hq cleanup --idle-hours 100 --json)" 'all(.[];.kind!="session")' 'idle-hours filter'
if hq cleanup --idle-hours nope >/dev/null 2>&1; then fail 'invalid hours accepted'; fi
printf 'keep\n' >"$HOME/dev/skip-worktrees/alpha-merged/dirty"
assert_json "$(hq cleanup --json)" 'any(.[];.kind=="worktree" and (.commands|length)==0)' 'dirty merged worktree preservation'
[[ $(jq -s '[.[]|select(.args[0]!="agents" and .args[0]!="--bg")]|length' "$CALL_LOG") == 0 ]] || fail 'cleanup mutated sessions'
ok 'cleanup: age threshold, exact commands, merged worktrees/branches, no mutations'

out=$(hq stop live1)
contains "$out" 'Removed live1'
[[ $(wc -l <"$SIGNAL_LOG") -eq 2 ]] || fail 'stop did not signal twice'
[[ $(head -1 "$SIGNAL_LOG") == '-INT 999999' ]] || fail 'stop signal'
assert_json "$(tail -1 "$CALL_LOG")" '.args==["rm","live1"]' 'stop built-in remove'
if hq stop missing >/dev/null 2>&1; then fail 'unknown stop id accepted'; fi
contains "$(hq stop done1)" 'Removed done1'
[[ $(wc -l <"$SIGNAL_LOG") -eq 2 ]] || fail 'completed session without pid was signalled'
printf '[{"id":"bad","pid":0,"state":"working"}]\n' >"$fixture/bad-pid.json"
if AGENTS_FILE="$fixture/bad-pid.json" hq stop bad >/dev/null 2>&1; then fail 'unsafe pid accepted'; fi
out=$(hq stop 12345678)
contains "$out" 'claude rm only applies to background ids'
[[ $(wc -l <"$SIGNAL_LOG") -eq 4 && $(tail -1 "$SIGNAL_LOG") == '-INT 999995' ]] || fail 'interactive stop signals'
assert_json "$(tail -1 "$CALL_LOG")" '.args==["agents","--json","--all"]' 'interactive stop must not remove'
jq '[.[]|select(.sessionId=="12345678-recent")]|. + [.[0]+{sessionId:"12345678-collision"}]' "$AGENTS_FILE" >"$fixture/ambiguous-sessions.json"
if AGENTS_FILE="$fixture/ambiguous-sessions.json" hq stop 12345678 >/dev/null 2>&1; then fail 'ambiguous session prefix accepted'; fi
ok 'stop: SIGINT twice then built-in rm, unknown id rejected'

out=$(hq health)
[[ -z $out && ! -f $CURL_LOG ]] || fail 'healthy fallback should be quiet and offline'
out=$(DISK_PCT=90 FAILED_UNITS=1 hq health)
contains "$out" 'disk root: 90%'
contains "$out" 'disk home: 90%'
contains "$out" 'failed units: 1'
contains "$(hq health -v)" 'disk root: 20%'
contains "$(SYSTEMCTL_FAIL=1 hq health)" 'failed units: unavailable'
ok 'health: local fallback, warnings default, verbose, unavailable systemd'

export BESZEL_URL=https://fixture.invalid BESZEL_EMAIL=fixture BESZEL_PASSWORD='fixture-secret'
out=$(hq health)
contains "$out" 'Beszel Fixture two: down cpu 94% mem 86% disk 87%'
contains "$out" 'alert Fixture two: CPU (threshold 90)'
[[ $out != *'Fixture one'* && $out != *fixture-secret* && $out != *fixture-token* ]] || fail 'health filtering or secret output'
out=$(PAGINATE=1 hq health -v --json)
assert_json "$out" '[.[]|select(.kind=="system")]|length==2' 'Beszel pagination'
assert_json "$out" 'any(.[];.kind=="system" and .name=="Fixture one" and .cpu==12 and .memory==25 and .disk==30)' 'Beszel fields'
contains "$(CURL_FAIL=1 hq health)" 'Beszel: unavailable'
assert_json "$(cat "$CURL_LOG" | jq -s '.')" 'any(.[];any(.[];contains("/api/collections/users/auth-with-password")))' 'Beszel users auth endpoint'
ok 'health: Beszel users auth, v0.21 fields, triggered alerts, pagination, failure'

out=$(DISK_PCT=90 FAILED_UNITS=1 hq brief)
[[ $(awk 'END{print NR}' <<<"$out") -le 30 ]] || fail 'brief exceeds 30 lines'
contains "$out" 'sessions alpha: 3 live'
contains "$out" '1 older idle hidden, -a to show'
contains "$(hq brief -a)" 'sessions alpha: 5 live'
contains "$out" 'project alpha: 1 dirty, 1 ahead'
contains "$out" 'Cleanup:'
contains "$out" 'Next:'
contains "$out" 'next settled priority'
jq '.items += [range(0;200)|{system:"system-two",name:"CPU",value:90,triggered:true}]' "$ALERTS_FILE" >"$fixture/many-alerts.json"
out=$(ALERTS_FILE="$fixture/many-alerts.json" hq brief)
[[ $(awk 'END{print NR}' <<<"$out") -le 30 ]] || fail 'busy brief exceeds 30 lines'
contains "$out" 'next settled priority'
hook=$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$repo/hooks/hooks.json")
out=$(CLAUDE_PROJECT_DIR="$repo" CLAUDE_PLUGIN_ROOT="$fixture/missing-plugin-cache" bash -c "$hook")
contains "$out" 'next settled priority'
calls_before=$(wc -l <"$CALL_LOG")
out=$(CLAUDE_PROJECT_DIR="$HOME/dev/alpha" bash -c "$hook" 2>&1)
[[ -z $out && $(wc -l <"$CALL_LOG") == "$calls_before" ]] || fail 'hook ran in child project'
out=$(CLAUDE_PROJECT_DIR='' bash -c "$hook" 2>&1)
[[ -z $out && $(wc -l <"$CALL_LOG") == "$calls_before" ]] || fail 'hook ran with no project root'
ok 'brief: health, live sessions, dirty/ahead, cleanup count, memory Next, <=30 lines'
export BESZEL_URL='' BESZEL_EMAIL='' BESZEL_PASSWORD=''

# Install only into an isolated copy, including settings and memory tests.
checkout=$fixture/checkout
mkdir -p "$checkout/bin" "$checkout/.claude" "$checkout/memory/projects"
cp "$repo/bin/hq" "$checkout/bin/hq"
cp -R "$repo/lib" "$checkout/"
cp "$repo/install.sh" "$repo/config.example.env" "$checkout/"
cp "$repo/memory/MEMORY.md" "$checkout/memory/"
printf '{"permissions":{"allow":["Bash(git status)"]},"extra":"keep"}\n' >"$checkout/.claude/settings.local.json"
mkdir -p "$CLAUDE_CONFIG_DIR"
printf '%s\n' '{"model":"keep","hooks":{"SessionEnd":[{"hooks":[{"type":"command","command":"tkm-hook","args":["--event","session_end"],"timeout":1}]}],"Stop":[{"hooks":[{"type":"command","command":"keep-stop"}]}]}}' >"$CLAUDE_CONFIG_DIR/settings.json"
install_output=$(bash "$checkout/install.sh")
contains "$install_output" 'systemctl --user enable --now claude-hq-janitor.timer'
contains "$install_output" '"cleanupPeriodDays": 14'
contains "$install_output" 'SessionEnd hook runs hq gc --apply'
gc_hook_check='.model=="keep" and .hooks.Stop[0].hooks[0].command=="keep-stop"
  and ([.hooks.SessionEnd[].hooks[]|select(.command=="tkm-hook")]|length==1)
  and ([.hooks.SessionEnd[].hooks[]|select(.command|test("^setsid -f .*/\\.local/bin/hq gc --apply >/dev/null 2>&1 </dev/null$"))|select(.timeout==1)]|length==1)'
jq -e "$gc_hook_check" "$CLAUDE_CONFIG_DIR/settings.json" >/dev/null || fail 'installer did not merge SessionEnd gc hook beside tkm-hook'
[[ -f $XDG_CONFIG_HOME/claude-hq/config.env ]] || fail 'installer did not seed config'
jq -e --arg memory "$checkout/memory" '.autoMemoryDirectory==$memory and .extra=="keep" and .permissions.allow==["Bash(git status)"]' "$checkout/.claude/settings.local.json" >/dev/null || fail 'installer did not merge settings'
[[ -L $HOME/.local/bin/hq && $(readlink "$HOME/.local/bin/hq") == "$checkout/bin/hq" ]] || fail 'installer symlink'
printf '# keep custom configuration\n' >"$XDG_CONFIG_HOME/claude-hq/config.env"
bash "$checkout/install.sh" >/dev/null
[[ $(cat "$XDG_CONFIG_HOME/claude-hq/config.env") == '# keep custom configuration' ]] || fail 'installer overwrote config'
jq -e "$gc_hook_check" "$CLAUDE_CONFIG_DIR/settings.json" >/dev/null || fail 'installer duplicated or dropped SessionEnd hooks on rerun'
# Only the installer may write user Claude settings; later guards expect none.
rm -rf -- "$CLAUDE_CONFIG_DIR"
out=$("$HOME/.local/bin/hq" memory check)
contains "$out" 'within line limits'
for ((i=0;i<81;i++)); do printf 'index entry\n'; done >"$checkout/memory/MEMORY.md"
for ((i=0;i<41;i++)); do printf 'project entry\n'; done >"$checkout/memory/projects/alpha.md"
out=$("$HOME/.local/bin/hq" memory check)
contains "$out" 'MEMORY.md has 81 lines'
contains "$out" 'projects/alpha.md has 41 lines'
ok 'install: fixture HOME, settings merge, symlink resolution, idempotence, memory bounds'

init_repo "$HOME/dev/beta"
if out=$(hq spawn beta -- test 2>&1); then fail 'ambiguous project accepted'; fi
contains "$out" 'ambiguous project'
contains "$(hq spawn "$HOME/other/beta" -- test)" 'abc123 · beta: test'
git init -q -b main "$HOME/dev/unborn"
assert_json "$(hq projects --json)" 'any(.[];.name=="unborn" and .lastCommitAgeSeconds==null)' 'unborn repository'
ok 'edge cases: ambiguous project paths, unborn repository'

[[ ! -e $HOME/.claude ]] || fail 'early tests touched Claude configuration'

expect_refusal() {
  local expected=$1 code=0 output
  shift
  output=$("$@" 2>&1) || code=$?
  [[ $code == 3 ]] || fail "spawn refusal code $code"
  [[ $(awk 'END{print NR}' <<<"$output") == 1 ]] || fail 'spawn refusal must be one line'
  contains "$output" "$expected"
}
contains "$(hq capacity)" 'sessions 7/40 (3.5G rss, 0 idle>72h) · mem 16G avail · load 0.4/core · disk 20% · tmp 20%'
expect_refusal 'sessions 7/7 (0 idle>72h); run hq janitor' env HQ_MAX_SESSIONS=7 "$repo/bin/hq" spawn alpha -- test
expect_refusal 'memory' env HQ_MIN_MEM_MB=20000 "$repo/bin/hq" spawn alpha -- test
expect_refusal 'load' env HQ_MAX_LOAD=0.1 "$repo/bin/hq" spawn alpha -- test
expect_refusal 'disk 90%' env DISK_PCT=90 "$repo/bin/hq" spawn alpha -- test
expect_refusal 'disk 90%' env HOME_DISK_PCT=90 ROOT_DISK_PCT=20 "$repo/bin/hq" spawn alpha -- test
expect_refusal 'tmpfs 80%' env TMP_PCT=80 "$repo/bin/hq" spawn alpha -- test
expect_refusal 'tmpfs 80%' env SYSTEM_TMP_PCT=20 CUSTOM_TMP_PCT=80 "$repo/bin/hq" spawn alpha -- test
contains "$(TMP_FS=ext4 TMP_PCT=99 hq spawn alpha -- test)" 'abc123'
contains "$(HQ_MAX_SESSIONS=1 DISK_PCT=99 hq spawn alpha --force -- test)" 'abc123'
contains "$(HQ_MAX_SESSIONS=8 HQ_MIN_MEM_MB=16384 HQ_MAX_LOAD=0.4 DISK_PCT=89 TMP_PCT=79 hq spawn alpha -- test)" 'abc123'
ok 'capacity: every admission limit, boundaries, one-line exit 3, explicit force'

janitor_root=$HOME/janitor-projects
mkdir -p "$janitor_root"
init_repo "$janitor_root/tools"
printf '.claude/\n' >"$janitor_root/tools/.gitignore"
printf 'base\n' >"$janitor_root/tools/tracked"
git -C "$janitor_root/tools" add .
git -C "$janitor_root/tools" -c user.name=Fixture -c user.email=fixture.invalid commit -qm base
bucket=$janitor_root/tools-worktrees
mkdir -p "$bucket"
for entry in clean dirty unmerged ignored; do
  git -C "$janitor_root/tools" worktree add -q -b "hq/$entry" "$bucket/$entry"
done
printf 'unmerged\n' >"$bucket/unmerged/feature"
git -C "$bucket/unmerged" add feature
git -C "$bucket/unmerged" -c user.name=Fixture -c user.email=fixture.invalid commit -qm feature
printf 'dirty\n' >"$bucket/dirty/untracked"
printf 'cache\n' >>"$janitor_root/tools/.git/info/exclude"
printf 'ignored but valuable\n' >"$bucket/ignored/cache"
for entry in live recent; do
  git -C "$janitor_root/tools" worktree add -q -b "hq/$entry" "$janitor_root/tools/.claude/worktrees/$entry"
done
mkdir -p "$janitor_root/tools/.claude/worktrees/live/subdir"
git -C "$janitor_root/tools" branch hq/orphan
for ((i=1;i<=6;i++)); do git -C "$janitor_root/tools" branch "hq/orphan-$i"; done
git -C "$janitor_root/tools" branch topic/keep
# A committed-and-merged branch exercises the other safe worktree condition.
git -C "$janitor_root/tools" worktree add -q -b so/merged "$bucket/merged"
printf 'merged\n' >"$bucket/merged/merged"
git -C "$bucket/merged" add merged
git -C "$bucket/merged" -c user.name=Fixture -c user.email=fixture.invalid commit -qm merged
git -C "$janitor_root/tools" merge -q --ff-only so/merged
for entry in "$bucket/clean" "$bucket/dirty" "$bucket/unmerged" "$bucket/ignored" "$bucket/merged" "$janitor_root/tools/.claude/worktrees/live"; do
  "$REAL_FIND" -P "$entry" -exec touch -d '3 hours ago' {} +
done
now=$(date +%s)
janitor_agents=$fixture/janitor-agents.json
jq -n --arg root "$janitor_root/tools" --arg bucket "$bucket" --argjson now "$now" '[
 {id:"done-old",pid:999980,sessionId:"done-old-session",kind:"background",state:"done",status:"idle",cwd:$root,startedAt:(($now-18000)*1000)},
 {id:"done-recent",pid:999979,sessionId:"done-recent-session",kind:"background",state:"done",status:"idle",cwd:$root,startedAt:(($now-180000)*1000)},
 {id:"done-dirty",pid:999978,sessionId:"done-dirty-session",kind:"background",state:"done",status:"idle",cwd:($bucket+"/dirty"),startedAt:(($now-18000)*1000)},
 {id:"done-unmerged",pid:999977,sessionId:"done-unmerged-session",kind:"background",state:"done",status:"idle",cwd:($bucket+"/unmerged"),startedAt:(($now-18000)*1000)},
 {id:"idle-old",pid:999976,sessionId:"idle-old-session",kind:"background",state:"idle",status:"idle",cwd:$root,startedAt:(($now-60000)*1000)},
 {id:"waiting-old",pid:999975,sessionId:"waiting-old-session",kind:"background",state:"waiting",status:"idle",cwd:$root,startedAt:(($now-60000)*1000)},
 {id:"busy-old",pid:999974,sessionId:"busy-old-session",kind:"background",state:"working",status:"busy",cwd:$root,startedAt:(($now-180000)*1000)},
 {id:"active-recent",pid:999973,sessionId:"active-recent-session",kind:"background",state:"waiting",status:"idle",cwd:$root,startedAt:(($now-180000)*1000)},
 {id:"idle-recent",pid:999972,sessionId:"idle-recent-session",kind:"background",state:"waiting",status:"idle",cwd:$root,startedAt:(($now-3600)*1000)},
 {pid:999971,sessionId:"interactive-old",kind:"interactive",status:"idle",cwd:$root,startedAt:(($now-360000)*1000)},
 {pid:999970,sessionId:"remote-old",kind:"remote",status:"idle",cwd:$root,startedAt:(($now-360000)*1000)},
 {id:"live-wt",pid:999969,sessionId:"session-live-temp",kind:"background",state:"working",status:"busy",cwd:($root+"/.claude/worktrees/live/subdir"),startedAt:($now*1000)}
]' >"$janitor_agents"
# Contents deliberately are not a transcript; janitor must stat, never parse.
encoded=${janitor_root//[\/.]/-}-tools
mkdir -p "$CLAUDE_CONFIG_DIR/projects/$encoded" "$CLAUDE_CONFIG_DIR/projects/encoding-fallback"
printf 'not transcript JSON\n' >"$CLAUDE_CONFIG_DIR/projects/$encoded/done-recent-session.jsonl"
printf 'not transcript JSON\n' >"$CLAUDE_CONFIG_DIR/projects/encoding-fallback/active-recent-session.jsonl"
mkdir -p "$CLAUDE_CONFIG_DIR/projects/older-copy"
printf 'also not transcript JSON\n' >"$CLAUDE_CONFIG_DIR/projects/older-copy/active-recent-session.jsonl"
touch -d '3 days ago' "$CLAUDE_CONFIG_DIR/projects/older-copy/active-recent-session.jsonl"
for entry in claude-session-stale session-live-temp claude-recent arbitrary-cache claude-container/session-live-temp/scratchpad; do mkdir -p "$TMPDIR/$entry"; done
init_repo "$TMPDIR/claude-nested-git/repo"
printf 'unmerged local data\n' >"$TMPDIR/claude-nested-git/repo/untracked"
printf 'old scratch\n' >"$TMPDIR/claude-session-stale/file"
printf 'keep target\n' >"$fixture/outside-target"
ln -s "$fixture/outside-target" "$TMPDIR/claude-session-stale/link"
ln -s "$fixture/outside-target" "$TMPDIR/claude-link"
for entry in claude-session-stale session-live-temp arbitrary-cache claude-container claude-nested-git; do "$REAL_FIND" -P "$TMPDIR/$entry" -exec touch -h -d '5 days ago' {} +; done
printf 'old\n' >"$SYSTEM_TMP_FIXTURE/old-user-file"
printf 'recent\n' >"$SYSTEM_TMP_FIXTURE/recent-user-file"
touch -d '4 days ago' "$SYSTEM_TMP_FIXTURE/old-user-file"
ln -s "$fixture/outside-target" "$SYSTEM_TMP_FIXTURE/symlink"
init_repo "$SYSTEM_TMP_FIXTURE/git-work"
printf 'keep git data\n' >"$SYSTEM_TMP_FIXTURE/git-work/untracked"
touch -d '4 days ago' "$SYSTEM_TMP_FIXTURE/git-work/untracked"
signals_before=$(wc -l <"$SIGNAL_LOG")
out=$(HQ_ROOTS="$janitor_root" AGENTS_FILE="$janitor_agents" TMP_PCT=75 hq janitor)
contains "$out" 'Janitor dry-run'
contains "$out" 'remove done session done-old'
contains "$out" 'stop idle background idle-old'
contains "$out" 'report: idle interactive interactive-old'
contains "$out" 'remove merged worktree'
contains "$out" 'claude-session-stale'
[[ $out != *'remove done session done-recent'* && $out != *'stop idle background active-recent'* && $out != *'stop idle background busy-old'* ]] || fail 'janitor ignored recent activity or busy state'
[[ $(wc -l <"$SIGNAL_LOG") == "$signals_before" && -d $bucket/clean && -f $TMPDIR/claude-session-stale/file ]] || fail 'dry-run mutated work'
[[ ! -f $XDG_STATE_HOME/claude-hq/janitor.log ]] || fail 'dry-run wrote applied-action log'
contains "$out" 'delete merged branches: 9'
[[ $(awk '/^  plan: delete merged branch / {n++} END{print n+0}' <<<"$out") == 3 ]] || fail 'default janitor exceeded three samples'
verbose=$(HQ_ROOTS="$janitor_root" AGENTS_FILE="$janitor_agents" hq janitor -v)
contains "$verbose" 'delete merged branch hq/orphan-6'
[[ $(awk '/^  plan: delete merged branch / {n++} END{print n+0}' <<<"$verbose") == 9 ]] || fail 'verbose janitor omitted branches'
incomplete=$(HQ_ROOTS="$janitor_root" AGENTS_FILE="$janitor_agents" FAIL_REPO_SCAN=1 hq janitor 2>/dev/null)
[[ $incomplete != *'remove done session'* && $incomplete != *'remove merged worktree'* ]] || fail 'incomplete snapshot authorized deletion'
tuned=$(HQ_ROOTS="$janitor_root" AGENTS_FILE="$janitor_agents" HQ_DONE_HOURS=100 HQ_IDLE_HOURS=100 HQ_WORKTREE_HOURS=100 HQ_TMP_DAYS=100 hq janitor)
[[ $tuned != *'remove done session'* && $tuned != *'stop idle background'* && $tuned != *'remove merged worktree'* && $tuned != *'remove stale Claude temp'* ]] || fail 'janitor threshold tuning ignored'
ok 'janitor dry-run: done, idle, busy, transcript mtime/fallback, interactive report, no mutation'

mkdir -p "$XDG_STATE_HOME/claude-hq"
truncate -s 1048576 "$XDG_STATE_HOME/claude-hq/janitor.log"
out=$(HQ_ROOTS="$janitor_root" AGENTS_FILE="$janitor_agents" TMP_PCT=75 hq janitor --apply)
contains "$out" 'remove done background sessions >2h: 1'
[[ ! -d $bucket/clean && ! -d $bucket/merged ]] || fail 'safe merged worktrees not removed'
[[ -d $bucket/dirty && -f $bucket/dirty/untracked && -d $bucket/unmerged && -d $janitor_root/tools/.claude/worktrees/live && -d $janitor_root/tools/.claude/worktrees/recent ]] || fail 'janitor removed dirty, unmerged, live, or recent worktree'
[[ -f $bucket/ignored/cache ]] || fail 'ignored worktree data removed'
if git -C "$janitor_root/tools" show-ref --verify --quiet refs/heads/hq/orphan; then fail 'merged prefixed branch retained'; fi
git -C "$janitor_root/tools" show-ref --verify --quiet refs/heads/topic/keep || fail 'unapproved branch prefix deleted'
[[ ! -d $TMPDIR/claude-session-stale && ! -f $SYSTEM_TMP_FIXTURE/old-user-file ]] || fail 'stale temp not removed'
[[ -d $TMPDIR/session-live-temp && -d $TMPDIR/claude-container/session-live-temp/scratchpad && -d $TMPDIR/claude-recent && -d $TMPDIR/arbitrary-cache ]] || fail 'janitor removed live, recent, or unrelated temp'
[[ -f $fixture/outside-target && -L $TMPDIR/claude-link && -L $SYSTEM_TMP_FIXTURE/symlink && -f $SYSTEM_TMP_FIXTURE/git-work/untracked && -f $SYSTEM_TMP_FIXTURE/recent-user-file ]] || fail 'symlink, git work, or fresh tmp data damaged'
[[ -f $TMPDIR/claude-nested-git/repo/untracked ]] || fail 'Git work nested in Claude temp removed'
[[ -f $XDG_STATE_HOME/claude-hq/janitor.log.1 ]] || fail 'log did not rotate'
contains "$(cat "$XDG_STATE_HOME/claude-hq/janitor.log")" 'applied remove done session done-old'
contains "$(cat "$XDG_STATE_HOME/claude-hq/janitor.log")" 'Removed done-old'
contains "$(cat "$XDG_STATE_HOME/claude-hq/janitor.log")" 'applied delete merged branch hq/orphan-6'
[[ $out != *'hq/orphan-6'* ]] || fail 'apply stdout was not bounded'
[[ $(jq -s '[.[]|select(.args==["rm","idle-old"] or .args==["rm","waiting-old"])]|length' "$CALL_LOG") == 0 ]] || fail 'idle conversations deleted'
[[ $(rg -c -- '-INT 999976' "$SIGNAL_LOG") == 2 ]] || fail 'idle background not signalled twice'
[[ $(rg -c -- '-INT 999971' "$SIGNAL_LOG" || true) == '' ]] || fail 'interactive stopped by default'
contains "$(cat "$SCHED_LOG")" 'nice -n 19'
contains "$(cat "$SCHED_LOG")" 'ionice -c3'
contains "$(cat "$TIMEOUT_LOG")" '5 git --no-optional-locks'
ok 'janitor apply: safe worktrees/branches, stale temp, negative cases, signals, scheduling, timeouts, log rotation'

jq '[.[]|select(.kind=="interactive" or .kind=="remote")]' "$janitor_agents" >"$fixture/interactive-agents.json"
out=$(HQ_ROOTS="$janitor_root" AGENTS_FILE="$fixture/interactive-agents.json" HQ_JANITOR_STOP_INTERACTIVE=1 hq janitor --apply)
contains "$out" 'stop idle interactive interactive-old'
[[ $(rg -c -- '-INT 999971' "$SIGNAL_LOG") == 2 && $(rg -c -- '-INT 999970' "$SIGNAL_LOG") == 2 ]] || fail 'explicit interactive stop missing'
# A held flock must suppress the entire janitor without querying agents.
exec 8>"$XDG_STATE_HOME/claude-hq/janitor.lock"
flock -n 8
calls_before=$(wc -l <"$CALL_LOG")
contains "$(HQ_ROOTS="$janitor_root" AGENTS_FILE="$janitor_agents" hq janitor --apply)" 'another run holds the lock'
[[ $(wc -l <"$CALL_LOG") == "$calls_before" ]] || fail 'locked janitor queried agents'
exec 8>&-
# The fixture checkout has its own protected memory, even if TMPDIR points there.
mkdir -p "$checkout/memory/session-stale"
printf 'must survive\n' >"$checkout/memory/session-stale/file"
"$REAL_FIND" -P "$checkout/memory/session-stale" -exec touch -d '5 days ago' {} +
HQ_ROOTS="$janitor_root" AGENTS_FILE="$fixture/interactive-agents.json" TMPDIR="$checkout/memory" "$checkout/bin/hq" janitor --apply >/dev/null
[[ -f $checkout/memory/session-stale/file ]] || fail 'HQ memory touched'
ok 'janitor: interactive enable, exclusive lock, HQ memory protected'

# A worktree bucket can be the only project entry under a configured root.
linked_root=$HOME/linked-projects
init_repo "$HOME/linked-main"
mkdir -p "$linked_root/linked-main-worktrees"
git -C "$HOME/linked-main" worktree add -q -b hq/linked "$linked_root/linked-main-worktrees/old"
"$REAL_FIND" -P "$linked_root/linked-main-worktrees/old" -exec touch -d '3 hours ago' {} +
printf '[]\n' >"$fixture/no-agents.json"
out=$(HQ_ROOTS="$linked_root" AGENTS_FILE="$fixture/no-agents.json" hq janitor)
contains "$out" "remove merged worktree $linked_root/linked-main-worktrees/old"
[[ -d $HOME/linked-main/.git ]] || fail 'primary repo damaged'
unknown_root=$HOME/unknown-projects
mkdir -p "$unknown_root"
init_repo "$unknown_root/custom"
git -C "$unknown_root/custom" branch -m main trunk
git -C "$unknown_root/custom" worktree add -q -b hq/unproven "$unknown_root/custom-worktrees/old"
"$REAL_FIND" -P "$unknown_root/custom-worktrees/old" -exec touch -d '3 hours ago' {} +
out=$(HQ_ROOTS="$unknown_root" AGENTS_FILE="$fixture/no-agents.json" hq janitor)
[[ $out != *'remove merged worktree'* && $out != *'delete merged branch'* ]] || fail 'unknown default branch allowed deletion'
mkdir -p "$HOME/.cache/tmp/claude-default-old"
printf 'stale\n' >"$HOME/.cache/tmp/claude-default-old/file"
printf 'outside scratch root\n' >"$HOME/.cache/outside-old"
"$REAL_FIND" -P "$HOME/.cache/tmp/claude-default-old" -exec touch -d '5 days ago' {} +
env -u TMPDIR HQ_ROOTS="$HOME/missing" AGENTS_FILE="$fixture/no-agents.json" "$repo/bin/hq" janitor --apply >/dev/null
[[ ! -e $HOME/.cache/tmp/claude-default-old && -f $HOME/.cache/outside-old ]] || fail 'default TMPDIR cleanup escaped its root'
ok 'janitor: discover sibling worktree buckets through Git metadata'

# Exercise the default without the opt-out used by the legacy report fixtures.
mkdir -p "$fixture/guard-tmp" "$HQ_PROC_ROOT/812345"
printf 'PPid:\t0\n' >"$HQ_PROC_ROOT/812345/status"
ln -s "$repo" "$fixture/hq-alias"
jq -n --arg hq "$repo" --arg alias "$fixture/hq-alias" --arg cwd "$HOME" --argjson now "$(date +%s)" '
 [
 {pid:900110,sessionId:"guard-busy",kind:"interactive",status:"busy",cwd:$cwd,startedAt:(($now-100*3600)*1000)},
 {pid:900111,sessionId:"guard-hq",kind:"interactive",status:"idle",cwd:($hq+"/memory"),startedAt:(($now-100*3600)*1000)},
 {pid:900112,sessionId:"guard-71h",kind:"interactive",status:"idle",cwd:$cwd,startedAt:(($now-71*3600)*1000)},
 {pid:900113,sessionId:"guard-73h",kind:"interactive",status:"idle",cwd:$cwd,startedAt:(($now-73*3600)*1000)},
 {pid:812345,sessionId:"guard-ancestor",kind:"remote",status:"idle",cwd:$cwd,startedAt:(($now-100*3600)*1000)},
 {pid:900115,sessionId:"guard-hq-alias",kind:"interactive",status:"idle",cwd:($alias+"/memory"),startedAt:(($now-100*3600)*1000)},
 {pid:900116,id:"guard-busy-done",sessionId:"guard-busy-done",kind:"background",state:"done",status:"busy",cwd:$cwd,startedAt:(($now-100*3600)*1000)}
 ]' >"$fixture/guard-agents.json"
signals_before=$(wc -l <"$SIGNAL_LOG")
# Expand process ids/environment in the child that becomes the janitor parent.
# shellcheck disable=SC2016
out=$(env -u HQ_JANITOR_STOP_INTERACTIVE TRACE_ANCESTORS=1 HQ_ROOTS="$HOME/missing" AGENTS_FILE="$fixture/guard-agents.json" TMPDIR="$fixture/guard-tmp" bash -c '
  mkdir -p "$HQ_PROC_ROOT/$$"
  printf "PPid:\t812345\n" >"$HQ_PROC_ROOT/$$/status"
  exec "$HQ_TEST_REPO_ROOT/bin/hq" janitor --apply
')
contains "$out" 'stop idle interactive >72h: 1'
[[ $(( $(wc -l <"$SIGNAL_LOG")-signals_before )) == 2 ]] || fail 'protected or 71h session stopped'
[[ $(tail -2 "$SIGNAL_LOG") == $'-INT 900113\n-INT 900113' ]] || fail '73h session did not receive SIGINT twice'
[[ $(jq -s '[.[]|select(.args[0]=="rm" and (.args[1]|startswith("guard-")))]|length' "$CALL_LOG") == 0 ]] || fail 'interactive/busy session removed'
signals_before=$(wc -l <"$SIGNAL_LOG")
out=$(HQ_JANITOR_STOP_INTERACTIVE=0 HQ_ROOTS="$HOME/missing" AGENTS_FILE="$fixture/guard-agents.json" TMPDIR="$fixture/guard-tmp" hq janitor --apply)
contains "$out" '(report-only; HQ_JANITOR_STOP_INTERACTIVE=0)'
[[ $(wc -l <"$SIGNAL_LOG") == "$signals_before" ]] || fail 'interactive opt-out stopped a session'
contains "$(HQ_INTERACTIVE_HOURS=24 hq capacity)" 'idle>24h)'
contains "$(env -u HQ_JANITOR_STOP_INTERACTIVE "$repo/bin/hq" brief)" 'idle interactive >72h stops on --apply'
ok 'interactive default: 73h stopped, 71h/busy/HQ/alias/ancestor kept, opt-out report-only'

stress_root=$HOME/stress-projects
mkdir -p "$stress_root"
for ((i=0;i<20;i++)); do init_repo "$stress_root/p$i"; done
head=$(git -C "$stress_root/p0" rev-parse HEAD)
for ((i=0;i<132;i++)); do printf 'create refs/heads/hq/stress-%03d %s\n' "$i" "$head"; done |
  git -C "$stress_root/p0" update-ref --stdin
# Large directories exercise a single metadata index, without reading contents.
for ((project=0;project<150;project++)); do
  printf -v directory '%s/perf-%03d' "$CLAUDE_CONFIG_DIR/projects" "$project"
  mkdir "$directory"
  for ((slot=0;slot<20;slot++)); do
    sid=perf-$project-$slot
    if (( project<54 && slot==0 )); then sid=stress-idle-$project; fi
    printf 'deliberately invalid transcript contents\n' >"$directory/$sid.jsonl"
  done
done
"$REAL_FIND" -P "$CLAUDE_CONFIG_DIR/projects" -mindepth 2 -maxdepth 2 -type f \
  -path "$CLAUDE_CONFIG_DIR/projects/perf-*/*.jsonl" -exec touch -d '96 hours ago' {} +
jq -n --arg root "$stress_root" --argjson now "$(date +%s)" '[range(0;40)|{id:("stress-"+tostring),sessionId:("stress-session-"+tostring),pid:(900000+.),kind:"background",state:"working",status:"busy",cwd:($root+"/p"+(.%20|tostring)),startedAt:($now*1000)}]' >"$fixture/stress-agents.json"
for action in brief janitor; do
  calls_before=$(jq -s '[.[]|select(.args[0]=="agents")]|length' "$CALL_LOG")
  finds_before=$(awk '/-mindepth 2 -maxdepth 2/ {n++} END{print n+0}' "$FIND_LOG")
  started_ns=$(date +%s%N)
  out=$(HQ_ROOTS="$stress_root" AGENTS_FILE="$fixture/stress-agents.json" hq "$action")
  elapsed_ms=$(( ($(date +%s%N)-started_ns)/1000000 ))
  budget=2000; [[ $action != brief ]] || budget=1500
  [[ $elapsed_ms -lt $budget ]] || fail "$action took ${elapsed_ms}ms (limit ${budget}ms)"
  calls_after=$(jq -s '[.[]|select(.args[0]=="agents")]|length' "$CALL_LOG")
  finds_after=$(awk '/-mindepth 2 -maxdepth 2/ {n++} END{print n+0}' "$FIND_LOG")
  [[ $((calls_after-calls_before)) == 1 && $((finds_after-finds_before)) == 1 ]] || fail "$action did not use one agent query and one transcript index"
  if [[ $action == brief ]]; then
    [[ $(awk 'END{print NR}' <<<"$out") -le 30 ]] || fail 'stress brief exceeds 30 lines'
    contains "$(head -1 <<<"$out")" 'sessions 40/40'
  fi
  printf 'timing: %s %sms (40 sessions, 20 repos, 150x20 transcripts, 132 branches)\n' "$action" "$elapsed_ms"
done
ok 'performance: one agent query/index, brief <1.5s, janitor <2s, brief <=30 lines'

jq -n --arg root "$stress_root" --argjson now "$(date +%s)" '
 [range(0;2)|{id:("busy-"+tostring),sessionId:("busy-session-"+tostring),pid:(900000+.),kind:"background",state:"working",status:"busy",cwd:($root+"/p0"),startedAt:($now*1000)}] +
 [range(0;54)|{sessionId:("stress-idle-"+tostring),pid:(900002+.),kind:"interactive",status:"idle",cwd:($root+"/p0"),startedAt:(($now-96*3600)*1000)}]' >"$fixture/idle-agents.json"
mkdir -p "$HQ_PROC_ROOT/900000" "$HQ_PROC_ROOT/900001"
printf 'VmRSS:\t10485760 kB\n' >"$HQ_PROC_ROOT/900000/status"
printf 'VmRSS:\t3250586 kB\n' >"$HQ_PROC_ROOT/900001/status"
contains "$(HQ_ROOTS="$stress_root" AGENTS_FILE="$fixture/idle-agents.json" hq capacity)" 'sessions 56/40 (13.1G rss, 54 idle>72h)'
expect_refusal '54 idle>72h); run hq janitor' env HQ_ROOTS="$stress_root" AGENTS_FILE="$fixture/idle-agents.json" "$repo/bin/hq" spawn p0 -- test
for action in brief janitor; do
  started_ns=$(date +%s%N)
  out=$(HQ_ROOTS="$stress_root" AGENTS_FILE="$fixture/idle-agents.json" hq "$action")
  elapsed_ms=$(( ($(date +%s%N)-started_ns)/1000000 ))
  budget=2000; [[ $action != brief ]] || budget=1500
  [[ $elapsed_ms -lt $budget ]] || fail "$action with 54 idle sessions took ${elapsed_ms}ms"
  if [[ $action == brief ]]; then [[ $(awk 'END{print NR}' <<<"$out") -le 30 ]] || fail 'idle-heavy brief exceeds 30 lines'; fi
  printf 'timing: %s %sms (56 sessions, 54 older idle, 150x20 transcripts)\n' "$action" "$elapsed_ms"
done
contains "$out" 'stop idle interactive >72h: 54 (report-only; HQ_JANITOR_STOP_INTERACTIVE=0)'
contains "$out" 'delete merged branches: 132'
[[ $(awk '/^  report: idle interactive / {n++} END{print n+0}' <<<"$out") == 3 ]] || fail 'interactive report exceeded three samples'
[[ $(awk '/^  plan: delete merged branch / {n++} END{print n+0}' <<<"$out") == 3 ]] || fail 'branch report exceeded three samples'
[[ $(awk 'END{print NR}' <<<"$out") -le 10 ]] || fail 'janitor default report grew with item count'
verbose=$(HQ_ROOTS="$stress_root" AGENTS_FILE="$fixture/idle-agents.json" hq janitor -v)
[[ $(awk '/^  report: idle interactive / {n++} END{print n+0}' <<<"$verbose") == 54 ]] || fail 'verbose interactive report omitted items'
[[ $(awk '/^  plan: delete merged branch / {n++} END{print n+0}' <<<"$verbose") == 132 ]] || fail 'verbose branch report omitted items'
out=$(HQ_ROOTS="$stress_root" AGENTS_FILE="$fixture/idle-agents.json" hq cleanup)
contains "$out" 'merged branches: 132'
contains "$out" 'old done/idle sessions: 54'
[[ $(awk 'END{print NR}' <<<"$out") -le 10 ]] || fail 'cleanup default report grew with item count'
verbose=$(HQ_ROOTS="$stress_root" AGENTS_FILE="$fixture/idle-agents.json" hq cleanup -v)
contains "$verbose" 'hq/stress-131'
[[ $(awk '/^branch:/ {n++} END{print n+0}' <<<"$verbose") == 132 ]] || fail 'verbose cleanup omitted items'
assert_json "$(HQ_ROOTS="$stress_root" AGENTS_FILE="$fixture/idle-agents.json" hq cleanup --json)" '[.[]|select(.kind=="branch")]|length==132' 'JSON cleanup must retain full details'
mkdir -p "$fixture/report-only-tmp"
signals_before=$(wc -l <"$SIGNAL_LOG")
out=$(HQ_ROOTS="$HOME/missing" AGENTS_FILE="$fixture/idle-agents.json" TMPDIR="$fixture/report-only-tmp" hq janitor --apply)
[[ $out != *'stress-idle-53'* && $(wc -l <"$SIGNAL_LOG") == "$signals_before" ]] || fail 'report-only apply exceeded samples or stopped interactive'
contains "$(cat "$XDG_STATE_HOME/claude-hq/janitor.log")" 'report: idle interactive stress-idle-53'
ok 'reports: 54 idle + 132 branches grouped with <=3 samples, -v/JSON full, RSS and refusal guidance'

# gc: build caches and worktrees under fixture HOME only; docker and pgrep are stubs.
cache=$XDG_CACHE_HOME
[[ $cache == "$fixture"/* ]] || fail "gc tests need a fixture cache, got $cache"
gc_root=$HOME/gc-projects
gc_reset() {
  rm -rf -- "$cache" "$fixture/outside"
  mkdir -p "$cache/go-build/00" "$cache/go-build/01" "$cache/old-target/debug" "$cache/fresh-target" "$cache/tmp/go-build111/b001" \
    "$cache/tmp/go-build222" "$cache/keep" "$fixture/outside/linked-target"
  head -c 8192 /dev/zero >"$cache/go-build/00/entry-d"
  head -c 8192 /dev/zero >"$cache/go-build/01/unused-d"
  touch -d '30 hours ago' "$cache/go-build/01/unused-d"
  printf 'x\n' | tee "$cache/old-target/debug/bin" "$cache/fresh-target/bin" "$cache/tmp/go-build111/b001/a" \
    "$cache/tmp/go-build222/a" "$cache/keep/file" "$fixture/outside/linked-target/file" >/dev/null
  ln -s "$fixture/outside/linked-target" "$cache/linked-target"
  "$REAL_FIND" -P "$cache/old-target" "$cache/tmp/go-build111" "$fixture/outside" -exec touch -h -d '2 hours ago' {} +
  : >"$DOCKER_LOG"
}
gc_untouched() {
  [[ -f $cache/go-build/00/entry-d && -f $cache/go-build/01/unused-d && -d $cache/old-target && -d $cache/tmp/go-build111 ]] || fail "$1"
}
gc_reset
out=$(HQ_ROOTS="$gc_root" ROOT_DISK_PCT=50 hq gc --apply)
contains "$out" 'GC skipped: disk 50% < 70%; go-build'
gc_untouched 'gc below thresholds deleted caches'
[[ ! -s $DOCKER_LOG ]] || fail 'gated gc called docker'
out=$(HQ_ROOTS="$gc_root" ROOT_DISK_PCT=50 HQ_GC_GO_GB=0 hq gc)
contains "$out" 'GC dry-run · go-build'
contains "$out" "plan: trim go build cache $cache/go-build ("
contains "$out" "plan: clear go build cache $cache/go-build"
contains "$out" "plan: remove stale build target $cache/old-target"
contains "$out" "plan: remove stale go temp $cache/tmp/go-build111"
contains "$out" 'plan: docker builder prune -f'
contains "$out" 'plan: docker image prune -f (dangling only)'
contains "$out" "keep build dirs used <60m: 2"
[[ $out != *linked-target* && $out != *"$cache/keep"* ]] || fail 'gc planned a symlinked or non-cache dir'
gc_untouched 'gc dry-run deleted caches'
[[ $(cat "$DOCKER_LOG") == info ]] || fail 'gc dry-run pruned docker'
: >"$DOCKER_LOG"
out=$(HQ_ROOTS="$gc_root" ROOT_DISK_PCT=85 BUILD_PROCS='4242 cargo build --release' hq gc --apply)
contains "$out" 'skip build caches: build running: 1'
contains "$out" '4242 cargo build --release'
gc_untouched 'gc deleted caches during a build'
[[ ! -s $DOCKER_LOG ]] || fail 'gc touched docker during a build'
out=$(HQ_ROOTS="$gc_root" ROOT_DISK_PCT=85 hq gc --apply)
contains "$out" 'GC apply · disk 85% >= 70%'
contains "$out" "applied: trim go build cache $cache/go-build"
[[ $out != *'clear go build cache'* ]] || fail 'gc wiped go-build under the size cap' 
contains "$out" 'GC freed'
[[ -f $cache/go-build/00/entry-d && ! -e $cache/go-build/01/unused-d ]] || fail 'gc did not trim only unused go-build entries'
[[ ! -e $cache/old-target && ! -e $cache/tmp/go-build111 ]] || fail 'gc kept stale caches'
[[ -f $cache/fresh-target/bin && -f $cache/tmp/go-build222/a && -f $cache/keep/file ]] || fail 'gc removed recent or unrelated dirs'
[[ -L $cache/linked-target && -f $fixture/outside/linked-target/file ]] || fail 'gc followed a symlinked target'
[[ $(cat "$DOCKER_LOG") == $'info\nbuilder prune -f\nimage prune -f' ]] || fail "gc docker calls: $(cat "$DOCKER_LOG")"
contains "$(cat "$XDG_STATE_HOME/claude-hq/janitor.log")" 'gc freed'
contains "$(cat "$TIMEOUT_LOG")" '900 nice -n 19 ionice -c3 env HQ_JANITOR_CONTEXT=1'
gc_reset
out=$(HQ_ROOTS="$gc_root" ROOT_DISK_PCT=85 HQ_GC_GO_GB=0 hq gc --apply)
contains "$out" "applied: clear go build cache $cache/go-build"
[[ ! -e $cache/go-build ]] || fail 'gc kept go-build over the size cap after trim'
out=$(PS_ROWS=$'4001 1 90000 99.5 superorchestrator tui --config-dir x\n4002 1 600 99.0 fresh-orphan\n4003 77 90000 99.0 child\n4004 1 90000 3.0 idle-daemon' \
  HQ_ROOTS="$gc_root" ROOT_DISK_PCT=50 hq gc)
contains "$out" 'orphan (report only, not killed): pid 4001 cpu 99.5% up 25h: superorchestrator tui'
[[ $out != *4002* && $out != *4003* && $out != *4004* ]] || fail 'gc reported young, parented or idle processes'
gc_reset
DOCKER_DOWN=1 HQ_ROOTS="$gc_root" ROOT_DISK_PCT=85 hq gc --apply >/dev/null
[[ $(cat "$DOCKER_LOG") == info ]] || fail 'gc pruned with docker unavailable'
exec 7>"$XDG_STATE_HOME/claude-hq/gc.lock"
flock -n 7
gc_reset
contains "$(HQ_ROOTS="$gc_root" ROOT_DISK_PCT=85 hq gc --apply)" 'gc: another run holds the lock'
gc_untouched 'locked gc deleted caches'
exec 7>&-
ok 'gc: gate, dry-run, build guard, go-build trim then cap wipe, stale-only targets, symlinks, docker, orphans, lock, log'

# gc worktrees: only clean + merged + unlocked + idle + not used by any process.
init_repo "$gc_root/app"
for name in clean locked busy dirty ahead; do git -C "$gc_root/app" worktree add -q -b "so/$name" "$gc_root/app-wt/$name"; done
git -C "$gc_root/app" worktree lock "$gc_root/app-wt/locked"
printf 'wip\n' >"$gc_root/app-wt/dirty/wip"
git -C "$gc_root/app-wt/ahead" -c user.name=Fixture -c user.email=fixture.invalid commit -q --allow-empty -m ahead
mkdir -p "$HQ_PROC_ROOT/777777"
ln -s "$gc_root/app-wt/busy" "$HQ_PROC_ROOT/777777/cwd"
"$REAL_FIND" -P "$gc_root/app-wt" -exec touch -h -d '2 hours ago' {} +
printf '[]\n' >"$fixture/gc-agents.json"
exec 7>"$XDG_STATE_HOME/claude-hq/janitor.lock"
flock -n 7
gc_reset
out=$(HQ_ROOTS="$gc_root" AGENTS_FILE="$fixture/gc-agents.json" ROOT_DISK_PCT=85 hq gc --apply)
contains "$out" 'skip worktrees: janitor running: 1'
[[ -d $gc_root/app-wt/clean ]] || fail 'gc removed worktrees while janitor held its lock'
exec 7>&-
out=$(HQ_ROOTS="$gc_root" AGENTS_FILE="$fixture/gc-agents.json" ROOT_DISK_PCT=85 hq gc --apply -v)
contains "$out" "applied: remove merged worktree $gc_root/app-wt/clean"
[[ ! -e $gc_root/app-wt/clean ]] || fail 'gc kept clean merged worktree'
for name in locked busy dirty ahead; do [[ -d $gc_root/app-wt/$name ]] || fail "gc removed $name worktree"; done
git -C "$gc_root/app" show-ref --verify --quiet refs/heads/so/ahead || fail 'gc deleted unmerged branch'
rm -f "$HQ_PROC_ROOT/777777/cwd"
# The janitor timer path runs gc after janitor --apply.
out=$(HQ_ROOTS="$gc_root" AGENTS_FILE="$fixture/gc-agents.json" ROOT_DISK_PCT=20 hq janitor --apply)
contains "$out" 'Janitor apply'
contains "$out" 'GC skipped: disk 20% < 70%'
ok 'gc worktrees: dirty/ahead/locked/busy kept, janitor lock respected, janitor --apply runs gc'

# Profile every command using fixture data; spawn/stop never reach a real session.
for action in projects sessions cleanup health capacity brief janitor gc memory spawn stop; do
  args=("$action")
  case $action in memory) args+=(check) ;; spawn) args+=(p0 --force -- profile) ;; stop) args+=(stress-0) ;; esac
  started_ns=$(date +%s%N)
  HQ_ROOTS="$stress_root" AGENTS_FILE="$fixture/stress-agents.json" hq "${args[@]}" >/dev/null
  elapsed_ms=$(( ($(date +%s%N)-started_ns)/1000000 ))
  printf 'profile: %s %sms (fixture)\n' "$action" "$elapsed_ms"
done
ok 'all commands profiled with fixture HOME, metadata and command stubs'

printf 'PASS: %s checks; fixture HOME + command stubs, no sessions or network.\n' "$tests"
