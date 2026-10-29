# MACFIX9 report

Implemented on `swarmhub/peer-delivery`, starting at `ad029a2` (fixes10).
**Native macOS acceptance is pending.** OVH cannot execute Seatbelt; passing profile
and stub tests here does not establish that the Mac accepts or enforces the rule.
No commit was made. Hermes was not changed, installed, restarted or contacted.
Runtime tests used synthetic fixtures and local processes, with no external
connections or outbound deliveries. Public source documentation was read to check
the Darwin mechanism; no live application/provider integration was exercised.

The supplied `mac-5de25fd` result establishes that ordinary AF_INET and AF_UNIX
`socket()` creation succeeds under the old profile. That profile has deny-default
and no network grants, but no explicit syscall restriction. Thus the absence of
network grants was insufficient for the promised creation-time denial. The exact
internal Seatbelt policy evaluation cannot be reproduced on OVH.

Apple's [XNU socket implementation](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/uipc_syscalls.c)
separates creation from bind/connect and has a second creation entry point,
`socket_delegate`. Apple's [syscall table](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/syscalls.master)
assigns these numbers 97 and 450. The
[WebKit macOS profile](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/WebProcess/com.apple.WebProcess.sb.in)
explicitly denies `SYS_socket` through `syscall-unix`. These primary sources support
the implementation choice; they do not substitute for the requested native run.

The changes are:

- `Resources/Skills/swarmhub-coding/scripts/verify_darwin.py` adds
  `(allow syscall-unix)(deny syscall-unix (syscall-number 97 450))`, plus explicit
  `network*` and `system-socket` denials. Other syscalls still face the existing
  filesystem, Mach and signal operation checks. Numeric constants avoid importing
  a system profile that might grant additional permissions. There is no conditional
  omission of the rule on older systems and no unsandboxed fallback.
- `verify-sandbox.py` starts isolated `/usr/bin/python3 -I -B` inside the same
  Seatbelt profile. Before executing the workspace shell command, the fixed guard
  requires EPERM/EACCES for IPv4, IPv6 and Unix stream/datagram creation. If any
  creation succeeds, it closes the descriptor and exits 77. Other socket errors,
  such as unsupported address families or descriptor exhaustion, also refuse the
  command. No address, connect, bind, listen, DNS lookup or send is used by the guard.
  The guard then execs `/bin/sh` in the same confined process, passing the command as
  a separate argument. `-I` prevents a workspace `socket.py` or user site package
  from replacing the guard's imports.
- `socketpair()` remains available for anonymous local IPC, matching Linux's
  existing exception. It is distinct from creating addressable AF_UNIX sockets.
  New positive coverage exercises socketpair creation and asyncio subprocess pipes.
- The reported `OrdinaryVerifierTests.test_network_and_host_processes_stay_out_of_reach`
  is unchanged. The separate native network test now requires creation itself to
  raise `PermissionError`, after a probe marker, instead of attempting a connection
  to loopback port 9 and accepting any error. Setup exit 77 and Xcode exit 69 are
  rejected as evidence. This strengthens the assertion and avoids contact even
  under a broken policy.
- `sim/test_macfix9.py` adds nine tests: four guard/profile tests, three shared
  behavior tests and two native Mac tests. Coverage includes all six socket kinds,
  direct libc calls, exec-child inheritance, raw Darwin socket/socket_delegate
  syscalls, and deliberate removal of effective restrictions. The deliberately
  permissive native control must exit 77 before creating the command's marker,
  even with a planted workspace `socket.py`.
- The bundled coding skill is **1.3.6** (previously 1.3.5), with Python/Swift version
  assertions updated so existing installs are offered the corrected helper.
  The messages skill is unchanged. No new helper file needs packaging.

The startup check adds one system Python startup to each Darwin verification.
An absent/broken system Python, unrecognized syscall rule, or ineffective socket
restriction prevents verification from proceeding. This is intentional fail-closed
behavior, but a Mac run in which every ordinary command refuses is **not acceptance**.
The exact rule syntax/enforcement, returned errno, Xcode shim behavior and continued
socketpair/Node operation must be demonstrated on the target Mac.

Local validation:

| Check | Clean `ad029a2` | Changed tree |
| --- | --- | --- |
| Focused new/profile/version/launcher tests | Not applicable | 19 tests: 15 pass, 4 native-Mac skips |
| Original Mac Python selection, executed on Linux | 51 tests: 43 pass, 3 fail, 5 native-Mac skips | Same results and same failing methods |
| Original ordinary-verifier class | 4 tests: 3 pass, 1 fail | Same results (also included in the replay) |
| Swift build/tests | Toolchain unavailable | Not run |

The three baseline and changed replay failures are:

- `sim.test_fixes6.GitMetadataEscapeTests.test_workspace_remains_writable_and_outside_stays_closed`
  (new top-level entry denied in Linux limited mode).
- `sim.test_fixes6.OrdinaryVerifierTests.test_node_child_processes_work`
  (`spawnSync /bin/sh EPERM` on this Linux host).
- `sim.test_fixes7.LimitedModeSuitesTests.test_mode_is_recorded_by_the_launcher_for_the_job_result`
  (`unshare -Ur true` succeeds, but actual setup takes fallback rather than namespaced mode).

