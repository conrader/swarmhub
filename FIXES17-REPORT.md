# FIXES17 report: platform modifiers and plural quantity subjects

Base: `swarmhub/peer-delivery` @ `c635e05`. Changes are uncommitted. Hermes and code-job were not modified. The two pre-existing untracked fixes8 brief files were left alone.

## Change

Both fixes16 review findings are fixed in `Sources/AgentApp/Models/ChatAutomation.swift` and `sim/goal_classifier.py`:

- `looksPlural` / `looks_plural` excludes the lowercased names Windows, macOS, iOS, tvOS, watchOS, Jenkins and Kubernetes from the suffix heuristic. Matching is case insensitive because tokenization already lowercases the input. Real plural nouns still stop the scan even when a platform name occurs elsewhere in the noun phrase.
- It recognizes plural quantity words as subject hints: both, all, many, several, few, cardinal words two through nineteen, the tens, hundred, thousand, million and billion. These stop `followsDeterminer` / `follows_determiner` before it can misread “these two” or “the many” as modifiers of the verb.
- A nonempty ASCII digit token immediately after a noun determiner also stops the scan, covering “these 2” and “the 12”. Digits after a platform/version modifier do not trigger this rule, preserving “the Windows 11 build” and “the iOS 18 build”. This uses character comparisons in both languages, avoiding integer overflow and Unicode numeric-parsing differences.
- The four-token lookback, boundary checks, subordinate-marker and compound-noun guards, and verb-series termination rules are unchanged. Python reads both new word lists from Swift; the branch order and scan bounds match by inspection.

`sim/test_fixes17.py` adds five test methods with 56 phrases (24 coding, 32 general), all mirrored in the shared `GoalTests.swift` table. Coverage includes every requested name and quantity sibling, uppercasing, versions, modifier order, real plural subjects, explanation-only controls, and commands after quantity-subject series with and without an object. The shared table count in `sim/test_fixes8_goal.py` is updated from 151/120 to 175/152 (coding/general).

## Before / after

Measured with the saved c635e05 Python implementation and its original Swift word lists versus the new Python port. All 271 pre-existing shared phrases keep their expected classification. Of the 56 added phrases, 27 change as intended (12 general → coding and 15 coding → general); 29 are unchanged controls. iOS was already handled by the old length check, so its cases are controls.

| Phrase | c635e05 | fixes17 | Expected |
|---|---|---|---|
| `Explain why the Windows build, refactor and test the parser` | general | coding | coding |
| `Explain why the macOS build, refactor and test the parser` | general | coding | coding |
| `Explain why the iOS build, refactor and test the parser` | coding | coding | coding |
| `Explain why the tvOS build, refactor and test the parser` | general | coding | coding |
| `Explain why the watchOS build, refactor and test the parser` | general | coding | coding |
| `Explain why the Jenkins build, refactor and test the parser` | general | coding | coding |
| `Explain why the Kubernetes build, refactor and test the parser` | general | coding | coding |
| `Explain why our nightly Windows build, refactor and test the parser` | general | coding | coding |
| `Explain why the macOS nightly build, refactor and test the parser` | general | coding | coding |
| `Explain why the WINDOWS build, refactor and test the parser` | general | coding | coding |
| `Explain why the Windows 11 build, refactor and test the parser` | general | coding | coding |
| `Explain why the iOS 18 build, refactor and test the parser` | coding | coding | coding |
| `Explain how the Jenkins test, fix and deploy the server` | general | coding | coding |
| `Can you explain why the Kubernetes deploy, fix and test the parser?` | general | coding | coding |
| `Explain why these two build, test and deploy the server, fix the parser` | coding | coding | coding |
| `Explain why those three build, test and deploy the server, fix the parser` | coding | coding | coding |
| `Explain why both build, test and deploy the server, fix the parser` | coding | coding | coding |
| `Explain why all build, test and deploy the server, fix the parser` | coding | coding | coding |
| `Explain why many build, test and deploy the server, fix the parser` | coding | coding | coding |
| `Explain why several build, test and deploy the server, fix the parser` | coding | coding | coding |
| `Explain why the two build, test and deploy the server, fix the parser` | coding | coding | coding |
| `Explain why these two build, test and deploy, refactor and lint the parser` | coding | coding | coding |
| `Explain why these 2 build, test and deploy, fix the parser` | coding | coding | coding |
| `Explain why these two build, test and deploy the server; fix the parser` | coding | coding | coding |
| `Explain why the Windows build fails` | general | general | general |
| `Explain why the macOS build fails` | general | general | general |
| `Explain why the iOS build fails` | general | general | general |
| `Explain why the tvOS build fails` | general | general | general |
| `Explain why the watchOS build fails` | general | general | general |
| `Explain why the Jenkins build fails` | general | general | general |
| `Explain why the Kubernetes build fails` | general | general | general |
| `Explain why the Windows build, write and update the summary` | general | general | general |
| `Explain why the Windows developers build, test and deploy the server` | general | general | general |
| `Explain why the developers using Windows build, test and deploy the server` | general | general | general |
| `Explain why the Kubernetes maintainers build, test and deploy the server` | general | general | general |
| `Explain why the Windows developers also build, test and deploy the server` | general | general | general |
| `Explain why these two build, test and deploy the server` | coding | general | general |
| `Explain why those three build, test and deploy the server` | coding | general | general |
| `Explain why both build, test and deploy the server` | general | general | general |
| `Explain why all build, test and deploy the server` | general | general | general |
| `Explain why many build, test and deploy the server` | general | general | general |
| `Explain why several build, test and deploy the server` | general | general | general |
| `Explain why the two build, test and deploy the server` | coding | general | general |
| `Explain why these both build, test and deploy the server` | coding | general | general |
| `Explain why these all build, test and deploy the server` | coding | general | general |
| `Explain why the many build, test and deploy the server` | coding | general | general |
| `Explain why those several build, test and deploy the server` | coding | general | general |
| `Explain why the few build, test and deploy the server` | coding | general | general |
| `Explain why these twelve build, test and deploy the server` | coding | general | general |
| `Explain why those twenty build, test and deploy the server` | coding | general | general |
| `Explain why these 2 build, test and deploy the server` | coding | general | general |
| `Explain why the 12 build, test and deploy the server` | coding | general | general |
| `Explain why the two often build, test and deploy the server` | coding | general | general |
| `Explain why the two also build, test and deploy the server` | general | general | general |
| `Explain how those three test, build and deploy the server` | coding | general | general |
| `Can you explain why these two build, test and deploy the server?` | coding | general | general |

