# Claude cross-review: swarmhub/peer-delivery 5b3c4f7..451d2df

Reviewed 2026-10-19 on the Linux box (no Swift, no macOS). This was a read-only review. No code was changed, nothing was committed, and no live Hermes, provider, gateway, provisioning or outbound operation ran.
The only file written is this report. Disposable probes ran in `/tmp`.

**Verdict: block.** The remaining fixes are small and targeted. But B1, the original blocker, is only partially closed: I
reproduced an escape from the new verification sandbox on Linux (finding 1). The Linux sandbox also fails
common verifiers, such as anything that writes to `/dev/null`, runs `git`, starts node child processes, uses asyncio, multiprocessing or subprocess timeouts (finding 2). The macOS
sandbox negative boundaries have never run natively (finding 3). B2, M1, M3 and M5 are fixed. B3, M2 and M4 are fixed in
code, but B3/M2 are proven only through an injected fake (finding 6).

## Checks run here

| Check | Result |
|---|---|
| `python3 -B -m unittest discover -s sim -p 'test_*.py'` | **158 ran, OK** (90 s; loopback allowed on this box, so no socket skips) |
| `sh Tests/Scripts/code-job-test.sh …/code-job` | **22 passed, 0 failed** |
| Disposable probes of `verify-sandbox.py` (Linux, Landlock + seccomp) | see findings 1–2 |
| Swift build/test | not run (no toolchain). The MacBook result (1344 tests, exit 0) is taken from the brief, not re-verified |
| Bot-msg socket suites, other `Tests/Scripts/*` | skipped (not needed for this delta) |

## Status of REVIEW-CODEX-3 findings

| ID | Status | Evidence |
|---|---|---|
| B1 verify runs unrestricted on host | **Partial** | `code-job:125` now goes through `verify-sandbox.py`: scrubbed env (`:107`), Landlock workspace/tmp only (`:37–49`), seccomp socket denial (`:62`), fails closed with 77. Outside writes, host reads and sockets are denied on Linux (re-probed). **But** the workspace grant includes `.git`, which gives a confirmed escape (finding 1). The claude agent path is still an unsandboxed host shell (finding 4). macOS has never been tested natively (finding 3). |
| B2 harness copies operator CLI config | **Fixed** | `sim/live_cli.py:78–92` copies only `auth.json` and generates a config with no network, no writable roots, no apps and no MCP. Env allowlist in `cli_env`. Probe uses a minimal env (`live_cli_probe.py`). Covered by `test_B2_unsafe_source_config…`. |
| B3 card not bound to runtime operation | **Fixed in code, unproven end to end** | Cards are built only from `swarmctl control get` (`ManagedControl.swift:33–46`, `AppStore+ManagedActions.swift:13–20`). The decision carries fingerprint+gate and is checked inside a `BEGIN IMMEDIATE` transaction (`swarm_policy.py:303`). The card omits some spec fields (finding 7). The real subprocess path is never tested (finding 6). |
| M1 verifier not frozen | **Fixed** | Defaults resolve at admission, before fingerprinting (`swarm_policy.py:176–182`). Managed `code-job` uses only `--verify` (`code-job:87–91`). `swarm_jobs.py:86` always passes `--verify` (possibly empty), so `check-job` compares like with like. |
| M2 failed decision suppresses card | **Fixed in code** | `decisionPending` is persisted. The card is removed only when `receipt.confirms(...)` passes (`AppStore+ManagedActions.swift:57–82`). It re-queries before deciding and clears the flag on error. Tested only with the `managedControl` fake (finding 6). |
| M3 Swift/Python intake path mismatch | **Fixed** | `ManagedActions.swift:167–170` now writes to `~/.hermes/swarmhub/secrets`. `ManagedActionsTests.swift:228–242` runs the real Swift writer against the real Python validator (no skip guard). |
| M4 all goals need coding evidence | **Fixed, with a regression risk** | `ChatAutomation.swift:42–45` and `AppStore+Goals.swift:60`: coding evidence is required only for `/goal --coding` (finding 8). |
| M5 export failure skips credential cleanup | **Fixed** | `live_managed.py:55–61` creates an ExitStack before credentials are copied. `finish()` (`:588–604`) runs every stage independently and closes resources in a `finally`. |

## Findings (most severe first)

### 1. BLOCKER: verifier can write `.git/config`, and the next host `git` runs its payload outside the sandbox
`verify-sandbox.py:39` (Linux, full `access` on the workspace) and `:85,91` (macOS, `file-write*` on the workspace subpath).
The verifier runs model-edited code with write access to `<workspace>/.git`. **Reproduced on Linux:**
`verify-sandbox.py ws 'printf "[core]\n\tfsmonitor = touch /tmp/xrev-probe/ESCAPED\n" >> .git/config'` exited 0.
A later plain `git status` on the host then created `ESCAPED`. The same works with `core.hooksPath` and `.git/hooks/*`.
Several host-side triggers exist: bots' default auto-allowed `git status` rules (`Models.swift:46–47`), the
user's own git, and later CLI runs. This is a privilege escalation: Codex's `workspace-write` sandbox protects `.git`
(the harness relies on that, `sim/live_cli.py:113`), so a Codex-edited test file can get unsandboxed host execution
through verification. That is exactly B1's threat.
**Fix:** make `.git` (and `GIT_DIR`, if outside) read-only for the verifier. On macOS add
`(deny file-write* (subpath "<ws>/.git"))` after the allow. Landlock cannot carve a sub-path out of a grant, so either
grant each top-level workspace entry except `.git` individually, or run verification in a disposable copy/worktree whose
`.git` is a read-only bind. Add a negative test that writes `.git/config` and `.git/hooks/pre-commit` from the verifier and
asserts both are unchanged.

