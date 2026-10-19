# Fixes8 report: Codex review of fixes7 (signal bypass, /goal classifier, skill versions)

Branch `swarmhub/peer-delivery`, base `7a25611`, Linux (Ubuntu, kernel 6.8, libseccomp 2.5.5, Python 3.12, Yama
`ptrace_scope=1`), 2026-10-19. Input: `/home/ubuntu/work/swarmhub/20261019T162320Z-fixes7.review.txt` (verdict:
concerns, three findings) and `FIXES7-REPORT.md`. Findings 5 and 9 are untouched. Hermes is untouched. No live Hermes or
provider calls: the sandbox tests run the shipped scripts against temporary repositories and a local helper process.

Commits: `e32aca7` (item 1), `56740ed` (item 2), `bc7ab53` (item 3), then the refactor that keeps `verify-sandbox.py`
under 500 lines and this report (see the end).

## Item 1 (high): the limited sandbox signals only its own process tree

**Reproduced first.** Before the change, a probe in the limited sandbox (`SWARMHUB_VERIFY_NAMESPACES=0`) got signals
into a helper process outside the sandbox four ways: `rt_sigqueueinfo`, `rt_tgsigqueueinfo` (the review's finding),
and two the review did not name: `fcntl(F_SETOWN, pid)` plus `O_ASYNC` on a pipe, and `ioctl(FIOSETOWN, pid)` on an
AF_UNIX socketpair. With SIGIO owners the kernel signals that pid later, on I/O. The helper received 6 signals. x32
syscall numbers (`nr | 0x40000000`) were already killed with SIGSYS by libseccomp's bad-arch action.

**What changed:**

- `verify_signals.py:32`: `rt_sigqueueinfo` and `rt_tgsigqueueinfo` join `kill/tkill/tgkill` as seccomp
  user-notification calls answered by the unconfined launcher. `decide` (`:185-226`, branches `:206-221`):
  - **Aimed at another process:** the target is pinned with a pidfd and checked against the sandbox tree, as for kill.
    Then the caller's `siginfo_t` is copied **once** from `/proc/<tid>/mem` (`siginfo`, `:109-135`). The open is
    checked against the pending request with `SECCOMP_IOCTL_NOTIF_ID_VALID`, `si_signo` is set to `sig`, and the copy
    is sent with `pidfd_send_signal(pidfd, sig, info)` or `rt_tgsigqueueinfo` (`call`, `:100-107`). The receiver gets
    the caller's `SI_QUEUE`, `si_pid` and `si_value`. The kernel's own rule still applies: a non-negative si_code
    (impersonating kill) towards another process is EPERM, as it would be for the caller.
  - **Aimed at the caller's own thread group:** answered with `SECCOMP_USER_NOTIF_FLAG_CONTINUE` (`:44`, `:239`), so
    the kernel's self-signal rules apply unchanged. This is the only CONTINUE. Its target is the blocked caller
    itself, so pid reuse cannot redirect it.
  - Kernel argument errors are mirrored: pid ≤ 0 gives ESRCH; tgid/tid ≤ 0 gives EINVAL; an unreadable siginfo gives
    EFAULT.
- `verify_signals.py:37-42` (used by `verify-sandbox.py:218-222`): in limited mode, `fcntl` `F_SETOWN`/`F_SETOWN_EX`
  and `ioctl` `FIOSETOWN`/`SIOCSPGRP` are EPERM. The command is matched with `SCMP_CMP_MASKED_EQ` on its low 32 bits,
  because the kernel takes an `unsigned int` command and junk in the upper half of the register must not dodge the rule.
  `kcmp` is denied there too. `pidfd_open` and `pidfd_send_signal` stay denied in limited mode. `ptrace`,
  `process_vm_readv/writev` and `pidfd_getfd` stay denied in every mode (`verify-sandbox.py:54`).
- `supervised_syscalls` (`verify-sandbox.py:270`) also resolves `pidfd_send_signal` for the launcher's own use.
- Namespaced mode is unchanged: the sigqueue calls are plain syscalls there, and the PID namespace already hides host
  pids.
- `SKILL.md:90-92` documents the routed and denied calls. The module docstring of `verify_signals.py` lists the whole
  family.

**Per syscall:**

| Syscall | Limited mode now | Own child |
|---|---|---|
| kill, tkill, tgkill | launcher-checked (fixes7) | works |
| rt_sigqueueinfo, rt_tgsigqueueinfo | launcher-checked, siginfo copied (**new**); self: kernel | works, payload intact |
| pidfd_open, pidfd_send_signal | EPERM (unchanged) | denied outright; signal it with kill |
| pidfd_getfd, ptrace, process_vm_readv/writev | EPERM in every mode (unchanged) | denied outright |
| kcmp | EPERM (**new**; Landlock's ptrace scoping already refused it towards host processes) | denied |
| fcntl F_SETOWN/F_SETOWN_EX, ioctl FIOSETOWN/SIOCSPGRP | EPERM (**new**) | denied (no SIGIO owner at all) |

**Tests.** `sim/test_fixes8.py`, class `LimitedModeProcessIsolationTests` (`:262`), has **one test per syscall**
(13 tests: the 12 syscalls of the table plus the SIGIO owner calls). The harness starts a helper in its own session
that records every signal it gets (`HELPER`, `:25`). Inside the sandbox the probe (`PROBE`, `:40`) aims the syscall at
that helper, at the launcher (`$PPID`) and at PID 1. Each attempt must get EPERM: for kill, also the helper's process
group; for tgkill, a host tid under the caller's own tgid; for fcntl/ioctl, also commands with the upper bits set.
The probe then signals its own child through the same syscall where the call is routed, or through kill where it is
denied. For the sigqueue calls the child checks `si_code=SI_QUEUE`, the sender pid and `si_value=42` with
`sigwaitinfo`; it also checks that SI_USER to the own child is EPERM, that a bad siginfo pointer is EFAULT, and that a
self-sigqueue with SI_USER is delivered. After each run `probe` (`:247`) checks that the helper is alive, received
nothing and is not traced. `NamespacedModeSignalTests` (`:306`) runs the sigqueue/kill/tgkill probes in the
namespaced mode.

**Negative control:** with the two scripts reverted to `7a25611`, exactly 3 of the 14 tests fail: rt_sigqueueinfo,
rt_tgsigqueueinfo and SIGIO owner. The other 11 were already refused before this change.

**Left as is, per the brief:** limited-mode shared memory is still the host `/dev/shm` by name. Same-uid objects are
reachable by name (no listing; DAC applies). This awaits Konrad's product decision; switching is the one line at
`verify-sandbox.py:351` (`extras = [('/dev/shm', SHM_BY_NAME)] ...`).

**Known limits (not signals):**
- The limited mode still allows non-signal calls that touch other same-uid processes: `prlimit64(pid, ...)`,
  `setpriority`, `sched_setaffinity`/`sched_setscheduler`, `ioprio_set`, `get_robust_list`, `migrate_pages`/`move_pages`.
  They are outside this brief's family; they are listed here for a later decision.
- Kernels ≥ 6.12 offer `LANDLOCK_SCOPE_SIGNAL`, which enforces this rule in-kernel (including SIGIO owners). That would
  be the cleaner path once the target hosts have it.
- Forwarding a sigqueue needs the launcher to read `/proc/<tid>/mem`. Under Yama `ptrace_scope` 0/1 the launcher (an
  ancestor) may. Under 2/3 a sigqueue to another own process returns EPERM (fails closed). A sigqueue to oneself is
  unaffected.
- `kill`/`tkill`/`tgkill` still carry the launcher as `si_pid` (fixes7 limit). The sigqueue calls now keep the caller's.
- On this 6.8 kernel `tkill`/`tgkill` report `si_code=SI_USER` even unsandboxed. The test accepts SI_USER or SI_TKILL.

## Item 2 (medium): a clear coding request anywhere in a /goal wins

`Sources/AgentApp/Models/ChatAutomation.swift:147-245`. `looksLikeCoding` (`:160`) is now
`requestsCodeInAClause(text) || firstVerbRequestsCode(text)`. The fixes7 rule is kept verbatim as
`firstVerbRequestsCode` (`:200`), so the new pass can only turn a result into coding.

`requestsCodeInAClause` (`:164`) looks for an imperative: a change or coding-only verb at a clause start. A clause
starts at the start of the text, or after `;`, `!`, `?`, a newline or a `.` followed by a space or the end
(`sentenceWords`, `:222`; `README.md` stays one word). It also starts after `,`, `so` or `please`, but only outside a
question: a sentence starting with how/what/why/is/are/do/can/... keeps its later verbs as part of the question. Lead-ins
`then`/`now`/`just`/`also`/`and` and `can/could/would/will you` may stand before the verb.

A coding-only verb there is coding. A change verb is coding when a code noun or phrase follows it in its clause, or when
its object is a pronoun (`it`, `them`, `this`, ...) and the text names code outside an about/regarding topic. New word
lists: `:153-158`; `namesCode`: `:215`.

**Swift test table**, `Tests/AgentAppTests/GoalTests.swift:271-287` (`plainGoalsAreClassifiedByTheRequestedAction`):
all 24 existing phrases are kept, plus

- **9 coding:** "The tests are failing; fix the bug", "The build is broken. Please fix it", "Tests are red so fix the
  parser", "Why does the login page crash? Debug it", "The CI is failing, please update the dependencies", "What
  changed in the API? Add a test for it.", "The README is outdated; rewrite it", "Summarize the failure, then fix the
  failing tests", "The scraper times out, can you fix it?"
- **5 general:** "How do I add tests, then fix the build?", "The tests are failing; explain why", "The build is broken.
  Please write a summary for the team", "What does the parser do? Describe it", "The meeting notes are messy; clean them
  up"

These are still single `#expect`s in a loop; no macro is nested in another.

**Python port.** The fixes7 port was never committed. It now lives in `sim/goal_classifier.py`, and its word lists are
**read from the Swift source**, so only the control flow is mirrored by hand. `sim/test_fixes8_goal.py` (6 tests):
- reads the `coding`/`general` arrays out of `GoalTests.swift` (21 + 17) and runs them through the port;
- pins the 24 fixes7 phrases independently of the Swift file (still classified the same, still in the table);
- shows the review phrase is general under the old rule alone and coding now;
- checks questions and non-code imperatives after a status clause stay general;
- checks that sentence splitting ignores dots inside words;
- checks that all ten word lists and the `||` composition exist in the Swift source.

## Item 3 (medium): skill versions bumped

- `Resources/Skills/swarmhub-coding/SKILL.md:4`: 1.3.3 → **1.3.4** (fixes7 `verify_signals.py`, limited-mode
  disclosure; fixes8 item 1).
- `Resources/Skills/swarmhub-messages/SKILL.md:4`: 1.3.4 → **1.3.5** (fixes7 completion-wake wording in
  `peer-runtime.py`).
- No change was needed in `SkillLibrary.swift`: `state` (`:157-162`) already reports `.outdated` when the installed
  semver is below the bundled one. The bump is what makes that fire.
- **New test:** `Tests/AgentAppTests/CodingSkillTests.swift:141-161`, `installsAtThePreviousSkillVersionsAreOutdated`.
  - A bot on coding 1.3.3 and messages 1.3.4 (with the matching coding variant) reads `.outdated(installed:)` for both,
    and its Update banner names `swarmhub-coding`.
  - After coding goes to 1.3.4, the banner moves to messages.
  - At 1.3.4 / 1.3.5 both read `.current` and the banner is gone.
- **Version pins updated** to the new numbers: `CodingSkillTests.swift:32, 53, 80, 190, 198` (the install-block fixture
  and record would otherwise read outdated) and `BotMessageSkillTests.swift:13, 41`. The label in
  `sim/live_managed.py:95` follows too.
- `sim/test_fixes8_skills.py` (2 tests) checks the bump here and that the Swift tests pin the same numbers.
- The `swarmhub-peer` plugin manifest version written by `peer-runtime.py:403` (1.3.3) is the plugin's own version.
  It is rewritten on every registration and is not part of skill update detection, so it was left unchanged.

## Tests run here

| Command | Result |
|---|---|
| Bypass probe before the change (limited mode, helper outside the sandbox) | rt_sigqueueinfo, rt_tgsigqueueinfo, F_SETOWN, FIOSETOWN all **delivered** (helper got 6 signals); x32 kill → SIGSYS |
| Same probe after the change | all four EPERM, helper got 0 |
| `cd sim && python3 -B -m unittest test_fixes8 -v` | 14 tests OK (13 limited-mode + 1 namespaced) |
| Same, scripts reverted to `7a25611` (negative control) | 3 failures: rt_sigqueueinfo, rt_tgsigqueueinfo, SIGIO owner |
| `cd sim && python3 -B -m unittest discover` (final tree) | **216 tests in 114.2 s, OK, 3 skips** (Darwin-native), exit 0; log `/tmp/fixes8-python.log` |
| `sh Tests/Scripts/code-job-test.sh "$PWD/Resources/Skills/swarmhub-coding/scripts/code-job"` | **22 passed, 0 failed**, exit 0; log `/tmp/fixes8-sh.log` |
| `CODE_JOB_SH=/bin/dash dash Tests/Scripts/code-job-test.sh ...` | **22 passed, 0 failed**, exit 0; log `/tmp/fixes8-dash.log` |
| Independent adversarial verifier (Sonnet, scratch repo, decoy in its own session) | **CONFIRMED**. 307 attempts against the decoy/launcher all refused: the five signal calls with junk upper bits, negative/0/-1 pids, groups (also after `setpgid` into the launcher's group), the denied calls, 64 SIGIO-owner variants, `timer_create` SIGEV_THREAD_ID (EINVAL), x32 and `int 0x80` (SIGSYS), CLONE_PARENT exit signals. Positive side: SI_QUEUE with caller si_pid and si_value intact, kill/tgkill to children and adopted orphans, subprocess timeout. Not tried: `mq_notify` (self-only by design). Logs `/tmp/f8attack-WPIuA0/` |

The 216 are fixes7's 194 plus `test_fixes8` (14), `test_fixes8_goal` (6) and `test_fixes8_skills` (2). Swift was not
compiled or run (no toolchain here). A stray, gitignored `Resources/Skills/swarmhub-messages/scripts/__pycache__`
dated before this session's runs was removed. The Swift loader bundles every file in a skill folder, so build from a
clean checkout.

The last commit only moves the signal constants (`SIGNAL_SYSCALLS`, `SIGNAL_OWNER_CALLS`, `CMD_MASK`) from
`verify-sandbox.py` into `verify_signals.py:37-42`, which keeps `verify-sandbox.py` at 497 lines. The full runs above
were made on that final tree.

## What still needs a real Mac

- `swift build`, then `swift test --filter 'GoalTests|CodingSkillTests|BotMessageSkillTests'`, in particular:
  - `plainGoalsAreClassifiedByTheRequestedAction` (38 phrases)
  - `codingLikeGoalsRequireEvidenceUnlessMarkedGeneral`
  - `installsAtThePreviousSkillVersionsAreOutdated` (new)
  - `codingSkillShipsWithItsScript`, `renderedCodingSkillCarriesThisBotsOrder`, `installTurnCarriesTheScriptAndTheVariant`
  - `installRecordsTheVariantFromTheBlock`, `messagesSkillShipsWithItsScript`, `renderedMessagesSkillSendsAsThisBot`
- Then the full Swift suite, which also covers the fixes6/fixes7 Swift tests still pending a Mac run.
- `python3 -B -m unittest sim.test_fixes8_goal sim.test_fixes8_skills -v` natively. These are pure text and should pass
  on macOS. `sim.test_fixes8`'s sandbox classes skip there; the limited mode is Linux-only.
- From fixes7, still open: a host with `apparmor_restrict_unprivileged_userns=1`, to see the real mount-EPERM path take
  the limited mode (here it is simulated).
