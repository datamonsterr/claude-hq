---
name: hq
description: Coordinate home-server project sessions through Claude Code Remote Control, with compact health, cleanup reports, and durable HQ memory.
---

Act as the HQ controller. Run `hq brief` at start and after `/clear`.
When installed as a plugin without hq on PATH, use
`"${CLAUDE_PLUGIN_ROOT}/bin/hq"` for each hq command below.

| User intent | Action |
|---|---|
| Orient / daily start | `hq brief` |
| Find work | `hq projects` (`--json` for structured output) |
| Start a project task | `hq spawn <project> [-n title] [-w [name]] [--mode mode] -- "<prompt>"` |
| Check work | `hq sessions [project]`; `-a` includes completed and older idle |
| Ask child for status | Use `ListAgents` and `SendMessage` after checking sessions |
| Recover context | `/recap` in child; only if needed, `claude -p --resume <id> "<question>"` (adds a turn) |
| Read logs | `claude logs <id>` |
| Stop a session | After user approval, `hq stop <id-or-session-prefix>` (SIGINT twice; rm only for background ids) |
| Find cleanup candidates | `hq cleanup [--idle-hours 12]`; `-v` lists all items/commands (report only) |
| Check server | `hq health`; `-v` shows all, `--json` gives structured results |
| Check admission | `hq capacity`; spawn refuses exhausted resources (exit 3); `--force` only when requested |
| Automated cleanup | `hq janitor` groups plans; `-v` lists all; explicitly authorized `--apply` logs full details |
| Check memory bounds | `hq memory check` |
| Clean disk | Use a disk-cleanup skill if one is installed |

Spawn using `hq spawn`, never just `cd`. Projects resolve from HQ_ROOTS.
Use `--` after a bare `-w` to separate the prompt from an optional worktree name.
Pass relevant context in the prompt: background children may lack auto memory.
Ask children to finish with a summary of at most 2,000 tokens.
Surface workspace-trust messages so the user can trust the directory locally.
Treat built-in agent names as summaries; do not parse transcript files.
Cleanup means report exact commands, then ask the user before acting.
The cleanup report uses session age; janitor checks transcript mtimes, never contents.
Do not create a session registry, tmux manager, or purge service.
Only explicitly authorized janitor --apply may perform automatic cleanup.

Use built-in auto memory in the HQ checkout's `memory/`, wired by `install.sh`.
When installed elsewhere, run the original checkout's installer to set HQ memory;
plugin installation does not copy HQ project settings into other repositories.
Keep MEMORY.md as an index, one line per entry, <=80 lines / about 6 KB.
Read projects/<name>.md only as needed; <=40 lines: path, purpose, status, gotchas.
Append one dated line per settled decision to decisions.md.
Save settled decisions, preferences, project mappings/status, recurring failures.
Never save facts available from git, repo files, or `claude agents --json`.
Write facts when settled. End of day, move daily notes to log/YYYY-MM.md,
prune the index, run `hq memory check`, then `git commit && git push`.
Never preload log files; grep only for a specific historical question.
