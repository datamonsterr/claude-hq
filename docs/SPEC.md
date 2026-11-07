# claude-hq — spec v0.2 (thin layer over built-ins)

## Problem

The user works from a locked-down company laptop. Only the Claude Code app UI
(claude.ai/code / desktop / mobile) is allowed; no SSH. All work runs on a home
server via Remote Control. The user wants ONE long-lived "HQ" session that knows
every project, spawns clickable working sessions, checks their state, flags
cleanup and server health, and keeps a small durable memory across daily `/clear`.

## Principle: reuse built-ins, add only glue

Verified on Claude Code 2.1.319 (2026-11-07):

| Need | Built-in used | HQ adds |
|---|---|---|
| Spawn clickable session in a project | `cd <dir> && claude --bg --remote-control --name "<title>" [-w <name>] "<prompt>"` — verified: background session, Remote Control active, URL `claude.ai/code/session_…` | `hq spawn` resolves project name to dir, builds title, prints id |
| List sessions + status | `claude agents --json` (id, cwd, kind, name, status, state, sessionId) | `hq sessions` groups by project, compact table |
| Session summary | AI session name in `claude agents --json`; `/recap`; `claude -p --resume <id> "…"` (adds a turn); `ListAgents`/`SendMessage` cross-session messaging tools | nothing; skill tells HQ which to use and when |
| Stop / remove | `claude stop <id>`, `claude rm <id>` | nothing |
| Transcript/worktree cleanup | `cleanupPeriodDays`, worktree auto-removal, `claude purge` | `hq cleanup` *report only*: done/idle sessions > N h, merged-but-present worktrees/branches, dirty repos |
| Disk cleanup | a disk-cleanup skill, if installed | nothing |
| Health + alerts | Beszel hub (already alerts, heartbeat) | `hq health`: compact Beszel summary via its PocketBase API; tiny local fallback (df, failed units) |
| Memory | Built-in auto memory (MEMORY.md index + topic files, loaded at start, survives `/clear`) | layout + rules, stored in repo so it syncs via git (see Memory) |

Dropped from v0.1: tmux, own session registry, transcript parsing, own purge service.
Automatic deletion is limited to the explicit janitor policy below.

## Shape

```
claude-hq/
  .claude-plugin/plugin.json, marketplace.json   plugin "hq"
  CLAUDE.md                 HQ controller rules (<60 lines)
  .claude/settings.json     HQ-dir settings (memory dir if allowed, permissions for hq/claude agents)
  bin/hq                    bash; deps: bash, git, jq, curl, claude
  lib/hq-{agents,capacity,repos,report,janitor}.sh   metadata, resources, bounded scans/reports, janitor glue
  skills/hq/SKILL.md        decision table: which built-in or hq command per intent
  commands/brief.md, spawn.md, cleanup.md
  .hq-root                  marker for the HQ-only SessionStart briefing
  hooks/hooks.json          SessionStart: `hq brief` only if CLAUDE_PROJECT_DIR has .hq-root
  memory/                   durable memory (see Memory)
  systemd/claude-hq.service user unit keeping `claude remote-control --name HQ` alive in the repo dir
  systemd/claude-hq-janitor.service, .timer   optional cleanup every 15 minutes
  install.sh, config.example.env, tests/run.sh, README.md
```

## `hq` CLI (each output compact; `--json` where useful)

- `hq projects` — git repos directly under `HQ_ROOTS` (colon list, default `~/dev`), skipping `*-worktrees`. Row: name, branch, dirty count, ahead/behind, last commit age, live session count (from `claude agents --json` cwd prefix).
- `hq spawn <project> [-n title] [-w [name]] [--mode <permission-mode>] [--force] [prompt…]` — checks capacity, then runs the built-in command above in the project dir. Prints short id + title. Title default `"<project>: <first 6 words of prompt>"`.
- `hq sessions [project]` — `claude agents --json` (add `--all` with `-a`) grouped by project root, columns id, state/status, age, name.
- `hq stop <id>` — SIGINT the session pid twice, then `claude rm <id>` for background ids only. Interactive rows resolve by unambiguous sessionId prefix; display `.id // (.sessionId[0:8])` and `.state // .status` in sessions.
- `hq cleanup [--idle-hours 12] [-v]` — report only, grouped counts with up to three sample items/commands per rule. `-v` lists every item; `--json` preserves all records. Never deletes.
- `hq health` — if `BESZEL_URL`, `BESZEL_EMAIL`, `BESZEL_PASSWORD` set: auth (`/api/collections/users/auth-with-password`), list systems (name, status, cpu/mem/disk %) and active alerts. Else/also: root+home disk %, `systemctl --failed` count. Warnings only by default, `-v` for all.
- `hq brief [-a]` — <=30 lines: capacity at top, health warnings, live sessions per project, dirty/ahead projects, cleanup candidate count, top of memory "Next". Candidate counts use bulk Git metadata; `hq cleanup` performs full worktree checks.

