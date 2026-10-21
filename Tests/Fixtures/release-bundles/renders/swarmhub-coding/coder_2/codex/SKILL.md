---
name: swarmhub-coding
description: "Use for any coding task: writing or changing code, work in a repository, tests, pull requests. Hands the task to a coding agent (Claude Code, Codex) through SwarmHub's code-job queue; supersedes the claude-code, codex and opencode skills. Installed by SwarmHub, v1.3.14."
version: 1.3.14
author: SwarmHub
metadata:
  swarmhub:
    source: swarmhub
---

# SwarmHub coding

Use this for every coding task: writing or changing code, work in a repository, running and fixing tests, preparing a
pull request. Do not use the claude-code, codex or opencode skills; this one replaces them.

How to run a job:
1. Write the task as one clear, self-contained instruction (what to change, where, how to check it).
2. Start it as a background process of your terminal tool (its background option), with your workspace or the
   repository folder as `--dir`:
   ```
   ~/.hermes/profiles/coder_2/skills/swarmhub/swarmhub-coding/scripts/code-job --bot coder_2 --order codex --dir <workspace or repo folder> --model <explicit model ID> --effort high --report <report path> --verify "<project test command>" -- "<task>"
   ```
3. Wait for the process to finish. A job can take many minutes; when the box is busy it first waits for a free coding
   slot ("Waiting for a free coding slot…"). Do not start the same task twice.
4. Report the result in a few lines: what changed, what was checked, and the last `code-job:` line as it is (which
   agent ran, how long it waited and ran, its peak memory, and anything skipped).

Exit codes: 0 done; 124 the job ran out of time; 69 no coding agent could run (say which were skipped and why); any
other code is the agent's own failure, report its output. On exit 75 with `CODE_JOB_USE_DELEGATE` on stdout, do the
task with your own delegate_task (a sub-agent) instead.

Claude Code is never started by a direct code-job: it runs on this box with the operator's shell (acceptEdits plus
Bash), outside any workspace sandbox, so it needs the owner's approval of the exact task. A direct run skips it
(`skipped claude: approval`) and continues with the next agent in the order. To use Claude Code, submit a managed
coding task (`swarmctl submit`, below) and wait for the owner's decision; code-job then checks the approved record
(`--task-id`) before launching it.

Never print, read or copy `~/.hermes/swarmhub/claude.token`, and never set ANTHROPIC_API_KEY. Logins are SwarmHub's
Accounts sheet's job (`scripts/swarmhub-claude-login`, run by the manager bot): never run it or a login yourself.

Completion routing: when this task came from another bot, add `--origin <ordering-profile>` to code-job (or set
`SWARMHUB_ORDERING_BOT`). A Hermes terminal in `swarmhub-from-<sender>` also infers it from `HERMES_SESSION_ID`.
Use the sender of the original request, not the worker's own profile. Unknown/missing origin
falls back to `COORDINATOR=<profile>` in `~/.hermes/swarmhub/coding.conf` or `SWARMHUB_COORDINATOR`. Without either,
the completion remains pending until a coordinator is configured. Install swarmhub-messages alongside this skill.
Every exit publishes a private record in `~/.hermes/swarmhub/job-completions/job.*` before temporary output is removed.
The record contains routing, agent, exit/status, work directory and timings, never the task text or CLI output.
The messaging worker retries priority wakes until delivered, including after restart; no keys need copying.
A repeated completion carries the same job ID. Check that ID before repeating follow-up work. Exit 75 is a delegate
handoff, not a completed coding task. A receiver journal suppresses acknowledged completion IDs, including when the
sender lost its acknowledgement. An interrupted unacknowledged turn can recover after a lease; this is not a
transactional exactly-once guarantee for arbitrary tools inside a model turn.

Completion contract: `--model` and `--report` are required (or `CODE_JOB_MODEL` / `CODE_JOB_REPORT`); effort defaults to
explicit `high` and is passed to the CLI. Use a model ID supported by the chosen CLI; prefer a single-agent order
when pinning a model. Codex receives `--model` and `model_reasoning_effort`; Claude receives `--model` and `--effort`.
The CLI is told the report path. Exit zero requires nonempty CLI output, a fresh nonempty report whose hash differs
from its pre-run contents, **and evidence code-job gathers itself**: a new commit in `--dir` (HEAD recorded before and
after the run; resetting or switching to an unrelated history is not a new commit) or a passing verification command (`--verify "<command>"`, else `CODE_JOB_VERIFY`, else `VERIFY=` in
`~/.hermes/swarmhub/coding.conf`), run by code-job in `--dir` after the CLI exits. A configured verification that
fails is never outweighed by a commit. Missing model/report, empty work and unchanged reports fail with exit 65; a
fresh report without evidence exits 66 with status `unverified`. Records include the CLI exit separately from the
contract exit, model, effort, report path/existence and hash, `head-before`/`head-after`, `commit-evidence`,
`verify-command`/`verify-exit`, `tests-passed` and the `evidence` summary (`commit`, `tests`, `commit+tests`, `none`).
The completion wake lists what code-job verified and what remains unverified (report correctness, the work itself).
Exit zero certifies these checks, not the correctness of the work. Reports stay at their paths; their text and the
verification output are not copied to records or wakes. Managed jobs take the command from the `verify` spec field.
The report is checked again after verification. Stop also cancels verification and its child processes.