### 2. MAJOR: Linux verifier sandbox breaks ordinary test commands (false "unverified" results)
`verify-sandbox.py:37–38`: `/dev/null` gets read-only rights (1|4|8, no WRITE_FILE). `:62–64`: denies `socketpair`, `kill`, `tgkill` and `pidfd_*`.
Probed results, all from the workspace:
- `echo hi > /dev/null` gives `cannot create /dev/null` (exit 2).
- `git status` gives `could not open '/dev/null'` (128).
- `node -e "execSync('true')"` exits 13 (libuv stdio uses `socketpair`).
- asyncio fails at loop creation (self-pipe `socketpair`).
- `subprocess.run(..., timeout=1)` gives `PermissionError` on kill.
- `multiprocessing.Pool` fails.
- `/etc/passwd`, `/etc/ssl` and `/etc/resolv.conf` are unreadable, which breaks getpwuid and TLS libraries.
Any real `pytest`/`npm test`/`make` verifier will therefore usually fail. The job then ends `unverified`/66 even when the code is
correct. The sim tests use only trivial commands, so they pass. macfix7 fixed `/dev/null` on macOS only.
**Fix:** give `/dev/null` (and `/dev/zero`, `/dev/tty` if needed) WRITE_FILE rights. Allow `socketpair` (AF_UNIX pairs
are not network; keep `socket` blocked, or allow only `socket(AF_UNIX)` via an argument filter). Allow `kill`/`tgkill` but
confine them with a PID namespace, or accept same-sandbox signalling (Landlock ABI 6 scopes signals). Add read access to
`/etc/passwd`, `/etc/group`, `/etc/ssl` and `/etc/alternatives`. Add positive regressions for `>/dev/null`, `git status`,
node spawn, asyncio and `subprocess` timeouts.

### 3. MAJOR: macOS sandbox boundaries never executed natively; profile has broad grants
On a Mac, `swift test` runs only positive smoke tests (`code-job-test.sh` and offline pattern replays). The negative cases in
`sim/test_fixes5.py` run the real sandbox only on Linux. On Darwin they inspect a mocked `subprocess.call` profile string
(MACFIX6/7 reports say so). So "outside write / secret read / network denied" has never run under `sandbox-exec`.
Profile concerns (`verify-sandbox.py:77–98`):
- Unfiltered `(allow mach-lookup)` reaches every Mach service: the pasteboard (`pbpaste` could copy the clipboard into
  verify output), LaunchServices (`open https://…` hands a URL to the browser outside the sandbox) and others. These are
  plausible exfiltration routes that bypass the network deny. **Not probed (no Mac).**
- All of `/Library` is readable.
- `PATH` and read grants exclude `/opt/homebrew`, `/Applications/Xcode.app` and `/private/var/db/xcode_select_link`. Homebrew
  toolchains and Xcode-selected `swift test` will probably fail on Apple Silicon (functional; same class as finding 2).
**Fix:** restrict `mach-lookup` to an explicit `global-name` allowlist (start empty, add only what dyld/sh/python need).
Narrow `/Library` to `/Library/Developer/CommandLineTools`. Add an opt-in toolchain allowlist. Run the existing
`VerificationTests` natively on the MacBook (`python3 -B -m unittest sim.test_fixes5`), plus `pbpaste`, `open`,
`osascript` and outside-write probes, before calling B1 closed on macOS.

### 4. MAJOR (pre-existing, undermines B1): `--order claude` gives the coding model an unsandboxed host shell at gate=auto
`code-job:273`: `claude -p … --permission-mode acceptEdits --allowedTools "Read,Edit,Write,Bash,…"` runs on the
host with the inherited environment (only `ANTHROPIC_API_KEY` is unset). Coding specs default to gate `auto`
(`swarm_policy.py:208–210`). Sandboxing the verifier does not help when the agent itself can `Bash` anything: read
credentials, edit other projects, call a real sender. This path dates from b88d4b2 (before this range). Codex runs in
`workspace-write`.
**Fix:** run claude under Claude Code's sandbox settings (filesystem restricted to the workspace, network off), or under
the same verify sandbox. Alternatively, gate `order` containing `claude`/`hermes` at `owner`. Add a test that an auto-gated claude
job cannot write outside `--dir`.

