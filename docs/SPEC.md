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

Dropped from v0.1: tmux, own session registry, own transcript parsing, own stop/kill, auto-delete.

## Shape

```
claude-hq/
  .claude-plugin/plugin.json, marketplace.json   plugin "hq"
  CLAUDE.md                 HQ controller rules (<60 lines)
  .claude/settings.json     HQ-dir settings (memory dir if allowed, permissions for hq/claude agents)
  bin/hq                    bash; deps: bash, git, jq, curl, claude
  skills/hq/SKILL.md        decision table: which built-in or hq command per intent
  commands/brief.md, spawn.md, cleanup.md
  .hq-root                  marker for the HQ-only SessionStart briefing
  hooks/hooks.json          SessionStart: `hq brief` only if CLAUDE_PROJECT_DIR has .hq-root
  memory/                   durable memory (see Memory)
  systemd/claude-hq.service user unit keeping `claude remote-control --name HQ` alive in the repo dir
  install.sh, config.example.env, tests/run.sh, README.md
```

## `hq` CLI (each output compact; `--json` where useful)

- `hq projects` — git repos directly under `HQ_ROOTS` (colon list, default `~/dev`), skipping `*-worktrees`. Row: name, branch, dirty count, ahead/behind, last commit age, live session count (from `claude agents --json` cwd prefix).
- `hq spawn <project> [-n title] [-w [name]] [--mode <permission-mode>] [prompt…]` — runs the built-in command above in the project dir. Prints short id + title. Title default `"<project>: <first 6 words of prompt>"`.
- `hq sessions [project]` — `claude agents --json` (add `--all` with `-a`) grouped by project root, columns id, state/status, age, name.
- `hq stop <id>` — SIGINT the session pid twice, then `claude rm <id>` for background ids only. Interactive rows resolve by unambiguous sessionId prefix; display `.id // (.sessionId[0:8])` and `.state // .status` in sessions.
- `hq cleanup [--idle-hours 12]` — report only, with exact commands to run (`claude stop/rm`, `git worktree remove`, `git branch -d`). Never deletes.
- `hq health` — if `BESZEL_URL`, `BESZEL_EMAIL`, `BESZEL_PASSWORD` set: auth (`/api/collections/users/auth-with-password`), list systems (name, status, cpu/mem/disk %) and active alerts. Else/also: root+home disk %, `systemctl --failed` count. Warnings only by default, `-v` for all.
- `hq brief [-a]` — <=30 lines: health warnings, live sessions per project, dirty/ahead projects, cleanup count, top of memory "Next".

Sessions and brief hide idle interactive rows aged >=24h by default, reporting
"N older idle hidden, -a to show"; -a includes them. JSON sessions report the count
on stderr. Projects LIVE counts only non-terminal rows that are non-idle or <24h.

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
- `tests/run.sh`: fixture HOME + stub `claude` (records argv, returns canned `agents --json`), stub `curl`/`systemctl`/`df`; no network, no real `~/.claude`. Covers projects, spawn argv, sessions grouping, cleanup report, health with and without Beszel, brief <=30 lines.
- `claude plugin validate .` passes.
- No secrets, hostnames, IPs, personal paths committed.

## Out of scope

Web UI, MCP server, multi-machine, auto-deletion, auto-merging, cost tracking.
