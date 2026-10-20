# Core integration (coreInt1)

Branch `swarmhub/core-integration`, worktree `/home/ubuntu/work/swarmhub/wt-coreint1`, base `swarmhub/core-plan`
(`f0d243c`, contained in every core branch; sysprompt1 sits on the older `749d826`, which core-plan contains).
Approved by Konrad 2026-10-20 19:53. Nothing merged to main, nothing deployed, Hermes untouched, TEST keys only,
no iOS build or test run (iOS suspended).

Every local head equals its GitHub head (`git ls-remote`, 2026-10-20), and every pinned commit is the branch head:
p2c `a0fb6cb`, p2d `618eb9d`, p3a `10d8f88`, p4b `1f1d463`, p4c `3361182`, p5d `775328b`, p6b `5c64184`,
p7c `e0c9e64`, p8a `3d2e5f5`, sysprompt1 `7cd8a14`. After the merges, `git merge-base --is-ancestor` confirms all
25 heads are in HEAD.

## Merge order (`--no-ff`, dependency order; no branch was already contained when its turn came)

| # | Branch | Head | Merge commit | Conflicts |
| --- | --- | --- | --- | --- |
| 1 | core-p0a | 0b9a78f | bf4a485 | none |
| 2 | core-p0b | afa3131 | 22c39aa | none |
| 3 | core-p0d | c750627 | ac21f56 | none |
| 4 | core-p1a | d341c9a | b59e73b | none |
| 5 | core-p1c | d0677aa | 719b652 | none |
| 6 | core-p5a | b924c92 | 8ccdb64 | none |
| 7 | core-p5b | 54d26f8 | e731d0d | none |
| 8 | core-p0c | 2c07833 | 6a181ec | none |
| 9 | core-p4a | 4fb9740 | 5b153b4 | none |
| 10 | core-p5c | e784fd7 | 66cfdf6 | none |
| 11 | core-p5d | 775328b | 49c068d | none |
| 12 | core-p6a | 0c5f2ae | d984c94 | none |
| 13 | core-p7a | 61453f3 | 6ebdc52 | SCHEMAS.md |
| 14 | core-p7b | 248f12b | b3891a5 | SCHEMAS.md |
| 15 | core-p7c | e0c9e64 | bd7cf3f | iOS app + project |
| 16 | core-p6b | 5c64184 | 96469c6 | none |
| 17 | core-p2a | 8e6583c | 08c6bf8 | none |
| 18 | core-p2b | 19ed7d1 | 90d94af | skill pins |
| 19 | core-p2c | a0fb6cb | 5a2653d | iOS generator/project, BotWorkTests |
| 20 | core-p2d | 618eb9d | a97123f | none |
| 21 | core-p3a | 10d8f88 | 9b4882e | none |
| 22 | core-p4b | 1f1d463 | af95431 | skill pins |
| 23 | core-p4c | 3361182 | f46ad5c | none |
| 24 | core-p8a | 3d2e5f5 | b4d2f05 | skill pins, render goldens |
| 25 | sysprompt1 | 7cd8a14 | 8ed3bed | iOS MobileStore, generator/project |
| – | integration fixes | | 528e82c | semantic (see below) |

Commits use the noreply identity, with no Claude trailer (SwarmHub rule).

## Conflicts and resolutions

- **docs/update-service/SCHEMAS.md (p7a, p7b):** P6a §12 and P7a §13 both appended after §11. Kept both, in order,
  and dropped P7a's "§12 is on the P6a branch" aside. The result is byte-identical to core-p6b's own merge through §13,
  and to core-p7b's file after the P7b renderer section.
- **Apps/iOS/Sources/SwarmHubApp.swift (p7c):** keeps P5d's `.environment(managed)` and adds P7c's `.environment(\.sduiViewSource, SDUIiOS.installed)`.
- **scripts/generate-ios-project.py (p2c, sysprompt1):**
  - Build phases are `boundary, sources, frameworks, resources, baseline`. P5d's approval check still runs first (asserted by the test), and P2c's baseline embed still runs last, before signing.
  - The sandboxing comment now names both script phases.
  - sysprompt1's hosted `SwarmHubTests` target is added to the same generator.