Sessions and brief hide idle interactive rows aged >=24h by default, reporting
"N older idle hidden, -a to show"; -a includes them. JSON sessions report the count
on stderr. Projects LIVE counts only non-terminal rows that are non-idle or <24h.

## Capacity and auto-clean

This section authorizes janitor's bounded cleanup only. `hq cleanup` remains
report-only. No session registry, transcript content parsing, or replacement for
Claude's session/worktree operations is introduced.

`hq capacity` prints one line, for example:
`sessions 56/40 (13.1G rss, 54 idle>24h) · mem 14G avail · load 0.4/core · disk 43% · tmp 16%`.
Sessions counts non-done/non-stopped rows with a pid, including interactive rows.
RSS sums VmRSS from `/proc/<pid>/status` for unique live pids, ignoring exited or
inaccessible pids. Idle>24h uses the joined last-activity timestamp and status idle;
these idle processes still count towards admission. A session-limit refusal names
the idle count and points to `hq janitor` for review.
Disk and tmp show the maximum relevant percentage across the checked paths.
Spawn refuses with exit 3 and one-line reason unless all of these hold:

- sessions < `HQ_MAX_SESSIONS` (40);
- MemAvailable from `/proc/meminfo` >= `HQ_MIN_MEM_MB` (3072);
- load1 from `/proc/loadavg` / `nproc` <= `HQ_MAX_LOAD` (1.5);
- disk use of `/` and `$HOME` <90%;
- tmpfs use at `/tmp` and `$TMPDIR` <80% (default scratch directory `~/.cache/tmp`).

Unavailable metrics refuse admission. `hq spawn --force` explicitly bypasses
checks. `HQ_MEMINFO_FILE`, `HQ_LOADAVG_FILE`, and `HQ_PROC_ROOT` allow fixture metadata in tests.

`hq janitor [--apply] [-v]` defaults to dry-run. Output groups counts per rule,
with at most three sample items each; `-v` lists all items. On --apply, all item
details, including report-only/kept items and command output, go to janitor.log.
Both modes
hold a nonblocking flock in `${XDG_STATE_HOME:-~/.local/state}/claude-hq/`.
Janitor self-applies `nice -n 19` and `ionice -c3`. External calls have timeouts
(`HQ_CALL_TIMEOUT=8` seconds; whole run `HQ_JANITOR_TIMEOUT=120`); Git calls and
each repository scan are bounded to 5 seconds. Repository scans use four workers
and `git --no-optional-locks`. A single cached `claude agents --json --all` query
serves each invocation. Incomplete scans never authorize session/worktree removal.

Last activity is the transcript **mtime only**, never its contents. Build one
index per invocation with a depth-two find of `*.jsonl` under
`$CLAUDE_CONFIG_DIR/projects` (default `~/.claude/projects`), then join by
sessionId once. For duplicate ids use the newest mtime. No per-session glob or
stat processes. Missing files fall back to `startedAt`; missing both keeps the
session. The index is held only in memory, without persistent session tracking.

Git scans obtain branch/divergence/dirty state with one porcelain-v2 status call,
batch merged refs and branch occupancy, and serialize each repository once.
Brief skips per-worktree status/age scans; janitor checks only merged, non-live,
old candidates. Applying an action still performs the safety rechecks below.

Janitor policy:

1. Background **done** sessions inactive > `HQ_DONE_HOURS` (2) are interrupted
   twice, then removed with `claude rm`. Dirty/unmerged work or an incomplete
   repository snapshot prevents removal. Background state idle uses rule 2,
   preserving its resumable conversation; idle is not proof of completion.
