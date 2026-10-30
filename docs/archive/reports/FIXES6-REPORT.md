# Fixes 6: closing REVIEW-CLAUDE-XREV (verdict: block) on swarmhub/peer-delivery

Base: 7f4c2fb. Work: 868a070 (findings 1–4), e293bee (findings 6–8) and a third commit with the fallback symlink fix and this report. Done on the Linux box
(Ubuntu 24.04, kernel 6.8, Landlock ABI 4, libseccomp, unprivileged user namespaces allowed). No Swift toolchain
here: Swift changes are compile-safe by inspection only (no nested `#require`/`#expect`), and the Mac run list is at
the end. Hermes itself is untouched (`git diff --name-only 7f4c2fb..HEAD` has no Vendor/Hermes paths). Every test
outbound stays FAKE; no live Hermes, provider or network call ran.

## Finding 1 (blocker): verifier could write `.git`

`Resources/Skills/swarmhub-coding/scripts/verify-sandbox.py`

- Linux (`linux_child`, :232): the launcher's child enters a user+mount+PID namespace (`unshare`, :99, uid/gid
  mapped onto the caller), makes mount propagation private, bind-mounts `<ws>/.git` over itself read-only, mounts a
  private `/proc` and `/dev/shm` (`private_mounts`, :120), then enters a nested user namespace so the inherited mounts
  are locked (the verifier cannot remount `.git` even if it had mount rights), then applies Landlock + seccomp. The
  `mount` family, `unshare`, `setns`, `pivot_root` and `clone` with namespace flags are denied by seccomp as well
  (`seccomp`, :172).
- Linux fallback without unprivileged user namespaces (e.g. a stock Ubuntu 24.04 desktop with
  `kernel.apparmor_restrict_unprivileged_userns=1`, containers): the workspace root is read-only and each existing
  top-level entry is granted individually, `.git` read-only (`workspace_rules`, :212). New top-level entries and
  signals to other processes are then denied; a stderr line says so. There is still no unsandboxed fallback.
- A linked worktree's gitfile, gitdir and commondir are parsed by hand (`git_dir`, :63; running git in the launcher
  would execute the very config under protection) and granted read-only; on macOS they are denied for writes.
- macOS (`darwin_profile`): `(deny file-write* (subpath/literal "<ws>/.git"))` and the gitdir after the workspace
  allow (:311–312; later rules win in SBPL).
- `code-job:103`: code-job's own evidence git runs as `git -c core.fsmonitor=false -c core.hooksPath=/dev/null`, so
  even an agent that had a host shell (finding 4) cannot make code-job's `rev-parse`/`merge-base` execute planted
  settings.

Tests (`sim/test_fixes6.py`, `GitMetadataEscapeTests`): a host control proves the escape is real on this git
(2.43: a planted `core.fsmonitor` runs on `git status`); under the sandbox every variant fails (config append, hook
file, `git config`, `core.hooksPath`, python append, rename/remove/replace `.git`, symlink to /tmp), `.git/config`
is byte-identical, hooks absent, and a later host `git status` creates no marker; linked worktree gitdir/commondir
read-only; `LandlockFallbackTests` repeat the core checks with `SWARMHUB_VERIFY_NAMESPACES=0`.

## Finding 2: Linux sandbox broke ordinary verifiers

Same file. `/dev/null`, `/dev/zero`, `/dev/full` writable (`WRITABLE_DEVICES`); `/etc/passwd`, `group`,
`nsswitch.conf`, `hosts`, `resolv.conf`, `ssl`, `ca-certificates`, `alternatives`, `os-release`, `python3*`
readable (`READABLE`); inside the namespace `kill`/`tkill`/`tgkill`/`pidfd_*` are allowed (they cannot reach host
pids: `kill -0 <host pid>` is "No such process"); `socketpair` allowed for `AF_UNIX` only (argument filter);
`socket`/`connect`/`bind`/`listen`/`accept` stay denied; `clone3` returns ENOSYS so glibc falls back to `clone`,
which is filtered for namespace flags. Private `/proc` (read) and `/dev/shm` (tmpfs, needed by multiprocessing
semaphores). In the fallback mode signals remain denied (no namespace to confine them) and `/proc` stays hidden.

Tests (`OrdinaryVerifierTests`): a unittest module run with `/usr/bin/python3 -m unittest` inside the sandbox
(5 tests: `/dev/null` + `git status`/`rev-parse`, `asyncio` subprocess, `multiprocessing.Pool`, `subprocess.run`
timeout killing its child, self-signal), a node script (`execSync`, `spawnSync` with timeout → SIGTERM, piped
`spawn`), shell redirections + git, and the negatives (INET and UNIX sockets, host pid signal, `~/.bashrc`).
pytest itself is not importable inside the sandbox (HOME is scrubbed, user site-packages invisible), so the
"pytest-style" check is a unittest module; a project with pytest in its own venv under the workspace would work.

## Finding 3: macOS profile too broad; negatives never run natively