- **Apps/iOS/SwarmHub.xcodeproj/project.pbxproj (p7c, p2c, sysprompt1):** never hand-merged. Each time it was regenerated with
  `scripts/generate-ios-project.py`; the test asserts the project is current and deterministic.
- **Apps/iOS/Sources/MobileStore.swift (sysprompt1):** `init(storageDirectory:)` from sysprompt1, with P6b's `appConfig = AppConfig.load()` after the capture early-return.
- **Tests/AgentAppTests/BotWorkTests.swift (p2c):** kept P6b6's explicit `as [String]` / `as [String?]` types, the Mac type-check fix for the ambiguous `==`. The values are unchanged.
- **Skill version pins (p2b 1.3.10, p4b 1.4.0, p8a 1.4.5 vs HEAD 1.4.5 from p5d):** took the highest, **1.4.5**, in
  `SKILL.md`, `BotMessageSkillTests.swift`, `CodingSkillTests.swift` and `sim/test_fixes8_skills.py` (previous 1.4.4 → 1.4.5).
  Every auto-merged body change is kept: P5c/P5d device approvals, P2b `swarmctl update-status`, P5b devices.
  - **Collision to resolve before any release:** core-p5d's 1.4.5 and core-p8a's 1.4.5 already had different scripts, and the integrated 1.4.5 is a third combination. A box holding either earlier 1.4.5 would show "current" and never get the rest. Recommendation: bump swarmhub-messages to 1.4.6 on this branch before publishing anything. Not done here because the brief said "take the highest".
- **Render goldens `Tests/Fixtures/release-bundles/renders/swarmhub-messages/*/any-order/SKILL.md` (p8a):** took
  p8a's Swift-final goldens. The integrated `SKILL.md` is byte-identical to p8a's, so no regeneration was needed. Only the scripts differ, and they have no goldens. `Tests/Updater/test_render.py` passes against them, and no PROVISIONAL marker was added.

### Semantic integration fixes (commit 528e82c)

Seven failures in `scripts/` appeared only on the integration. Each source branch passes the same modules alone: p5d boundary 15 OK, p2c/p2d app_content 5 OK.

1. **Policy schema (P2c/P8a × P6a):** P6a renamed the policy document schema to `swarmhub/config-policy/1`, and the apps
   refuse any other schema (SCHEMAS §12). `scripts/test_app_content.py`, `Packages/SwarmHubCore/Tests/.../AppContentTests.swift`
   and `scripts/release/drill_world.py` still expected `swarmhub/policy-defaults/1`; they now use the P6a name.
2. **iOS approval boundary (P5d × P7c, sysprompt1):** `check-ios-approvals.py` assumed flat `Sources/*.swift`. P7c adds
   `Sources/SDUI/`, which the checker did not scan, and sysprompt1 adds a hosted test target, `Tests/*.swift`. This makes the check stricter:
   - It now expects exactly what the generator compiles: Sources/ recursively and Tests/ at the top level.
   - All of those files are scanned for shared-key symbols.
   - The Hermes key-store rule covers approval files at any depth under Sources/.
   - Any other compiled path still fails (`..`, nested Tests, other folders).
   - New negative tests cover each of these. The fixture copy now includes `Apps/iOS/Tests`.
3. **`test_native_hermes_approval_path_is_unchanged` (P5d × P2c, P6b, sysprompt1):** it asserted the whole of
   `MobileStore.swift` equals `b3a5617`, which no integration can satisfy because three branches edit other parts of that file. It now asserts that:
   - `resolve`, `checkApproval` and `remember` are byte-identical to b3a5617;
   - every base line mentioning approvals is still present, in order.

   A mutation test (editing the decline notice, or dropping an approval-clearing line) fails it. **This is a narrower check than whole-file identity. Konrad should accept or reject it.**