### 5. MAJOR (product): managed approvals no longer work for remote boxes
`ManagedControl.swift:68` accepts only a localhost `hermesBaseURL`. Before this range, remote runtimes worked through
the bot-turn decision path. Now every awaiting action on a remote box shows an error and can never be approved from the
app, so the action and its queue sit at `awaiting-*` forever. This fails closed (safe) and FIXES5-REPORT discloses it,
but it is a user-visible regression that needs explicit sign-off.
**Fix:** reuse the app's existing SSH box channel to run `swarmctl control get|decide` remotely (same JSON contract), or
surface a clear "approve on the runtime host" state with an expiry. In either case, add a test for the remote case.

### 6. MAJOR (test fake hides the real path): `ManagedLocalControl` is never exercised
Every B3/M2 Swift test injects `store.managedControl` (`AppStore+ManagedActions.swift:33`), and nothing references
`ManagedLocalControl` (`grep -rn ManagedLocalControl Tests/` is empty). The following are therefore untested:
- the real subprocess path: profile path, HERMES_HOME, PATH with `/usr/bin/env python3`, stdin JSON;
- decoding real `swarmctl control get` output into `ManagedRecord` (e.g. `decided_at` as float, `spec` nested object);
- the receipt after `control decide`.
Live passes 8/9 used the harness action bridge, not the app (LIVE-REPORT-9 grades "at the managed-runtime boundary").
**Fix:** add one Swift test that installs the real `swarmhub-messages` scripts into a temporary `HOME/.hermes/profiles/<p>`,
submits an owner-gated FAKE action with `swarmctl submit`, then drives `ManagedLocalControl.request` through get → card →
decide → receipt. Include a stale-fingerprint rejection.

### 7. MINOR: approval card omits spec fields the runtime fingerprints
`ManagedControl.swift:5–21`: `Spec` decodes and renders only known keys. `speculative`, `origin`, `parent` and `request` are
dropped from the displayed JSON while still being covered by the fingerprint. None changes argv today
(`request` is embedded in the provision argv, and `speculative` only checks policy, `swarm_policy.py:132–136`), but the card
no longer shows "exactly what will execute" once a field gains meaning.
**Fix:** render the raw `spec` object from `control get` (e.g. as `[String: JSONValue]`) instead of a lossy struct.

### 8. MINOR: plain `/goal` silently drops coding evidence; general goals accept any non-empty reply
`AppStore+Goals.swift:60`: evidence is required only with the literal `--coding ` prefix. Coding goals users start as
`/goal fix the build` used to require a commit/test; now any non-empty visible reply with a `done` block completes them
(`ChatAutomation.swift:44`).
**Fix:** treat the goal as coding when the bot delegates through `swarmhub-coding` or the text hits coding keywords, or
make the composer offer the toggle. At minimum, show "unverified (general goal)" on the done card for coding-like text.

### 9. MINOR / residual trust model: the deciding profile's own model can still approve without the human
`swarmctl:32–36` keeps the legacy `decide` command, and `swarm_policy.py:285–297` checks only `HERMES_HOME`. Its docstring
admits this is "not authentication against a hostile shell". The coordinator/owner profiles are bots, so their model (or
any same-user process that sets HERMES_HOME) can approve real outbound or owner-gated work without the app card.
This predates the range and Codex accepted it, but the new card UI implies human-only approval.
**Fix:** state the trust model in SKILL.md/README. Optionally drop `decide` from the bot-installed skill and keep only
`control decide`, run by the app. Real enforcement needs a separate Unix user or app-held secret.

## Delta scan (fixes5, live 8–9, macfix3–7)

- **Hermes itself:** not modified. `git diff --name-only 5b3c4f7..HEAD` touches no Vendor/Hermes core paths.
  `peer-runtime.py` is SwarmHub's own plugin installer (it writes the profile plugin dir), as Codex noted.
- **Outbound:** every harness outbound is `fake: true` (`live_managed.py:438,452,497–503`). The provisioner is a synthetic
  local script. A real outbound needs an owner-published `outbound` hook plus a coordinator decision
  (`swarm_policy.py:237–249`); no test configures one. Finding 1/4 are the routes around the record mechanism.
- **Secrets:** intake is 0600 under `~/.hermes/swarmhub/secrets`. Harness credentials are now private and always deleted.
  The verifier env is scrubbed. No secret material was found in the diffs reviewed (sim/results JSON not exhaustively scanned).
- **macfix3–5:** `@MainActor` closure type and GoalTests restore are fine. macfix5 is a purely mechanical unwrap of nested
  `#require` inside `#expect`, with no assertions dropped (sampled the whole diff). `withKnownIssue` usage is unchanged
  (TestRunGuard/KeyVault only).
- **macfix6/7:** the new grants (`file-map-executable` on runtime and workspace, a literal `/` read, a `/dev/null` write) are
  narrow and justified. The broad grants that remain are in finding 3.

## Unblock criteria

Fix 1 and 2 with regressions. Fix 3's mach-lookup allowlist and run the sandbox negatives natively on the MacBook. Either
fix 4 or gate claude/hermes orders at owner. Add the real `ManagedLocalControl` test (6). Get explicit sign-off on 5.
Findings 7–9 can follow.

Verdict: block