2. Other background sessions that are not busy/running/working and inactive >
   `HQ_IDLE_HOURS` (12) receive SIGINT twice only; no rm.
3. Interactive/remote idle sessions inactive > `HQ_INTERACTIVE_HOURS` (24) are
   reported only, unless `HQ_JANITOR_STOP_INTERACTIVE=1`; that opt-in stops only.
4. Registered worktrees are discovered through Git for every repository under
   HQ_ROOTS, including sibling `<repo>-worktrees/*` and `.claude/worktrees/*`.
   Remove only non-primary worktrees with no modified, untracked, or ignored
   files; tip fully merged into the default branch (equivalently zero commits
   beyond its merge-base; origin/HEAD, then local main/master, otherwise keep);
   no live cwd inside; no filesystem activity for
   `HQ_WORKTREE_HOURS` (1). Recheck before applying. Prune after removal. Delete
   merged, unoccupied local branches only when a prefix in `HQ_BRANCH_PREFIXES`
   matches (default `hq/ so/ claude/ worktree-`). Never delete the default branch.
5. Under `$TMPDIR` (default `~/.cache/tmp`), remove user-owned Claude scratchpad/
   session directories older than `HQ_TMP_DAYS` (3), without newer descendants,
   Git work, or live session ids in their path/tree. Do not follow symlinks or
   cross filesystem boundaries. If `/tmp` is tmpfs and >
   `HQ_TMP_PRESSURE_PCT` (70) percent full, remove user-owned files there older
   than `HQ_SYSTEM_TMP_DAYS` (2), protecting Git work and live session paths.
   Never leave the selected scratch root or `/tmp`.
6. Never touch dirty/unmerged work or this HQ checkout's `memory/`. Metadata,
   names, ownership and mtimes may be inspected; transcript contents are not read.

Every applied action is logged to the state directory's `janitor.log`; at 1 MiB
rotate to `janitor.log.1`, retaining one previous log. Failed attempts are logged
as failures. Dry-run does not write action logs. The optional user service/timer
runs every 15 minutes with Nice=19, IOSchedulingClass=idle, CPUWeight=10,
MemoryMax=256M. Installer prints enable commands but does not enable it. Suggest
`cleanupPeriodDays: 14` in user settings; never edit those settings automatically.

## Memory

Decision (see docs/research-memory.md): use built-in auto memory as-is, copy the
Anthropic memory-tool / structured-notes pattern. No claude-mem / agentmemory /
basic-memory (daemon or MCP server each). Beads optional later for cross-project tasks.

Layout (in repo, synced via git):
- `memory/MEMORY.md` — index, one line per entry, cap 80 lines / ~6KB. Only file auto-loaded.
- `memory/projects/<name>.md` — <=40 lines each: path, purpose, status, gotchas. Read on demand.
- `memory/decisions.md` — append-only, one line per decision, dated.
- `memory/log/YYYY-MM.md` — never loaded; grep only.

Wiring: `install.sh` writes `.claude/settings.local.json` (gitignored) in the repo with
`autoMemoryDirectory` = absolute path of `<repo>/memory` (relative paths rejected by Claude Code).

Rules (in CLAUDE.md):
- Save: decisions, user preferences, project mappings/status, recurring failures.
  Never save what `git`, the repo, or `claude agents --json` can tell.
- Write when a fact settles. End of day: move day notes to `log/YYYY-MM.md`, prune index, `git commit && git push`.
- Spawned `--bg` children may lack auto memory: pass needed context in the spawn prompt;
  ask children to end with a <=2k-token summary.

`hq memory check` — warn when MEMORY.md > 80 lines or a project file > 40 lines.

## Acceptance

- `bash -n bin/hq`; shellcheck clean if installed.
- `tests/run.sh`: fixture HOME + command/resource/filesystem stubs; no network, real sessions, or real `~/.claude`. Covers admission, RSS, every janitor policy and negative cases, grouped reports and full logs. Performance fixture: 40/56 sessions, 20 repos, 132 branches, 150 project dirs x 20 jsonl files; brief <1.5s, janitor dry-run <2s, one agent query/index, brief <=30 lines. Profiles every command with fixtures.
- `claude plugin validate .` passes.
- No secrets, hostnames, IPs, personal paths committed.

## Out of scope

Web UI, MCP server, multi-machine, deletion outside janitor policy, auto-merging, cost tracking.
