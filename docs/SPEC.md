# claude-hq — spec v0.1

## Problem

The user works from a locked-down company laptop. Only the Claude Code app UI
(claude.ai/code / desktop / mobile) is allowed; no SSH, no other remote tools.
All real work runs on a home server (Arch Linux, this machine) via
`claude remote-control`. The user wants ONE long-lived "HQ" session that:

- knows every project on the server,
- spawns new, clickable Remote Control sessions per project (not just `cd`),
- lists and summarizes running sessions cheaply,
- reports cleanup candidates, finished work, and server health (Beszel + local),
- keeps a small durable memory, because the HQ session is cleared daily.

Prior art: Clauster (PyPI, schubydoo/clauster) does project-card spawning of
remote-control bridges, but through a loopback web UI the laptop cannot reach.
claude-hq does the same job from inside a Claude session.

## Shape

A git repo that is both:
1. the HQ project directory (open it in Claude Code, run `claude remote-control --name HQ` in it), and
2. a Claude Code plugin + marketplace (`.claude-plugin/`), so others can install the skill/commands/hook.

```
claude-hq/
  .claude-plugin/plugin.json        plugin manifest (name: hq)
  .claude-plugin/marketplace.json   marketplace listing this repo's plugin
  CLAUDE.md                         HQ controller rules (short)
  bin/hq                            single bash CLI, deps: bash, git, jq, tmux, claude, curl (Beszel only)
  skills/hq/SKILL.md                when/how to use each hq subcommand
  commands/*.md                     slash commands: brief, spawn, sessions, cleanup, health, remember
  hooks/hooks.json                  SessionStart: run `hq brief` (compact)
  memory/MEMORY.md                  durable notes, committed and pushed
  systemd/claude-hq.service         user unit template: keeps the HQ bridge alive
  install.sh                        symlink bin/hq into ~/.local/bin, copy config example
  config.example.env                HQ_ROOTS, HQ_PERMISSION_MODE, BESZEL_* ...
  tests/run.sh                      fixture-based tests, no network, no real claude
  README.md
```

## `hq` CLI

Config: env vars, optionally loaded from `${XDG_CONFIG_HOME:-~/.config}/claude-hq/config.env`.
State: `${XDG_STATE_HOME:-~/.local/state}/claude-hq/` (sessions.jsonl registry, logs).
Every command prints compact, plain text (token budget matters). `--json` where noted.

| Command | Behavior |
|---|---|
| `hq projects [--json]` | Git repos directly under each dir in `HQ_ROOTS` (colon-separated, default `~/dev`). Per repo: name, branch, dirty file count, ahead/behind upstream (if any), last commit age, number of extra worktrees. Skip `*-worktrees` dirs. |
| `hq spawn <project> [-n name] [--worktree] [--mode <permission-mode>] [-p "first prompt"]` | Start a new Remote Control session in that project inside a detached tmux session `hq-<project>-<shortid>`. Session title `"<project> · <name>"`. `--worktree` creates `git worktree add` on branch `hq/<slug>` under `<root>/<project>-worktrees/<slug>` and runs there. Optional first prompt: verify how to pass one (positional prompt with `claude --remote-control`/`--name`, or fallback: write `.hq-brief.md` in the run dir and make the title say "read .hq-brief.md"). Record id, project, dir, tmux name, title, created_at in sessions.jsonl. Print the title so the user can find it in claude.ai/code. |
| `hq sessions [--json]` | Registry rows joined with live state: tmux alive?, transcript last activity (newest `*.jsonl` mtime in `~/.claude/projects/<encoded dir>/`, encoding = path with `/` and `.` replaced by `-`), age. Also list non-hq transcript dirs active in last 24h as "other". |
| `hq summary <id\|project> [-n N]` | Digest of newest transcript: last N (default 3) user prompts and last assistant text, each truncated to ~300 chars, plus tool-call count. Use jq; never print the whole file. |
| `hq stop <id>` | Kill the tmux session, mark row stopped. |
| `hq cleanup [--apply] [--idle-hours H]` | Report (default) or act: dead tmux rows (prune), bridges idle > H (default 12) hours (stop), worktrees whose branch is merged into default branch (remove worktree + branch), `git worktree prune`. Never touch dirty worktrees. Dry-run is default. |
| `hq health [--json]` | Disk usage of `/` and `$HOME` (warn >85%), memory, load vs cores, `systemctl --failed` (system+user), docker containers not running/unhealthy. If `BESZEL_URL` + `BESZEL_EMAIL` + `BESZEL_PASSWORD` set: auth against Beszel's PocketBase API and list systems with status and triggered alerts (check Beszel 0.21 docs/source for exact endpoints). Missing tools degrade to a "skipped" line, never fail. |
| `hq brief` | One screen (<=40 lines): health warnings only, live sessions, projects with dirty/ahead work, cleanup candidate count, "Next" section from memory. Used by SessionStart hook. |
| `hq remember "<text>" [--section Next\|Decisions\|Notes]` | Append dated bullet to memory/MEMORY.md under the section. `hq memory` prints it. Memory path: `HQ_MEMORY` or `<repo>/memory/MEMORY.md`. |

## Acceptance

- `bash -n bin/hq` and `shellcheck bin/hq install.sh tests/run.sh` clean (shellcheck if installed).
- `tests/run.sh` passes: builds fixture HOME with 2 fake git repos (one dirty, one with merged worktree), fake transcript jsonl, stub `claude`/`tmux`/`systemctl`/`docker` on PATH; covers projects, spawn (asserts stub claude argv + registry row), sessions, summary, cleanup dry-run vs --apply, health without Beszel, brief line count <=40, remember.
- `claude plugin validate .` (or equivalent per current docs) passes for the plugin manifest.
- README: 5-minute setup for the home server, how to run HQ bridge under systemd/tmux, how the laptop uses it, install as plugin elsewhere.
- No secrets, hostnames, IPs, or personal paths committed.

## Out of scope (v0.1)

Web UI, MCP server, multi-machine, auto-merging, sending messages into running sessions, cost tracking.
