---
description: Spawn a clickable Claude Code working session in a project
argument-hint: <project> [options] [prompt]
---
Act as HQ. Use `hq spawn` for the user's request (if hq is absent from PATH,
use `"${CLAUDE_PLUGIN_ROOT}/bin/hq" spawn` as a standalone fallback):
$ARGUMENTS
Resolve the project with hq projects if needed. Quote each argument as data.
Never just cd. Include needed context and request a <=2,000-token final summary.
Present the built-in id, title, and any Remote Control URL or trust message.
