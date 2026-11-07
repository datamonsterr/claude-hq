# Performance checks

Read-only wall-clock measurements during this change used 56 live sessions,
153 Claude project directories, 7 repositories under the default roots,
64 registered worktrees, and 138 merged branch refs. Local config files were
excluded from the profiling environment. No real spawn, stop, or janitor apply
was run.

| Command | Before | After |
|---|---:|---:|
| projects | 2.180 s | 0.473 s |
| sessions | 0.329 s | 0.335 s |
| cleanup | 2.210 s | 0.779 s |
| health (local) | 0.030 s | 0.034 s |
| capacity | 0.273 s | 0.350 s |
| brief | 2.289 s | 0.674 s |
| janitor (dry-run) | 3.435 s | 0.742 s |
| memory check | 0.011 s | 0.014 s |

Cleanup output dropped from 438 lines to 17; janitor from 127 to 9. Default
reports group counts and at most three samples per rule. `-v` lists everything;
janitor `--apply` writes every detail and command result to its bounded log.

Timestamped Bash traces and individual repository scans isolated the expensive
worktree scans: 1.888 s for 27 trees and 0.893 s for 23 trees. The changes batch
merged refs, serialize worktrees once per repository, and build branch occupancy
once. Brief counts metadata candidates, leaving full tree checks to cleanup.
Janitor inspects only eligible trees and rechecks each deletion on apply.

Activity-dependent commands walk transcript metadata once and join by sessionId;
no transcript content is read. Capacity also reads live-pid VmRSS directly from
proc status files. Missing/exited pids are skipped in the RSS sum, while the
agent list remains the source of the admission count.

Run `bash tests/run.sh` for reproducible fixture measurements. It creates 150
project directories with 20 deliberately invalid jsonl files each, 20 repositories,
132 merged branches, and both 40-session and 56-session/54-idle cases. It checks:

- brief <1.5 s and <=30 lines; janitor dry-run <2 s;
- one agent query and one transcript index per relevant invocation;
- grouped counts, at most three samples, complete verbose/JSON output and logs;
- RSS sums and session-limit refusal guidance;
- every command's fixture timing, including stub-only spawn and stop.

Timings vary with filesystem cache, repository size and concurrent system load.
