# Research: memory and session tooling (2026-11-07)

| Project | Capture | Selection / token bound | Storage | Setup | Verdict |
|---|---|---|---|---|---|
| [claude-mem](https://github.com/thedotmack/claude-mem) | 9 hooks feed a Bun worker; an observer LLM writes observations | SessionStart index (50 obs, 10 sessions); 3-layer search: search (~50-100 tok/hit), timeline, get_observations (~0.5-1k tok/hit) | SQLite FTS5 + Chroma | Node, Bun, uv, worker, extra LLM spend | Copy the progressive-disclosure idea, skip the daemon |
| [basic-memory](https://github.com/basicmachines-co/basic-memory) | Manual, via MCP tools | Nothing injected; model must search | Markdown + `[[wikilinks]]`, SQLite index | uv + MCP server | Too passive; recall depends on model asking |
| [beads](https://github.com/gastownhall/beads) | `bd remember`, task graph | `bd prime` hook injection; caps unlimited by default | Dolt, synced to git refs | Go binary, no daemon | Optional later for cross-project tasks |
| [agentmemory](https://github.com/rohitg00/agentmemory) | 12 hooks | 2000-token SessionStart budget, BM25 | Server on 3111/3113 | Daemon | Skip |
| cavemem (merged into caveman) | 5 hooks | FTS5 + 3-step MCP retrieval | SQLite | Idle-exit worker | Skip |
| [Claude Code auto memory](https://code.claude.com/docs/en/memory) | Claude writes files | First 200 lines / 25KB of MEMORY.md each session; topic files on demand | Markdown in `autoMemoryDirectory` (absolute or `~/` path only) | Built in | **Adopt** |
| [Anthropic memory tool](https://platform.claude.com/docs/en/agents-and-tools/tool-use/memory-tool) + [context engineering](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents) | Explicit file ops | Cap file sizes, expire stale notes, just-in-time loading, subagents return 1-2k token summaries | `/memories` files | Pattern | **Copy the rules** |
| [Clauster](https://github.com/schubydoo/clauster) | n/a | n/a | n/a | Python web UI (loopback) | Reuse argv shapes: `claude --bg --rc NAME -- PROMPT`; parse `backgrounded · <id>`; stop = SIGINT x2 then `claude rm` |

Built-ins verified on 2.1.319: `claude --bg --remote-control NAME PROMPT` creates a background session visible at claude.ai/code; `claude agents --json` lists id, cwd, name, status, state.

Unverified: whether `--bg` children get auto memory (docs say the toggle "can't be turned on" for background sessions).