## Tests (Linux, `PYTHONDONTWRITEBYTECODE=1`, final tree 528e82c)

| Suite | Result |
| --- | --- |
| `python3 -m unittest discover -s scripts -p 'test_*.py'` | **608 tests OK**, 1 skipped (macOS-only libcommonCrypto vector) |
| `python3 -m unittest discover -s Tests/Updater -p 'test_*.py'` | **204 OK** |
| Remote/device approvals `discover -s sim -p 'test_*approvals*.py'` | **71 OK** |
| `sim/test_fixes8_skills.py`, `sim/test_prompt_sync.py` | 2 OK, 9 OK |
| `make_vectors.py --check`, `make_config_vectors.py --check`, `make_ui_vectors.py --check`, `make_ui_renders.py --check`, `approvals/device_approval_vectors.py --check` | all byte-identical |
| `Tests/Scripts/updater-bootstrap-preflight-test.sh` under sh, dash, bash, zsh | 33 passed, 0 failed, 0 skipped each |
| `Tests/Scripts/updater-bootstrap-test.sh` | Docker not installed. Ran `BOOTSTRAP_TEST_MODE=fallback`: 36 passed, 0 failed, 2 skipped |
| `git diff --check core-plan..HEAD` | clean |
| Source files over 500 lines among files changed vs core-plan (excluding fixtures/json/md) | none |

No `__pycache__` was left in the tree, and no containers were created.

## The MacBook must run (Swift cannot build here; iOS stays skipped)

1. `PYTHONDONTWRITEBYTECODE=1 swift test` at the repo root (AgentApp). This includes `RenderGoldenTests` (must change no golden), `BotMessageSkillTests`, `CodingSkillTests`, `BotWorkTests`, the SDUI renderer/action golden tests, the routine pixel tests, `BotPromptSyncIntegrationTests`/`SystemPromptTests`, and staged install and managed remote control.
2. `PYTHONDONTWRITEBYTECODE=1 swift test --package-path Packages/SwarmHubCore`, including `AppContentTests` (now `config-policy/1`), `UpdatePinTests`, the config/SDUI decoders and `ManagedApprovalFlowTests`.
3. `PYTHONDONTWRITEBYTECODE=1 python3 scripts/test_mac_device_approvals.py -v`, and the scripts suite once on macOS (it un-skips the libcommonCrypto vector).
4. `sh Tests/Scripts/updater-bootstrap-preflight-test.sh` on macOS (the Darwin `xcrun` and library paths).
5. Not run: `scripts/test-ios-core.sh`, `scripts/test-ios-sdui.sh` and any `xcodebuild` (iOS suspended). The regenerated iOS project and the iOS sources from P5d, P7c and sysprompt1 have not been compiled together.

## coreInt2 fixes

2026-10-20, on `swarmhub/core-integration`, starting at `0bb9686`. This section supersedes the narrower
MobileStore check and unresolved 1.4.5 collision described above. Main and Hermes are untouched, nothing was
pushed or deployed, signing uses TEST keys only, and no iOS builds or runtime tests were run.

1. **Approval boundary restored.** `scripts/test_ios_approval_boundary.py` now compares the complete raw-byte diff
   of `Apps/iOS/Sources/MobileStore.swift` against `b3a5617` with the frozen, enumerated diff in
   `Tests/Fixtures/ios-mobile-store-allowed-diff.json`. The only exceptions to baseline identity are exactly:
   - P2c (`a0fb6cb`): the `appContent` declaration.
   - P6b (`5c64184`): the `appConfig` declaration/comment and `AppConfig.load()` in initialization.
   - sysprompt1 (`7cd8a14`): prompt-sync state, `init(storageDirectory:)` and local loading, retry/dismiss,
     client invalidation/context, explicit prompt edits and synchronization.

   No other byte may change, inside or outside approval functions, including whitespace, line endings and EOF;
   even the listed additions are pinned exactly. A missing baseline now fails instead of skipping the check.
   The existing ApprovalsView assertions remain. Eight negative mutations cover unrelated state, credentials,
   the decline notice, approval clearing, a listed addition, CRLF, appended text and a missing final newline.
   MobileStore itself is unchanged from the initial HEAD.

