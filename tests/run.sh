#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
export HOME=$fixture/home
export XDG_CONFIG_HOME=$HOME/.config
export CLAUDE_CONFIG_DIR=$HOME/.claude
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export HQ_ROOTS=$HOME/dev:$HOME/other
export BESZEL_URL='' BESZEL_EMAIL='' BESZEL_PASSWORD=''
export CALL_LOG=$fixture/claude-calls.jsonl CURL_LOG=$fixture/curl-calls.jsonl
export AGENTS_FILE=$fixture/agents.json
export SYSTEMS_FILE=$fixture/systems.json ALERTS_FILE=$fixture/alerts.json
export SIGNAL_LOG=$fixture/signals
export HQ_TEST_REPO_ROOT=$repo
mkdir -p "$HOME/dev" "$HOME/other" "$fixture/stubs"
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
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf 'fixture 100 20 80 %s%% /\n' "${DISK_PCT:-20}"
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
contains "$out" 'claude stop idle1'
contains "$out" 'claude rm done1'
contains "$out" 'worktree remove'
contains "$out" 'branch -d'
contains "$out" 'dirty entries'
contains "$out" 'hq stop 87654321'
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
cp "$repo/install.sh" "$repo/config.example.env" "$checkout/"
cp "$repo/memory/MEMORY.md" "$checkout/memory/"
printf '{"permissions":{"allow":["Bash(git status)"]},"extra":"keep"}\n' >"$checkout/.claude/settings.local.json"
bash "$checkout/install.sh" >/dev/null
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

[[ ! -e $HOME/.claude ]] || fail 'tests touched Claude configuration'
printf 'PASS: %s checks; fixture HOME + command stubs, no sessions or network.\n' "$tests"
