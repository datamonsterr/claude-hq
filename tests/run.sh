#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
fixture=$(mktemp -d /tmp/claude-hq-tests.XXXXXX)
trap 'rm -rf -- "$fixture"' EXIT
export HOME=$fixture/home
export XDG_CONFIG_HOME=$HOME/.config
export XDG_STATE_HOME=$HOME/.local/state
export TMPDIR=$fixture/tmp
export CLAUDE_CONFIG_DIR=$HOME/.claude
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export HQ_ROOTS=$HOME/dev:$HOME/other
export BESZEL_URL='' BESZEL_EMAIL='' BESZEL_PASSWORD=''
export CALL_LOG=$fixture/claude-calls.jsonl CURL_LOG=$fixture/curl-calls.jsonl
export AGENTS_FILE=$fixture/agents.json
export SYSTEMS_FILE=$fixture/systems.json ALERTS_FILE=$fixture/alerts.json
export SIGNAL_LOG=$fixture/signals
export HQ_TEST_REPO_ROOT=$repo
export HQ_MEMINFO_FILE=$fixture/meminfo HQ_LOADAVG_FILE=$fixture/loadavg
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
if [[ ${FAIL_REPO_SCAN:-0} == 1 && " $* " == *' _scan-repo '* ]]; then exit 124; fi
exec "$REAL_TIMEOUT" "$@"
STUB
cat >"$fixture/stubs/systemctl" <<'STUB'
#!/usr/bin/env bash
[[ ${SYSTEMCTL_FAIL:-0} != 1 ]] || exit 1
if [[ ${FAILED_UNITS:-0} == 1 ]]; then printf 'fixture.service loaded failed failed Fixture\n'; fi
exit 0
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
install_output=$(bash "$checkout/install.sh")
contains "$install_output" 'systemctl --user enable --now claude-hq-janitor.timer'
contains "$install_output" '"cleanupPeriodDays": 14'
[[ ! -e $HOME/.claude/settings.json ]] || fail 'installer edited user Claude settings'
[[ -f $XDG_CONFIG_HOME/claude-hq/config.env ]] || fail 'installer did not seed config'
jq -e --arg memory "$checkout/memory" '.autoMemoryDirectory==$memory and .extra=="keep" and .permissions.allow==["Bash(git status)"]' "$checkout/.claude/settings.local.json" >/dev/null || fail 'installer did not merge settings'
[[ -L $HOME/.local/bin/hq && $(readlink "$HOME/.local/bin/hq") == "$checkout/bin/hq" ]] || fail 'installer symlink'
printf '# keep custom configuration\n' >"$XDG_CONFIG_HOME/claude-hq/config.env"
bash "$checkout/install.sh" >/dev/null
[[ $(cat "$XDG_CONFIG_HOME/claude-hq/config.env") == '# keep custom configuration' ]] || fail 'installer overwrote config'
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
contains "$(hq capacity)" 'sessions 7/40 · mem 16G avail · load 0.4/core · disk 20% · tmp 20%'
expect_refusal 'sessions 7/7' env HQ_MAX_SESSIONS=7 "$repo/bin/hq" spawn alpha -- test
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
 {pid:999971,sessionId:"interactive-old",kind:"interactive",status:"idle",cwd:$root,startedAt:(($now-180000)*1000)},
 {pid:999970,sessionId:"remote-old",kind:"remote",status:"idle",cwd:$root,startedAt:(($now-180000)*1000)},
 {id:"live-wt",pid:999969,sessionId:"session-live-temp",kind:"background",state:"working",status:"busy",cwd:($root+"/.claude/worktrees/live/subdir"),startedAt:($now*1000)}
]' >"$janitor_agents"
# Contents deliberately are not a transcript; janitor must stat, never parse.
encoded=${janitor_root//[\/.]/-}-tools
mkdir -p "$CLAUDE_CONFIG_DIR/projects/$encoded" "$CLAUDE_CONFIG_DIR/projects/encoding-fallback"
printf 'not transcript JSON\n' >"$CLAUDE_CONFIG_DIR/projects/$encoded/done-recent-session.jsonl"
printf 'not transcript JSON\n' >"$CLAUDE_CONFIG_DIR/projects/encoding-fallback/active-recent-session.jsonl"
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
incomplete=$(HQ_ROOTS="$janitor_root" AGENTS_FILE="$janitor_agents" FAIL_REPO_SCAN=1 hq janitor 2>/dev/null)
[[ $incomplete != *'remove done session'* && $incomplete != *'remove merged worktree'* ]] || fail 'incomplete snapshot authorized deletion'
tuned=$(HQ_ROOTS="$janitor_root" AGENTS_FILE="$janitor_agents" HQ_DONE_HOURS=100 HQ_IDLE_HOURS=100 HQ_WORKTREE_HOURS=100 HQ_TMP_DAYS=100 hq janitor)
[[ $tuned != *'remove done session'* && $tuned != *'stop idle background'* && $tuned != *'remove merged worktree'* && $tuned != *'remove stale Claude temp'* ]] || fail 'janitor threshold tuning ignored'
ok 'janitor dry-run: done, idle, busy, transcript mtime/fallback, interactive report, no mutation'

mkdir -p "$XDG_STATE_HOME/claude-hq"
truncate -s 1048576 "$XDG_STATE_HOME/claude-hq/janitor.log"
out=$(HQ_ROOTS="$janitor_root" AGENTS_FILE="$janitor_agents" TMP_PCT=75 hq janitor --apply)
contains "$out" 'Removed done-old'
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
[[ $(rg -c -- '-INT 999971' "$SIGNAL_LOG") == 2 && $(rg -c -- '-INT 999970' "$SIGNAL_LOG") == 2 ]] || fail 'interactive opt-in stop missing'
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
ok 'janitor: interactive opt-in, exclusive lock, HQ memory protected'

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

stress_root=$HOME/stress-projects
mkdir -p "$stress_root"
for ((i=0;i<20;i++)); do init_repo "$stress_root/p$i"; done
jq -n --arg root "$stress_root" --argjson now "$(date +%s)" '[range(0;40)|{id:("stress-"+tostring),sessionId:("stress-session-"+tostring),pid:(900000+.),kind:"background",state:"working",status:"busy",cwd:($root+"/p"+(.%20|tostring)),startedAt:($now*1000)}]' >"$fixture/stress-agents.json"
for action in brief janitor; do
  calls_before=$(jq -s '[.[]|select(.args[0]=="agents")]|length' "$CALL_LOG")
  started_ns=$(date +%s%N)
  out=$(HQ_ROOTS="$stress_root" AGENTS_FILE="$fixture/stress-agents.json" hq "$action")
  elapsed_ms=$(( ($(date +%s%N)-started_ns)/1000000 ))
  [[ $elapsed_ms -lt 3000 ]] || fail "$action took ${elapsed_ms}ms (limit 3000ms)"
  calls_after=$(jq -s '[.[]|select(.args[0]=="agents")]|length' "$CALL_LOG")
  [[ $((calls_after-calls_before)) == 1 ]] || fail "$action queried agents more than once"
  if [[ $action == brief ]]; then
    [[ $(awk 'END{print NR}' <<<"$out") -le 30 ]] || fail 'stress brief exceeds 30 lines'
    contains "$(head -1 <<<"$out")" 'sessions 40/40'
  fi
  printf 'timing: %s %sms (40 sessions, 20 repos)\n' "$action" "$elapsed_ms"
done
ok 'performance: one agent query, 40 sessions / 20 repos, each <3s, brief <=30 lines'

printf 'PASS: %s checks; fixture HOME + command stubs, no sessions or network.\n' "$tests"