2. **Skill collision resolved.** `Resources/Skills/swarmhub-messages/SKILL.md` is now **1.4.6**. Updated version pins
   in `BotMessageSkillTests.swift`, `CodingSkillTests.swift` and `sim/test_fixes8_skills.py`; installs at 1.4.5
   explicitly remain outdated until updated to 1.4.6. Audited complete tracked skill trees against all 25 listed
   source heads, including manager recipes/prompts: coding 1.3.12, feedback 1.0.0 and manager 1.2.0 each match all
   25 source heads at their version. Messages matched neither P5d nor P8a at 1.4.5; no other skill needs a bump.

   Added and used `Tests/Updater/test_render.py --refresh-versions` to regenerate the three messages goldens with
   the repository renderer. It validates the entire Swift-final file set before writing and permits only an
   increasing frontmatter version and matching advertised version. Every other byte, including bodies and
   references, must stay identical. Negative tests reject body/header/reference/file-set changes, downgrades,
   and provisional input, before any write. Documented the command in the render README. No generated golden
   was hand-edited and no PROVISIONAL marker was added or removed. Ran all five vector generators normally and
   with `--check`; generated pins and vectors remain byte-identical.

3. **Actual Linux verification output.** Saved merged stdout/stderr, commands, timestamps and exit statuses in
   [coreInt2-tests.log](coreInt2-tests.log), at `/home/ubuntu/work/swarmhub/wt-coreint1/coreInt2-tests.log`.
   The requested `/home/ubuntu/work/swarmhub/coreInt2-tests.log` cannot be written: the sandbox returns
   `OSError: [Errno 30] Read-only file system`. All Python runs used `PYTHONDONTWRITEBYTECODE=1`.

| Command/suite | Observed result |
| --- | --- |
| `python3 -m unittest discover -s scripts -p 'test_*.py'` | **609 run**, 3 failures, 6 errors, 1 skipped |
| `python3 -m unittest discover -s Tests/Updater -p 'test_*.py'` | **206 run**, 24 errors (includes both proxy subtests of one test) |
| `python3 -m unittest discover -s sim -p 'test_*approvals*.py'` | **71 run**, 1 error |
| Final focused boundary, complete render and skill-version suites, verbose | **36 run, OK** |
| `sim.test_fixes8_skills` and `sim.test_prompt_sync` | **11 run, OK** |
| `make_vectors.py`, `make_config_vectors.py`, `make_ui_vectors.py`, `make_ui_renders.py`, `device_approval_vectors.py`, each `--check` | **5/5 byte-identical**, exit 0 |
| `updater-bootstrap-preflight-test.sh` under sh, dash, bash, zsh | **33 passed, 0 failed, 0 skipped each** |
| `BOOTSTRAP_TEST_MODE=fallback sh Tests/Scripts/updater-bootstrap-test.sh` | Exit 1 **before any cases**: `mktemp` under `/home/ubuntu` is read-only |
| `git diff --check`; added allowlist fixture whitespace check | Clean |
| Source line limits vs core-plan | **318 changed source files checked, none over 500 lines** |

All 31 unittest error records are socket creation refused by the sandbox (`PermissionError: [Errno 1]
Operation not permitted`); the three scripts failures are drill assertions reporting that same refusal instead
of their expected outcomes. These runs are **not all-green verification**. The local HTTP/TLS fixture tests and
bootstrap fallback must be rerun where local sockets and the test home directory are writable; checks were not
skipped or weakened to hide these restrictions. The final 36-test focused run verifies the JSON-encoded
allowlist after its final formatting, all render goldens and the 1.4.5 → 1.4.6 expectation. The Mac checks above
remain pending, with updated 1.4.6 Swift expectations; iOS remains suspended.