## Verification

Full discovery, exactly `PYTHONPATH=sim python3 -B -m unittest discover -s sim`:

| Run | Tests run | Result | Exit |
|---|---:|---|---:|
| Before | 340 | 8 failure records, 8 skipped | 1 |
| After | 345 | Same 8 failure records, 8 skipped | 1 |

Logs: `/tmp/fixes17-before.log` and `/tmp/fixes17-after.log`. The baseline is not green in this restricted environment; the 340-tests-green result in FIXES16-REPORT.md was not reproduced here. Both logs also contain an embedded “Ran 0 tests / NO TESTS RAN” child-run message; the table uses the final discovery totals.

Before/after failure identifiers match exactly: eight failure records across five test methods, all outside the goal classifier. There are no new failure records. Before took 120.830 seconds; after took 122.059 seconds. The failures are:

- fixes6 `GitMetadataEscapeTests.test_workspace_remains_writable_and_outside_stays_closed`: cannot create `build` in the fallback sandbox.
- fixes6 `OrdinaryVerifierTests.test_node_child_processes_work`: Node `spawnSync /bin/sh` reports EPERM.
- fixes7 `LimitedModeSuitesTests.test_mode_is_recorded_by_the_launcher_for_the_job_result`: reports `fallback`, expects `namespaced`.
- fixes8 `LimitedModeProcessIsolationTests.test_a_sigio_owner_cannot_name_another_process`: socket send reports EPERM.
- fixes8 `NamespacedModeSignalTests.test_sigqueue_calls_reach_the_own_child_in_the_namespaced_mode`: four subtest failures (`rt_sigqueueinfo`, `rt_tgsigqueueinfo`, `kill`, `tgkill`) because the runner reports no user namespace.

Classifier-only coverage passes **45 tests**, including fixes8 and every fixes11–17 classifier test, and all **327 shared Swift-table phrases** pass through the Python port:

```sh
PYTHONPATH=sim python3 -B -m unittest \
  sim.test_fixes8_goal sim.test_fixes11.ExplanatoryScopeTests \
  sim.test_fixes12.GoalClassifierTests sim.test_fixes13 sim.test_fixes14 \
  sim.test_fixes15 sim.test_fixes16 sim.test_fixes17
```

Log: `/tmp/fixes17-classifier.log`. An earlier broader run of the complete fixes8_goal/11–17 modules also passed **76 tests**. `git diff --check` passes.

Swift was **not built or executed here**. Shared word lists, mirrored expected phrases, and source inspection check parity; they do not establish that Swift compiles or runs correctly. On a Mac with the required Swift 6/macOS SDK, from this checkout:

```sh
swift build
swift test --filter plainGoalsAreClassifiedByTheRequestedAction
swift test
```

The filter names the actual top-level classifier test function; the final command runs the complete suite, including the remaining goal tests.

## Limits and recommendation

This is a bounded English heuristic, not a grammatical parser. Known limits remain:

- Unknown proper names ending in `s` can still look plural. Only the explicit platform/tool list is exempted; capitalization cannot establish proper nouns after lowercasing. An ordinary plural use of “windows” is also indistinguishable from the platform name.
- Collective and irregular-plural subjects remain problematic: “Explain why the team build, test and deploy the server” and “… the children build …” classify as coding.
- Plural possessives and long modifier chains still hide commands: “Explain why the developers' nightly build, refactor and test the parser” and “… the really slow nightly smoke test, fix and deploy the server” classify as general.
- Quantities can themselves be modifiers. “Explain why the two stage build, refactor and test the parser” and “… the 2026 build, refactor and test the parser” classify as general. These are tradeoffs of the new subject hints, not solved grammar cases. Digit handling is limited to ASCII tokens after a listed determiner; spelled number recognition is limited to the explicit list.
- Complementizer “that”, punctuation-based clause boundaries, and the existing verb/noun vocabulary remain ambiguous.

**Recommendation: stop open-ended heuristic patching after this bounded fix and accept the remaining edge cases as documented limits.** These two reproducible defects justified a small regression-tested change, but further adjective, name, number and subject exceptions will trade one ambiguity for another. Use the existing `/goal --coding` and `/goal --general` overrides for ambiguous goals. Revisit the classifier only when observed usage establishes a meaningful failure pattern and a bounded change can be checked against a representative corpus; these synthetic edges alone do not justify another round of exceptions.