`darwin_profile`: `(allow mach-lookup)` replaced by an explicit allowlist (`DARWIN_MACH_SERVICES`, :277:
opendirectoryd libinfo, DirectoryService libinfo_v1, system logger, notification_center). Not granted: pasteboard
(`com.apple.pasteboard.1`), LaunchServices (`launchservicesd`, `lsd.mapdb`), AppleEvents, SecurityServer/trustd
(keychain/TLS), cfprefsd. `/Library` narrowed to `/Library/Developer`, `/Library/Frameworks`, `/Library/Apple`;
`/opt/homebrew` and `/Applications/Xcode.app` readable+executable (toolchains, no user secrets), PATH gains
`/opt/homebrew/bin`; `/private/var/db/xcode_select_link` and `/private/var/select` readable. Added
`(allow signal (target same-sandbox))`, `ipc-posix-sem`, `ipc-posix-shm*`, `/dev/zero` write. `(allow process*)`
and `sysctl-read` stay (not exfiltration routes; noted).

Tests: `DarwinProfileTextTests` (run everywhere) assert the allowlist, the absent services, the narrowed `/Library`,
and that the `.git`/gitdir deny follows the workspace allow. `DarwinNativeSandboxTests` (skipped off macOS) run the
real `sandbox-exec`: a `bootstrap_look_up` ctypes probe must resolve `opendirectoryd.libinfo` (positive control) and
must fail for pasteboard, launchservicesd, appleevents, SecurityServer, cfprefsd, lsd.mapdb; outside write, secret
read and a loopback connect must fail. The probe only looks services up; it never opens a URL or reads the
clipboard, so a broken sandbox cannot cause side effects on the Mac. **Needs the real-Mac run (below).**

## Finding 4: `--order claude` = unsandboxed host shell at gate auto

Design chosen: gate, not sandbox. Claude Code needs network for its API, so the verify sandbox cannot host it, and
Claude Code's own bubblewrap/seatbelt settings cannot be verified here. So:

- `swarm_policy.py:27,48,58–59`: new policy key `coding_gate` ∈ {owner, auto}, default **owner**. `:213–217`:
  every `kind: coding` spec waits for the owner unless the owner published `auto`; an order containing `claude`
  returns `owner` regardless of policy. Risks still force owner.
- `swarm_jobs.py:32–35`: `check-job` refuses an order containing claude unless the record's gate is `owner` and it
  carries `decided_by` (covers records admitted before this rule or edited in the DB).
- `code-job:326–329`: claude is only started for a managed task (`--task-id`) whose control interface exists and
  whose `check-job` passed; a direct run (or a task id without the control interface) skips it with
  `skipped claude: approval` and continues with codex/hermes. `hermes` stays as it was: it delegates to the bot's
  own tools, which is the bot's existing authority, not an escalation.
- Docs: `swarmhub-coding/SKILL.md` (the Claude Code paragraph after the exit codes, and the verification-authority
  paragraph), `swarmhub-messages/SKILL.md` (policy paragraph).