`__pycache__` cleanup completed: none remain in the worktree. No generated pins, vectors or Hermes files changed.

**Commit: uncommitted.** Attempting `git add -- scripts/test_ios_approval_boundary.py` returned:
`fatal: Unable to create '/home/ubuntu/work/swarmhub/peer-review/.git/worktrees/wt-coreint1/index.lock': Read-only file system`.
The sandbox blocks Git metadata writes, so changes are left unstaged on this branch; no push was attempted.

## coreInt4: merge of GitHub main

2026-10-20, on `swarmhub/core-integration`. Fetched `https://github.com/conrader/swarmhub.git main`, and
FETCH_HEAD was `5dba61a0f95404b78c39c0b9313e1c9130710d43` as expected (0.5.7–0.5.9, P50–P56; 72 commits
since the merge base `ed9c70a`). Merged `--no-ff` as **`9bc5bde`** (parents `b030b3b`, `5dba61a`). Main and every
remote branch are untouched, and nothing was pushed or deployed. Hermes and iOS are unchanged, and no `codex exec` was run.

### Conflicts and resolutions (exactly the six expected; no others)

Each one was a single hunk. Every resolution keeps both sides:

- **README.md:** core-integration's condensed overview against main's rewording of the "No reply is lost" bullet
  (e8f0c22, to "Reply recovery … can recover available server history"). Kept the condensed overview. It has no
  such bullet, so main's softer claim went into `docs/FEATURES.md` (Conversations bullet). The overview's
  branch-state sentence ("does not contain the 0.5.7–0.5.9 code changes", "builds and tests pass on a Mac") was
  false after this merge, so it now says the changes are included and that the merged code has not been built on a Mac.
  For the same reason, FEATURES.md's header notes were updated: connected-app reads now follow 0.5.8, and Draft Send
  still records a test action, which is still true (`ManagedActions.swift`, outbound FAKE). Main's auto-merged
  "Team coordination" heading change is kept.
- **Sources/AgentApp/Models/GroupChat.swift (`StoreFile`):** our `managedApprovals` (persisted verified managed
  cards) and P50's `scrollPositions` are both in the memberwise init, the assignments and `CodingKeys`. Both
  decoders auto-merged. `managedApprovals` keeps its strict `try` decode and `scrollPositions` keeps its tolerant `try?`.
- **AppStore+ModelPolicy.swift (`storeFile`):** passes `managedApprovals:` (only managed cards; nil while empty)
  and `scrollPositions: chatScroll.stored`.
- **AppStore.swift (load):** `approvals = file.managedApprovals ?? []`, then automations, heartbeat and
  `chatScroll.restore(file.scrollPositions)`.
- **AppStore+Turns.swift (turn end):** P54's "This app request was not run" warning for a turn that still ends with
  an app request. The abandoned-approval sweep still excludes managed cards (`!$0.isManaged`), so a run ending
  never cancels a runtime-recorded card.
- **Views/MessageView.swift:** the DEBUG-only `[QA-TEST]` badge is kept. The reply quote uses P51's
  `store.technicalLine(repliedMessage)`, which applies `SwarmhubBlock.visibleText` itself (TechnicalRow.displayLine),
  so swarmhub blocks stay hidden and technical rows show their folded line.

**Static checks (no Swift toolchain here):**
- No top-level type is declared twice in any module, and the merge adds no duplicate `AppStore` extension member.
- No caller of a signature changed on either side was found: `AccountProfileName.read(field:)` and
  `HermesRunRegistry.set(…scope:…)` have no stale callers.
- All referenced symbols exist (`ChatScrollModel`, `isManaged`, `addWarning`, `AppRequestMarker.notRun`).
- None of the 89 changed Swift, Python or shell files exceeds 500 lines.

### Linux suites (merged tree, `PYTHONDONTWRITEBYTECODE=1`)

