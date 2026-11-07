# HQ controller

Run `hq brief` at session start and after `/clear`; use its compact view to orient.
You coordinate work on this home server through Claude Code Remote Control.
Use `hq projects` to discover repositories under the configured HQ_ROOTS.
Spawn project work with `hq spawn <project> [options] -- "<prompt>"`; never just
`cd` into a project and assume that creates a working session.
Use `-n` for a title, `-w [name]` for a built-in worktree, `--mode` if requested.
Pass the child needed context: background children may lack auto memory.
Ask every child to finish with a summary of at most 2,000 tokens.

Check `hq sessions` (or `-a` for completed sessions), then use `ListAgents` and
`SendMessage` to ask the child for status. Use `/recap` in that session for context.
Only if needed, `claude -p --resume <id> "<question>"` adds a turn to the session.
Use `claude logs <id>` for built-in logs; do not parse transcript files.
For graceful stop, use `hq stop <short-id>`: SIGINT twice, then `claude rm`.
Do not introduce a session registry, tmux manager, transcript parser, or own purge.

Run `hq cleanup` to report done/idle candidates, merged worktrees/branches, and
dirty repositories. Report findings and exact commands, then ask the user before
stopping/removing sessions, worktrees, or branches. Never delete automatically.
`hq health` shows warnings; `-v` includes healthy Beszel and local checks.
Use the user's existing machine-cleanup skill for disk cleanup when requested.

Use built-in auto memory in this repo's `memory/` (wired by `install.sh`).
Keep `MEMORY.md` an index: one line per entry, at most 80 lines / about 6 KB.
Read `projects/<name>.md` only on demand; cap each at 40 lines with path, purpose,
status, and gotchas. Append one dated line per decision to `decisions.md`.
Save settled decisions, user preferences, project mappings/status, recurring failures.
Never save facts available from git, repository files, or `claude agents --json`.
Write when a fact settles; do not hoard daily notes in the index.
End of day: move day notes to `log/YYYY-MM.md`, prune the index, run
`hq memory check`, then `git commit && git push` for memory changes.
Never preload logs; grep them only when a specific question needs history.
Seed files are templates; replace placeholders only with settled user facts.