- Existing fixtures: `sim/test_peer_runtime.py` `PeerTests.setUp` publishes `coding_gate: auto` (the shared fixture
  exercises the owner's explicit automatic Codex route); `sim/test_review_fixes.py` `coding()` (order claude) now
  has the fixture owner decide first. The shell suite's claude cases run as managed tasks through a stub control
  interface (`Tests/Scripts/code-job-test.sh`, `with_control`/`managed`); the shard list is unchanged (22 cases).

Tests (`sim/test_fixes6_policy.py`): shipped default is owner (fresh HOME subprocess) and other values are rejected;
a codex task waits, does not launch on tick, runs after the bound owner decision; with `auto`, codex is queued but
`claude`, `claude,codex`, `codex,claude,hermes` wait; an approved claude task runs the stub claude bound to its
record; a denied one never launches; `check-job` refuses a gate-auto/undecided claude record and the launcher's
refusal marks it failed; a direct `code-job --order claude,codex` skips claude and runs codex.

## Findings 6–8

- **6** `Sources/AgentApp/Models/ManagedControl.swift:116`: `ManagedLocalControl.request(..., home:)` (default is
  the account home, unchanged); `AppStore.managedHome` (`AppStore.swift:25`) injects it
  (`AppStore+ManagedActions.swift:37`). `Tests/AgentAppTests/ManagedLocalControlTests.swift`: a temporary HOME with
  the shipped `swarmhub-messages/scripts` as the `coordinator` profile's skill, `swarmctl policy set` +
  `swarmctl submit` of a FAKE owner-gated prod action (`speculative:false` included), then (:74) direct
  `control get` → record fields → card → stale-fingerprint `decide` refused → `get` unchanged → bound `decide` →
  receipt `confirms`; non-local address and a profile without the script are refused. (:110) the AppStore path:
  a lying fence (kind read, gate coordinator) → `routeManagedApprovals` → card shows the prod record → 
  `decideManagedAction` → card removed, audit approved, runtime record `decided_by: coordinator`. The detached
  worker swarmctl starts is stopped via its pid files in `stop()`.
- **7** `ManagedControl.swift:7–47`: `ManagedRecord.Spec` holds the raw object (`fields: [String: JSONValue]`,
  custom Codable, typed accessors; convenience init keeps the old test shape); the card renders every field
  (`request(botID:)`). `JSONValue` gains `Decodable` (:78). Persisted cards decode unchanged (same JSON shape).
- **8** `ChatAutomation.swift:42` `GoalRun.requiresCodingEvidence = codingEvidence ?? looksLikeCoding(text)`;
  `:51 doneDetail`; `GoalProtocol.codingWords`/`looksLikeCoding` (word-boundary keyword match plus "pull request");
  `AppStore+Goals.swift:60–65`: `--coding` → true, `--general` → false, plain → nil. First turn, evidence request,
  cards and the blocked `need` use `requiresCodingEvidence`; an explicitly general goal with coding-like text gets
  "Unverified (general goal): …" on its done card. Goals persisted with `codingEvidence == false` by the fixes5 build
  are treated as explicitly general. Tests: `GoalTests.swift:270` (`looksLikeCoding`, `accepts`, protocol text,
  `doneDetail`) and `:285` (plain coding-like goal is sent back for evidence, `--general` completes with the
  unverified wording).

## Left as is (owner's call)

- **5 remote-box approvals**: unchanged. `ManagedLocalControl` still accepts only a localhost `hermesBaseURL`; an
  awaiting action on a remote box shows "Managed approval requires SwarmHub's local control interface…" and cannot
  be approved from the app.
- **9 deciding profile's model**: unchanged. `swarmctl decide` remains, `decide()` checks only `HERMES_HOME`;
  any same-user process that sets it can approve. The messaging SKILL.md already states the trust model.

## Independent verification (after the two commits)

A read-only verifier agent re-ran everything from scratch dirs and tried to disprove the claims. It confirmed
findings 2–4 and the suites, and it **refuted the fallback mode once**: a workspace symlink planted before the run
(`ln -s .git/config link` on the host, then `printf x >> link` under `SWARMHUB_VERIFY_NAMESPACES=0`) appended to
`.git/config`. Cause: the per-entry grant opened each top-level entry with `O_PATH` following symlinks, so the rule
was attached to the link's target. Fix (third commit): `workspace_rules` skips symlinked entries, which then resolve
against their target's own rules (`verify-sandbox.py`, the `is_symlink` check). Re-probed: the committed launcher
before the fix returned 0 and changed the file; after the fix exit 2 and the file is unchanged. New regressions:
`test_symlinks_to_git_metadata_cannot_be_written_through` (planted relative/absolute/dir links and links created by
the verifier, default mode) and `test_fallback_denies_writes_through_planted_symlinks` (fallback). The namespaced
default mode was never affected (the target sits on the read-only mount). The suites below were re-run after the fix.

## Tests run here

| Suite | Result |
|---|---|
| `python3 -B -m unittest discover -s sim -p 'test_*.py'` | **183 ran, OK, 3 skipped** (the Darwin-native class), re-run after the symlink fix |
| `python3 -B -m unittest sim.test_fixes6 -v` | 18 tests: 15 OK, 3 skipped (Darwin) |
| `python3 -B -m unittest discover -s sim -p test_fixes6_policy.py -v` | 7 OK |
| `sh Tests/Scripts/code-job-test.sh …/code-job` | **22 passed, 0 failed** |
| `CODE_JOB_SH=/bin/dash dash Tests/Scripts/code-job-test.sh …/code-job` | **22 passed, 0 failed** |
| Swift build/test | **not run** (no toolchain) |

## Needs the real Mac

Run from the repo root on the MacBook:

```
python3 -B -m unittest sim.test_fixes6 -v
swift build && swift test --filter 'ManagedLocalControlTests|GoalTests|ManagedActionsTests|CodingSkillTests'
swift test
```

- `sim.test_fixes6` runs the Seatbelt profile natively: `DarwinNativeSandboxTests` (mach allowlist positive
  control and denials, outside write, secret read, loopback connect) plus `GitMetadataEscapeTests` and
  `OrdinaryVerifierTests` under `sandbox-exec` (`.git` deny, `/dev/null`, `git status`, node children, python
  asyncio/multiprocessing/timeouts, signals). If `socketpair`, `ipc-posix-sem` or a Mach service the toolchain needs
  turns out to be missing, the failing test names the operation; add only that grant.
- Swift tests new or changed: `realControlGetCardDecideAndReceiptBindTheRuntimeRecord`,
  `theAppApprovesARealRuntimeRecordThroughSwarmctlAndRemovesTheCardOnItsReceipt` (ManagedLocalControlTests),
  `codingLikeGoalsRequireEvidenceUnlessMarkedGeneral`, `aPlainCodingLikeGoalIsSentBackWithoutEvidenceAndGeneralOptsOut`
  (GoalTests); unchanged but affected by the `Spec` change: all of `ManagedActionsTests`; the shell shards in
  `CodingSkillTests` (`codeJobShellTestPasses`, `codeJobShardsCoverEveryCaseOnce`).
- Skill versions were not bumped (1.3.3), as in the previous passes; `CodingSkillTests` and
  `test_peer_runtime.py:342` pin that string.