No failures were turned into skips. The original socket-denial test, new real Linux
socket/libc/child checks, and socketpair/asyncio positive check all pass here.
An initial 23-test focused run included the ordinary-verifier class: 18 passed,
1 baseline Node failure and 4 native-Mac skips. Logs are in
`/tmp/macfix9-focused.log`, `/tmp/macfix9-regressions.log`,
`/tmp/macfix9-baseline-ordinary.log`, `/tmp/macfix9-replay-linux.log`, and
`/tmp/macfix9-baseline-replay-linux.log`. The clean baseline was extracted with
`git archive HEAD` into `/tmp/macfix9-baseline-ad029a2`.

The focused command was:

```sh
PYTHONPATH=sim python3 -B -m unittest \
  sim.test_macfix9 sim.test_fixes9_darwin sim.test_fixes6.DarwinProfileTextTests \
  sim.test_fixes8_skills \
  sim.test_fixes5.VerificationTests.test_darwin_launch_allows_executable_mappings_without_opening_host_files -v
```

**Review of the 12 Mac skips:** `/tmp/mac-5de25fd.sh` identifies the original replay
as `sim.test_remote_approvals sim.test_fixes6 sim.test_fixes7 sim.test_fixes9_darwin
sim.test_fixes9_approvals`. That selection contains exactly these twelve
platform-gated methods:

| Class | Count | Reason |
| --- | ---: | --- |
| `sim.test_fixes6.LandlockFallbackTests` | 3 | Linux Landlock entry-by-entry filesystem rules; Darwin uses Seatbelt. |
| `sim.test_fixes7.LimitedModeSuitesTests` | 6 | Linux limited-mode signal supervision, `/dev/shm`, process cleanup and mode reporting. |
| `sim.test_fixes7.MountDeniedAfterUnshareTests` | 3 | Linux user/mount namespaces and injected mount/Landlock failures. |

All twelve are legitimate platform exclusions. The exact Mac output log was not
available locally, so this is a source/replay-script reconciliation, not a claim to
have read twelve individual Mac skip lines. `-v` in the replay below must confirm
the identities. An additional missing-Node skip would be a coverage gap, not one
of these twelve. The two new native tests must run on Mac; they add no Mac skips.
The full discovery suite contains additional Linux-only process-syscall tests,
so twelve is specific to this replay selection, not a full-suite skip budget.

On the Mac, from the checkout containing these uncommitted changes (or the later
box-shell commit), record `git rev-parse HEAD`, `git status --short`, `sw_vers`,
`uname -m`, `python3 --version` and `xcode-select -p`, then run:

```sh
# Exact previous selection plus the new regressions: expected 60 tests, 12 Linux-only skips.
PYTHONPATH=sim python3 -B -m unittest \
  sim.test_remote_approvals sim.test_fixes6 sim.test_fixes7 \
  sim.test_fixes9_darwin sim.test_fixes9_approvals sim.test_macfix9 -v

# Shell startup, exit propagation, edited-test denial and packaging/version checks.
PYTHONPATH=sim python3 -B -m unittest \
  sim.test_fixes5.VerificationTests.test_verifier_runs_builtins_and_workspace_executables_and_preserves_exit \
  sim.test_fixes5.VerificationTests.test_B1_network_from_command_and_edited_test_is_denied \
  sim.test_fixes8_skills -v

/bin/sh Tests/Scripts/code-job-test.sh "$PWD/Resources/Skills/swarmhub-coding/scripts/code-job"
# If /bin/dash is installed, also run the existing alternate-shell suite:
CODE_JOB_SH=/bin/dash /bin/dash Tests/Scripts/code-job-test.sh "$PWD/Resources/Skills/swarmhub-coding/scripts/code-job"

# Existing app fixture/stub tests; no live Hermes/provider runs or installs.
swift build
swift test
```

Mac acceptance requires all of the following:

1. The original AF_INET and AF_UNIX snippets reach Python and raise `PermissionError`;
   neither exit 0, shim exit 69, setup refusal 77, nor profile parse failure counts.
2. All six Python socket probes print their reached marker and fail with permission
   errors. The libc probes complete with six denials in both parent and exec child;
   the direct-syscall native test reaches its completion marker.
3. Anonymous socketpair, asyncio, multiprocessing/timeouts, shell/git and Node child
   tests still succeed. No socket-denial test is skipped. The changed guard must not
   interfere with ordinary command exit propagation (including exits 3, 5 and 127).
4. The deliberately permissive native control refuses with 77 and the guard-specific
   diagnostic before executing the workspace command. No marker file is written.
5. Existing system-Python shim, linked-worktree reads, `.git`/secret write/read denials,
   host-signal restrictions and native Mach allow/deny tests remain green. Their
   actual probe markers must be observed, not substituted with startup errors.
6. The replay reports only the twelve identified Linux-only skips. Record any extra
   skip or failure by name. Retain full stderr if Seatbelt rejects the syscall rule;
   do not remove the rule/guard or relax the socket assertions to obtain a green run.

Python syntax parsing and `git diff --check` pass. The launcher is 464 lines,
the Darwin helper 89, and the new test file 172; no touched source exceeds 500
lines and no bytecode files were generated under `Resources/Skills`.