| Suite | Result |
| --- | --- |
| `python3 -m unittest discover -s scripts -p 'test_*.py'` | **609 OK**, 1 skipped (macOS-only libcommonCrypto vector) |
| `python3 -m unittest discover -s Tests/Updater -p 'test_*.py'` (run alone) | **206 run, 3 failures**: the stale swarmhub-manager render goldens (below) |
| `python3 -m unittest discover -s sim -p 'test_*approvals*.py'` | **71 OK** (local sockets now work; the coreInt2 refusals are gone) |
| `sim.test_fixes8_skills`, `sim.test_prompt_sync` | **11 OK** |
| `updater-bootstrap-preflight-test.sh` under sh, dash, bash, zsh | **33 passed, 0 failed, 0 skipped** each |
| `BOOTSTRAP_TEST_MODE=fallback sh Tests/Scripts/updater-bootstrap-test.sh` | **36 passed, 0 failed, 2 skipped** (Docker absent) |
| `bot-msg-test.sh` with `BOT_MSG_SH` = sh, dash, bash, zsh | **14 passed, 0 failed** each |
| code-job / swarmhub-report / claude-login / box-adopt / box-readings / accounts-recipes `*-test.sh` | 23 / 22 / 5 / 11 / 12 / 6 passed, 0 failed |
| `make_vectors`, `make_config_vectors`, `make_ui_vectors`, `make_ui_renders`, `device_approval_vectors` `--check` | **5/5 byte-identical** |
| `git diff --check` | clean |

The first Updater run, which ran in parallel with the scripts and sim suites, had 14 failures. Eleven came from a
`Resources/Updater/swarmhub_update/__pycache__` created during the parallel run and copied into staged-transport
fixtures. After deleting the caches and running Updater alone, only the three golden failures remain, and no
`__pycache__` is left in the tree.

### Open risks

1. **swarmhub-manager render goldens are stale (3 red Updater tests).** Main's P56 bumped `swarmhub-manager` 1.2.0 → 1.3.0
   and added a Heartbeat section. The three `Tests/Fixtures/release-bundles/renders/swarmhub-manager/*/any-order/SKILL.md`
   goldens are Swift-final at 1.2.0. The failing tests are `test_render…test_every_golden_is_byte_identical`,
   `test_apply…test_real_resources_render_as_the_goldens` and
   `test_staged_transport…test_real_release_bytes_render_all_four_skills_as_todays_goldens`.
   - The renders README requires body changes to be rewritten on the Mac. `--refresh-versions` accepts only version-only changes, and `--write-provisional` refuses a Swift-final set.
   - The goldens were therefore **not** edited or overwritten from Python.
   - Evidence the Python port is consistent: the default-profile Python render differs from the golden by exactly main's
     `Resources/Skills/swarmhub-manager/SKILL.md` delta (14 ± lines), with `{{VERSION}}` substituted.
   - **Mac:** `SWARMHUB_WRITE_RENDERS=1 swift test --filter RenderGoldenTests`. Only the three manager files should change; then commit them.
2. **Merged Swift is unbuilt.** Main's P50–P56 and this branch's managed approvals, SDUI and prompt sync meet in
   `AppStore`, `StoreFile`, turn completion and `MessageView` for the first time. `swift test` (AgentApp and
   SwarmHubCore) on the Mac decides. Main's new tests (`--check-account-names`, P54 marker, P55 voice RPC, P56 heartbeat)
   have not run against this branch.
3. **Managed approvals × P54 app requests:** a turn ending in an app request now adds the "not run" warning, and managed
   cards survive the turn end. Their interaction in one chat has not been exercised.
4. **Parallel test runs pollute `Resources/` with `__pycache__`** despite `PYTHONDONTWRITEBYTECODE=1`, presumably a
   subprocess that drops the variable. This was not root-caused. Run Updater alone, or clean caches first.
5. The Mac checklist above still applies. iOS stays unbuilt and suspended.
