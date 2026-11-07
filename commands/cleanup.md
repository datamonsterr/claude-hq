---
description: Report session, worktree, branch, and dirty-repository cleanup candidates
argument-hint: [--idle-hours N]
---
Run `hq cleanup` using the requested idle-hours (if hq is absent from PATH,
use `"${CLAUDE_PLUGIN_ROOT}/bin/hq" cleanup` as a standalone fallback):
$ARGUMENTS
Report findings with exact commands; ask the user before stopping or removing
anything. Preserve dirty work. Never execute cleanup automatically.
The default report groups counts and three samples; use -v for the full item list.
