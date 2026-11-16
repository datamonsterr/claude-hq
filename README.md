# claude-hq v0.2

One long-lived HQ conversation on a home server, accessible through
[Claude Code Remote Control](https://code.claude.com/docs/en/remote-control).
From a company laptop, browser, desktop app, or phone, ask HQ to find projects,
spawn clickable working sessions, check progress, and report cleanup and health.
No SSH access from the laptop is needed.

HQ is Bash glue around Claude Code built-ins. Claude owns background sessions,
session discovery, Remote Control, worktrees, logs, and auto memory. HQ adds
project resolution, compact reports, and controller instructions. There is no
session registry, tmux manager, transcript parser, or daemon. An optional bounded
janitor performs only the automatic cleanup described below.
[docs/SPEC.md](docs/SPEC.md) defines the scope.

## Five-minute home-server setup

Requires Linux, Bash 4+, Git, jq, curl, GNU coreutils/findutils (including timeout,
stat, nproc, and xargs), util-linux (flock/ionice), and Claude Code with background sessions and
Remote Control (verified interface: 2.1.319). Sign in to a Claude account with
Remote Control available. Start with this checkout at `~/dev/claude-hq`.

1. Trust the HQ directory locally: run `claude` in it, accept workspace trust,
   then exit. Do this once in each project directory you want HQ to spawn into.
   Untrusted spawns print Claude's trust message for you to resolve locally.
2. Install the command and memory wiring:

   ```bash
   cd ~/dev/claude-hq
   bash install.sh
   export PATH="$HOME/.local/bin:$PATH"
   claude plugin marketplace add "$PWD"
   claude plugin install hq@claude-hq --scope local
   ```

   Add `~/.local/bin` to your shell PATH permanently. The idempotent installer
   symlinks `bin/hq`, merges the absolute `memory/` path as `autoMemoryDirectory`
   into the checkout's ignored `.claude/settings.local.json`, and copies
   `config.example.env` to `~/.config/claude-hq/config.env` only if absent.
   It respects `XDG_CONFIG_HOME`. Plugin installation enables the skill, slash
   commands, and SessionStart hook in the HQ directory. The hook checks for
   `.hq-root` in `CLAUDE_PROJECT_DIR`, so user-wide installs stay silent in children.
3. Edit that user-owned config. `HQ_ROOTS` is a colon-separated list, default
   `$HOME/dev`; only its immediate Git repositories are projects. Directories
   ending in `-worktrees` are skipped. Optionally set `BESZEL_URL`,
   `BESZEL_EMAIL`, and `BESZEL_PASSWORD` together for a Beszel users account.
   The config is sourced as shell code; keep credentials in that private copy.
4. Try Remote Control in the repo:

   ```bash
   claude remote-control --name HQ
   ```

   Open the displayed link on your other device. Keep the server awake.
   Exit this foreground process before enabling the persistent service below.
5. Install the user service:

   ```bash
   mkdir -p ~/.config/systemd/user
   cp systemd/claude-hq.service ~/.config/systemd/user/
   # Edit WorkingDirectory and ExecStart to match this checkout and `command -v claude`.
   systemctl --user daemon-reload
   systemctl --user enable --now claude-hq.service
   ```

   The template uses `%h/dev/claude-hq` and `%h/.local/bin/claude`. It runs
   `claude remote-control --name HQ` and restarts the process if it exits.
   Enable user lingering with `loginctl enable-linger "$USER"` if the service
   should survive logout (your server may require administrator approval).
   Inspect output with `journalctl --user -u claude-hq.service -n 30`.
   Claude owns session lifetime and reconnection; this unit keeps its Remote
   Control process running and does not implement session restoration.

## Use from the laptop

Open [claude.ai/code](https://claude.ai/code) or the Claude app and select HQ.
Try “Brief me”, “Work on alpha in a worktree”, or “Check my sessions”. HQ runs
on the home server and returns the built-in session id and available URL.
Select a child session directly when you want to work in it. Use `/clear` in HQ
for a fresh context; the SessionStart briefing and auto memory orient it again.

HQ checks `hq sessions` and uses Claude's `ListAgents` / `SendMessage` tools
to ask children for status. `/recap` provides session context; only when needed,
`claude -p --resume <id> "<question>"` adds a turn to the child. Background children
may lack auto memory, so HQ passes context and requests a <=2,000-token summary.
Cleanup is a report followed by a user decision.

## Commands

| Command | Result |
|---|---|
| `hq projects [--json]` | Name, branch, dirty count, ahead/behind, last commit age, live sessions |
| `hq spawn <project> [-n title] [-w [name]] [--mode mode] [--force] [--] [prompt…]` | Admission checks, then a built-in background Remote Control session |
| `hq sessions [project] [-a] [--json]` | Grouped id, state (status fallback), age, name; `-a` adds completed and older idle sessions |
| `hq stop <background-id\|sessionId-prefix>` | SIGINT twice; `claude rm` only for background ids |
| `hq cleanup [--idle-hours 12] [-v] [--json]` | Grouped findings with up to three samples; -v or JSON includes all |
| `hq health [-v] [--json]` | Warnings, or all local and Beszel checks with `-v` |
| `hq capacity` | Session count, Claude RSS, older idle count, available memory, load/core, disk and tmpfs use |
| `hq janitor [--apply] [-v]` | Grouped plans/results with up to three samples; -v lists all; apply logs full details |
| `hq gc [--apply] [--force] [-v]` | Disk-pressure build-cache and merged-worktree cleanup; see [Build and disk GC](#build-and-disk-gc) |
| `hq brief [-a]` | At most 30 lines of health, live sessions, dirty/ahead projects, cleanup count, memory Next |
| `hq memory check` | Warn about an index over 80 lines or project notes over 40 |

Examples:

```bash
hq spawn alpha -n 'alpha: fix tests' -w fix-tests --mode plan -- 'Investigate the failing tests; finish with a short summary.'
hq spawn alpha -w -- 'Use an automatically named worktree.'
hq sessions alpha -a
hq cleanup --idle-hours 24
```

Default spawn titles are `<project>: <first six words>`. Use an absolute project
path if multiple roots contain the same project name. Worktree/session ownership
stays with Claude. Use `claude logs`, `claude stop`, `claude rm`, and `claude purge`
for their built-in functions. HQ's graceful stop follows
[Clauster](https://github.com/schubydoo/clauster)'s SIGINT-twice approach because
plain stop can orphan the cloud session in the behavior recorded by the spec.
Interactive rows use the first eight sessionId characters as their displayed id;
`hq stop` accepts an unambiguous sessionId prefix and never calls rm for them.
Sessions and brief hide idle interactive sessions older than 24 hours by default,
with a hidden count; `-a` shows them. JSON sessions keep the array on stdout and
print the hidden count to stderr. LIVE excludes completed sessions and idle
sessions aged 24 hours or more. Use a disk-cleanup skill if one is installed
when disk cleanup is requested.

Cleanup uses **session age**, not measured idle duration: `claude agents --json`
has a start timestamp but no idle timestamp. A merged branch means its tip is
an ancestor of `origin/HEAD`, otherwise local `main` or `master`. If no default
can be established, work is kept. Review the base in each finding. Dirty worktrees are flagged without
a removal command. No command is executed by cleanup.

## Capacity and automatic cleanup

Spawn requires fewer than `HQ_MAX_SESSIONS=40` live Claude processes, at least
`HQ_MIN_MEM_MB=3072` available memory, load1/core <=`HQ_MAX_LOAD=1.5`, root/home
disk use <90%, and tmpfs `/tmp`/`$TMPDIR` use <80%. Refusal exits 3 with a one-line
reason; `--force` explicitly bypasses admission. `hq capacity` is also the first
line of `hq brief`.
For example: `sessions 56/40 (13.1G rss, 54 idle>72h)`. The idle label follows
`HQ_INTERACTIVE_HOURS` (default 72). All live processes count,
including older idle sessions. RSS sums accessible live-pid VmRSS metadata;
exited processes are skipped. A session-count refusal includes the older idle
count and points to `hq janitor`.

Start with `hq janitor` to review planned actions. `hq janitor --apply` enables
the policy in [SPEC: Capacity and auto-clean](docs/SPEC.md#capacity-and-auto-clean):

- Done backgrounds inactive >2h: SIGINT twice, then built-in rm if work is safe.
- Other non-busy backgrounds inactive >12h: stop only; keep the conversation.
- Interactive/remote idle >72h: stop by default; `HQ_JANITOR_STOP_INTERACTIVE=0`
  opts out to report-only. SIGINT twice with short waits keeps the conversation;
  interactive sessions are never removed with claude rm.
- Clean, merged, non-live worktrees untouched >1h: remove with Git, then prune;
  delete merged branches only with an approved prefix (`hq/ so/ claude/ worktree-`).
- Stale Claude scratch/session directories in `$TMPDIR` (default `~/.cache/tmp`)
  >3 days: remove only without live ids, newer descendants, or Git work. At >70%
  `/tmp` tmpfs use, remove user-owned non-Git files older than 2 days there.

Age uses one depth-two transcript mtime index and a sessionId join, without
reading contents or running per-session globs/stat processes. Duplicate ids use
the newest mtime, with session start time as fallback. Idle conversations are retained; idle alone
does not establish completed work. Dirty/unmerged work, symlink targets, live
worktrees, and HQ memory are protected. Busy sessions, sessions inside the HQ
checkout (also through symlinks), and the janitor's own ancestor processes are
never stopped. The brief states the current stop/report-only policy; hiding old
interactive rows in session displays still uses 24h. Configure the `HQ_*` thresholds listed
in [config.example.env](config.example.env). Each external janitor call has a
timeout, scans use four workers with a five-second repository budget, and each
invocation queries Claude's agents only once. Janitor runs at low CPU/I/O priority,
holds an exclusive flock, and logs applied actions to
`${XDG_STATE_HOME:-~/.local/state}/claude-hq/janitor.log` (1 MiB rotation, one backup).

To opt into the user timer after reviewing a dry-run:

```bash
cp systemd/claude-hq-janitor.{service,timer} ~/.config/systemd/user/
# Adjust WorkingDirectory and ExecStart in the copied service for your checkout.
systemctl --user daemon-reload
systemctl --user enable --now claude-hq-janitor.timer
```

The timer runs every 15 minutes; the service sets Nice=19,
IOSchedulingClass=idle, CPUWeight=10 and MemoryMax=256M. `install.sh` prints these
enable commands and does not enable the timer. Also consider setting
`"cleanupPeriodDays": 14` in `~/.claude/settings.json` yourself; the installer
only prints this suggestion. Its only edit to user Claude settings is the
SessionEnd gc hook below.

## Build and disk GC

Agent builds refill caches quickly (Go build cache, per-epic Cargo target dirs,
Go temp dirs, Docker build cache). `hq gc` prints a dry-run plan; `hq gc --apply`
deletes. Both exit at once unless root disk use is at least `HQ_GC_DISK_PCT`
(default 70) or `~/.cache/go-build` exceeds `HQ_GC_GO_GB` (default 10); `--force`
skips this gate only.

| Target | Rule |
|---|---|
| `$XDG_CACHE_HOME/go-build` (default `~/.cache`) | Entries unused for `HQ_GC_GO_AGE_H` (24; Go refreshes mtime on use) are trimmed; the whole cache is wiped only if still over `HQ_GC_GO_GB`, since a wipe forces slow cgo rebuilds |
| `$XDG_CACHE_HOME/*-target` | Removed when nothing inside changed for `HQ_GC_IDLE_MINUTES` (60) |
| `$XDG_CACHE_HOME/tmp/go-build*` | Same idle rule |
| Docker | `docker builder prune -f`, `docker image prune -f` (dangling only; never volumes) |
| Worktrees in HQ_ROOTS projects | The janitor's rule: clean, merged into the default branch, unlocked, idle `HQ_WORKTREE_HOURS`, and not the cwd of any process |

Every run, gated or not, also reports (never kills) orphaned processes: PPID 1,
up at least `HQ_GC_ORPHAN_HOURS` (6) and at least `HQ_GC_ORPHAN_CPU` (80) % CPU,
such as a stray `superorchestrator tui`.

Build caches are skipped entirely while any `cargo`, `rustc`, `go build|test|run|install|vet|generate`,
or `docker [compose|buildx] build` process of the user runs. Symlinks are never
followed and nothing outside the cache directory is deleted. Worktree cleanup is
skipped while the janitor holds its lock. Runs take `gc.lock` (no overlap), run at
Nice 19 / idle I/O under `HQ_GC_TIMEOUT` (900 s), log to `janitor.log`, and report
freed space from root-disk usage before and after.

Triggers:

- **Timer (all agents):** `hq janitor --apply` runs `hq gc --apply` after the
  janitor, so the 15-minute timer covers Claude, Codex, OpenCode and agy runs,
  including those superorchestrator starts. The service allows 1050 s.
- **Claude Code SessionEnd:** `install.sh` merges this hook into
  `${CLAUDE_CONFIG_DIR:-~/.claude}/settings.json` beside existing SessionEnd hooks
  (rerunning replaces it, never duplicates):
  ```json
  {"type": "command", "command": "setsid -f ~/.local/bin/hq gc --apply >/dev/null 2>&1 </dev/null", "timeout": 1}
  ```
  (`install.sh` writes the absolute path.) SessionEnd hooks share a 1.5 s budget and
  cannot block exit; `setsid -f` returns immediately with stdio redirected, so the
  exit never waits and gc outlives the session (also under `claude -p`).
  Superorchestrator's Claude account uses `~/.claude`, so its runs get the hook too.
- **Codex:** supports a `SessionEnd` hook (1 s default, 3 s max) in each
  `$CODEX_HOME/hooks.json`, but every non-managed hook must be trusted per home via
  `/hooks` before it runs. It is not installed automatically; to opt in, add the same
  `command` with `"timeout": 1` under `hooks.SessionEnd[].hooks` in each Codex home
  and trust it. The timer covers Codex otherwise.
- **OpenCode, agy, superorchestrator:** no post-session command hook
  (superorchestrator only sends Discord/desktop notifications), so the timer covers them.

Health always checks root/home disk usage and failed system units when available.
Default warnings: disk/memory >=85%, CPU >=90%, a non-up Beszel system, or a
triggered alert. An unavailable local or Beszel check is a warning. Beszel auth
uses `/api/collections/users/auth-with-password`; paginated `systems` records use
`name`, `status`, and `info.cpu/mp/dp`, and `alerts` uses `triggered`, `system`,
`name`, and threshold `value`. Schema verified against
[Beszel v0.21.0 source](https://github.com/henrygd/beszel/tree/v0.21.0/internal),
including its collections snapshot and system Info type. Tokens stay in memory.

## Durable memory

[Claude Code auto memory](https://code.claude.com/docs/en/memory) uses the ignored
local setting written by the installer. Only `memory/MEMORY.md` is auto-loaded:
keep it an index, one line per entry, <=80 lines / about 6 KB. The seeded files
are templates without personal data.

- `memory/projects/<name>.md`: <=40 lines; path, purpose, status, gotchas; read on demand.
- `memory/decisions.md`: append one dated line per settled decision.
- `memory/log/YYYY-MM.md`: archived daily notes; grep only, never preload.

Save settled decisions, preferences, project mappings/status, and recurring
failures. Do not duplicate facts available from Git, repository files, or the
built-in agent list. At day's end, archive notes, prune the index, check bounds,
then commit and push memory changes to your own Git remote. Review what you sync.

## Install the plugin in another checkout

The plugin is named `hq`, in the bundled `claude-hq` marketplace:

```bash
claude plugin marketplace add ~/dev/claude-hq
claude plugin install hq@claude-hq --scope user
```

Use `/hq:hq`, `/hq:brief`, `/hq:spawn`, and `/hq:cleanup`. The plugin prefers the
installed `hq` command so briefings read the durable checkout's memory, rather
than a plugin-cache copy. Without hq on PATH it falls back to its bundled CLI,
whose memory files are templates. Plugin installation does not configure
another repository's auto memory. Keep the HQ checkout as the durable memory
home and run `install.sh` there. If you prefer to try the plugin without
installing it, start Claude with `--plugin-dir ~/dev/claude-hq` in a trusted
directory. See the official
[plugins](https://code.claude.com/docs/en/plugins),
[manifest](https://code.claude.com/docs/en/plugins-reference),
[marketplaces](https://code.claude.com/docs/en/plugin-marketplaces),
[hooks](https://code.claude.com/docs/en/hooks), and
[skills](https://code.claude.com/docs/en/skills) documentation.

## Verification

```bash
bash -n bin/hq install.sh tests/run.sh
command -v shellcheck && shellcheck bin/hq install.sh tests/run.sh
bash tests/run.sh
claude plugin validate .
```

Tests use a temporary HOME, Git repositories, and stubbed `claude`, `curl`,
`systemctl`, `df`, `docker`, `pgrep`, and signals. They never start a real session, contact the
network, or touch real Claude configuration. Plugin validation checks metadata
and packaging without starting a session. Performance coverage includes 150
project directories x 20 transcripts, 20 repositories, and 132 branches;
see [performance measurements](docs/performance.md).

## Credits and research

The choice to use built-ins is documented in
[docs/research-memory.md](docs/research-memory.md).
[Clauster](https://github.com/schubydoo/clauster) informed spawning and graceful
stop. [Beszel](https://github.com/henrygd/beszel) supplies server health and alerts.
[Anthropic's memory tool](https://platform.claude.com/docs/en/agents-and-tools/tool-use/memory-tool)
and [context engineering notes](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents)
informed small notes and just-in-time retrieval.
[claude-mem](https://github.com/thedotmack/claude-mem) informed progressive
disclosure; [basic-memory](https://github.com/basicmachines-co/basic-memory),
[agentmemory](https://github.com/rohitg00/agentmemory), and cavemem/caveman were
evaluated without adding their servers. [Beads](https://github.com/gastownhall/beads)
remains an optional future task layer. No web UI, MCP server, multi-machine
coordination, auto-merge, deletion outside janitor policy, or cost tracking is included.
