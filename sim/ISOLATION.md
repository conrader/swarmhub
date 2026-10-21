# Sim harness isolation

On 2026-10-21 a Swift test on the Mac started this harness outside the safe namespace. On ovh, an earlier code-job
`kill_tree()` with a root pid of 0, 1 or empty sent SIGTERM and SIGKILL to every `ubuntu` process. The harness, the
code-job stub tests and the signal-sending tests now refuse to run unless they are isolated.

## Linux: a PID namespace or nothing

Run them only like this:

```sh
sudo -u sbtest -- unshare -r -p -f --mount-proc python3 -B -m unittest discover -s sim -p 'test_*.py'
sudo -u sbtest -- unshare -r -p -f --mount-proc sh Tests/Scripts/code-job-test.sh Resources/Skills/swarmhub-coding/scripts/code-job
```

The same applies to `discover -s scripts` and `discover -s Tests/Updater`, because some of their tests import sim
modules.

Every `sim/*.py` imports `sim_isolation` as its first import. That module exits with status 78 and prints the command
above unless the kernel says the process is isolated:

- `/proc/self/ns/pid` is not `pid:[4026531836]`, the host's initial PID namespace (`PROC_PID_INIT_INO`).
- `/proc/self` resolves to `os.getpid()`, so `/proc` belongs to this namespace (`--mount-proc`).
- Pid 1 of the namespace is in the same namespace and is an ancestor of the process.

No environment variable can claim isolation. From inside such a namespace, a signal cannot reach a process outside it.
The refusal also covers a Swift/XCTest launch: `live_observed.py` is guarded like every other entry point, and the
message names the launcher when it can tell. `Tests/Scripts/code-job-test.sh`, `bot-msg-test.sh` and
`sim/mac-codex-tmp-smoke.sh` run `/usr/bin/python3 -I -B sim/sim_isolation.py --check` before they do anything else (an absolute path, so a
stub `python3` on PATH cannot answer for it).

## macOS: signal-guarded mode (the choice made here)

macOS has no PID namespaces, so nothing there can prove isolation. The Swift tests that need the harness
(`ObservedPatternTests` running `live_observed.py --offline`, and `CodeJobScriptTests`/`BotMessageScriptTests`
running the shell suites) still exercise the real shipped scripts. A pure in-process stub would have dropped that
coverage. So on Darwin the harness runs in signal-guarded mode:

- `os.kill` and `os.killpg` are wrapped, which also covers `Popen.send_signal`, `terminate` and `kill`. So is
  `signal.pidfd_send_signal` where it exists. A target that is <= 1 (other than the process itself), negative, empty or not an int is refused. So is
  this process's own group, unless the process leads it. Any other target must be a live descendant of the
  process in one fresh snapshot of the process table (`/proc` on Linux, `ps -A -o pid,ppid,pgid,lstart` on macOS).
  A pid the harness once spawned counts for nothing by itself: once reaped, seen or not, its number may belong to
  an unrelated process, and so may that process's children. On Linux `kill` first pins the pid with `pidfd_open`
  and signals through the pidfd, so a reuse between the check and the signal cannot receive it. Every visible
  group member must be this process or its current descendant, including when this process leads the group.
  Mixed groups are refused. No survivor list is captured after reaping: by then the leader's identity has been
  released and the group number may already belong to someone else. Orphans adopted elsewhere are therefore
  refused even when they used to be ours; a group whose remaining members are still our descendants is allowed.
  Signal 0, an existence probe that delivers
  nothing, may still name any pid above 1. A refusal raises `PermissionError(EPERM)` and logs a line to stderr, as
  does an unreadable process table. A stale pid, or a child already reaped, raises `ProcessLookupError` without a
  signal. Every wait primitive reports reaping: `os.waitpid`, `wait`, `wait3`, `wait4`, `waitid`, and `Popen`'s
  own exit handling, which also runs for a `Popen` that was discarded while its child ran.
- `live_observed.py --offline` writes `"isolation": "darwin-guarded"` into `results.json`, and
  `ObservedPatternTests` requires it. A harness that started without the guard fails that Swift test.
- Shell code started by the harness cannot be wrapped. It has its own guards: code-job's `kill_tree`/`tree` refuse
  roots <= 1 and anything that is not a live direct child. `code-job-test.sh` and `bot-msg-test.sh` signal only
  pids that pass `own_pid` from `Tests/Scripts/own-pid.sh`: a plain number above 1, not the shell, a live
  descendant of the shell by the parent chain `ps` reports at that moment, and, where the pid comes from disk, a
  process whose command line names the expected program. `mac-codex-tmp-smoke.sh` signals its timed-out group
  only while its leader is unreaped, which pins the group number.

The Linux suites install the same signal guard inside the namespace, so every Linux run also exercises the guarded
mode the Mac relies on. Any other platform is refused.

## Signal helpers (defence in depth)

| Helper | Refuses |
| --- | --- |
| code-job `kill_tree`/`tree` | empty, garbage, <= 1, this shell, its ancestors, foreign roots (test_killtree_guard) |
| `swarm_store.terminate` | non-int, <= 1, self, ancestors (test_killtree_guard) |
| `verify_signals.Supervisor`, `verify_darwin.signal_group` | root/group <= 1, own group (test_killtree_guard) |
| `swarm_lifecycle.stop_child`, the termination forwarder, `stop_legacy_group` | any group that is not `private_group()`: <= 1, non-int, this process's group (test_signal_guards) |
| `Tests/Scripts/code-job-test.sh`, `bot-msg-test.sh` | every pid kill goes through `own_pid`: live descendant, expected command (test_signal_guards) |
| sim harness process | everything in the macOS list above, on both platforms (test_sim_isolation, test_sim_isolation_reuse) |

`mac-codex-tmp-smoke-stub.py` is the only sim module without the import. It is a fake Codex CLI that runs inside
code-job's own sandbox, under the guarded smoke script.