For a standing queue or any task with approval gates, use the messaging skill's `scripts/swarmctl submit` with JSON
on stdin. Coding fields: `bot`, `origin`, stable `intent`, `kind: "coding"`, `task`, absolute `directory`, `order`,
`model`, `effort`, `report`, optional one-line `verify` (the evidence command, e.g. the test suite); add
`risks: ["money", "prod", "secrets"]` as applicable and `parent` for peer work.
An unchanged intent is admitted only once. Each bot runs queued jobs in order; verified completion launches the next
automatically, even without a model reply to the wake. Failure holds later jobs until cancelled/replaced. Stop and
scope replacement cancel the old task tree, including queued peer deliveries and running managed streams/CLI trees.
Changed scope requires a new intent and fresh approval; `swarmctl replace <old-id>` reads the new JSON from stdin.
Direct code-job remains available for an already-authorized local task. It enforces the same global coding route,
speculation rule (`--speculative`) and completion contract. Managed `--task-id` jobs must match their approved record.

Verification authority: `verify-sandbox.py` executes the command and all imported test/build code with only the
recorded workspace and a private temporary directory writable, a scrubbed environment, and no network. The
repository metadata (`.git`, a worktree's gitdir) is read-only for the verifier, so it cannot plant `core.fsmonitor`,
`core.hooksPath`, hooks or filters that a later host `git status` would execute. Linux requires Landlock ABI 3+ and
libseccomp; with unprivileged user namespaces the verifier also gets a private mount/PID namespace (read-only `.git`
bind, private /proc and /dev/shm, signals confined to the sandbox, AF_UNIX socketpairs allowed), so ordinary test
commands work: `>/dev/null`, `git status`, node child processes, Python asyncio/multiprocessing/subprocess timeouts.
Without a usable user namespace (unshare refused, or unshare granted but mount denied as under Ubuntu's AppArmor
`apparmor_restrict_unprivileged_userns`) the same commands work in the **limited mode**: the workspace is granted entry
by entry (no new top-level entries), `kill`/`tkill`/`tgkill`/`rt_sigqueueinfo`/`rt_tgsigqueueinfo` are answered by
the unconfined launcher and reach only the verifier's own process tree and groups (`verify_signals.py`; a broadcast signal to PID -1, the
launcher and every host process get EPERM; ptrace, process_vm_*, pidfd signalling and SIGIO owners are denied).
Non-signal PID operations (limits, priority, scheduling, NUMA, robust-list reads and kcmp) are self-only;
priority operations on groups/users are denied. pidfd_open is brokered for the own tree, process_madvise accepts self; inherited
pidfds/sockets are discarded before confinement (`verify_processes.py`). All children inherit these restrictions, and
shared memory is the host's /dev/shm opened by name (no listing, no directories; not private). The launcher
records the mode (`verify-mode`: `namespaced`, `fallback`, `seatbelt`) in the job record and the completion wake names
the limited mode. If the limited mode cannot confine either, the verification is refused (exit 77). macOS uses sandbox-exec with a named Mach service allowlist (no pasteboard, LaunchServices,
AppleEvents or keychain) and `.git` write-denied, including linked worktree metadata; the verifier runs in its own process group, killed when it exits.
Darwin teardown: the launcher waits for the verifier's exit without reaping it (kqueue), SIGKILLs the group and waits
up to 5 s until it is empty (including process listings), then allows at most 0.25 s to reap the leader: a total
teardown wait ceiling of 5.25 s, plus OS scheduling/syscall overhead. Every group signal precedes the reap, so the
group ID cannot have been reused. Surviving/unlistable members or a leader that cannot be reaped fail verification (77). Terminating the launcher (TERM/INT/HUP, as on timeout or
cancel) runs the same teardown. Limit: a descendant that calls `setsid()` or `setpgid()`, or is spawned into a new
session/group, leaves the group and escapes this cleanup (Seatbelt has no pidfd/subreaper equivalent); a result is not
proof that such a process has stopped. Exact Xcode license/selection
files and the selected developer directory are readable so system toolchain shims can start (`verify_darwin.py`). Repository roots and reciprocal worktree pointers are captured before the coding tool runs and checked again before verification (`verify_git.py`); changed pointers refuse verification. The capture runs only when a verification command is configured; a layout it does not admit (submodule, separate-git-dir) still runs the job and its verification refuses with the reason, so the job reports unverified. Standalone linked-worktree verification requires an explicit pre-tool `--capture-git` snapshot. Required syscall resolution or installation failures refuse startup. On Linux, descendant exit is acknowledged and adopted children reaped before reporting completion. Unsupported isolation fails the verification; there is no host-shell
fallback. Managed coding tasks wait for the owner's decision unless the owner published `coding_gate: auto` (the
sandboxed Codex route); an order that includes claude waits for the owner regardless. Additional host/network authority is not supported by this verifier and must not
be obtained by changing the command. Use a separately owner-gated managed operation when extra authority is needed.
Managed admission freezes the effective VERIFY default into the immutable spec before fingerprinting; `"verify":""`
explicitly disables verification. Managed execution never re-reads environment/config defaults.

Scratch cleanup: an EXIT trap is installed immediately after allocation. Each startup sweeps private
`~/.hermes/swarmhub/scratch/code-job.<launcher-pid>.*` directories older than one day only if that PID is definitely
gone. Live/reused PIDs, permission errors, symlinks and legacy entries without a PID are retained; age alone is not
proof that a job has stopped. This reclaims most hard-kill leftovers on a later launch, not immediately. Remove legacy
entries manually only after confirming no job uses them. The HOME-workspace fallback still uses system `/tmp`.
