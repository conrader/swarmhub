# FIXES15: noun objects and completed command series

Base: `a255e70`, branch `swarmhub/peer-delivery`. Changes are uncommitted. Hermes and code-job were not edited.

## Change

Both review regressions now classify as **coding**:

- `Explain the build, refactor and test the parser`
- `Explain why we install, configure and run, fix and test the parser`

`ChatAutomation.swift` and `sim/goal_classifier.py` use the same predicates, state transitions, and token indexes:

1. `isSeriesHead` / `is_series_head` requires grammatical context before allowing a word to head an explanatory series. A subject, modal, or infinitive marker (optionally followed by `also`) supplies positive evidence. A finite clause also permits an uncoordinated noun-subject predicate, preserving `why the developers build, test and deploy`. Determiners and compound code nouns such as `unit test` exclude noun readings in that fallback. Unscoped explanatory objects such as `the build`, `a clean build`, and `our nightly run` cannot qualify merely because their last word is in the verb vocabulary. After a marker-led finite predicate, its object also cannot qualify through the noun-subject fallback.
2. `innerVerb` is cleared on every token, including paths that continue early, and after consuming a series. Only the immediately preceding eligible predicate can authorize a comma-series skip.
3. `seriesEnded` remembers that a series just completed. Its immediately following comma opens a new clause instead of extending the old series, including for an objectless infinitive (`how to build, test and deploy, refactor and lint the parser`). Fresh explanatory clauses still establish their own series normally.

The Python port reads the new `nounDeterminers` list from Swift. The existing series connector list and `verbSeriesEnd` scanning rules are unchanged. The two required controls remain **general** for `Explain why we install, configure and run the server` and **coding** for `Explain why we add tests, and fix the parser`.

## Regression coverage and before/after phrases

`sim/test_fixes15.py` adds **7 test methods / 65 phrases**: 43 coding and 22 general. All phrases have matching expectations in the shared `GoalTests.swift` table; 56 are new table entries. The shared table grows from **95 coding / 92 general** to **136 coding / 107 general** (243 total), with all 187 previous expectations preserved. `sim/test_fixes8_goal.py` updates its table-count assertion accordingly.

The before column was evaluated with the Python implementation from `git show a255e70:sim/goal_classifier.py`; its word lists were checked against the Swift source at that commit. The after column is the edited port. **36 phrases change from general to coding; the other 29 retain their classification.** No phrase in this table changes from coding to general.

| Group | Phrase | fixes14 | fixes15 (expected) |
|---|---|---|---|
| NOUN_OBJECTS | Explain the build, refactor and test the parser | general | coding |
| NOUN_OBJECTS | Explain the test, refactor and test the parser | general | coding |
| NOUN_OBJECTS | Explain the run, refactor and test the parser | general | coding |
| NOUN_OBJECTS | Explain the fix, refactor and test the parser | general | coding |
| NOUN_OBJECTS | Explain the deploy, refactor and test the parser | general | coding |
| NOUN_OBJECTS | Explain a clean build, refactor and test the parser | general | coding |
| NOUN_OBJECTS | Explain the unit test, refactor and deploy the server | general | coding |
| NOUN_OBJECTS | Explain our nightly run, refactor and test the parser | general | coding |
| NOUN_OBJECTS | Explain this quick fix, refactor and test the parser | general | coding |
| NOUN_OBJECTS | Explain their latest deploy, refactor and test the parser | general | coding |
| NOUN_OBJECTS | Can you explain the build, refactor and test the parser? | general | coding |
| NOUN_OBJECTS | Could you describe the unit test, refactor and deploy the server? | general | coding |
| CLAUSE_OBJECTS | Explain why we run the build, refactor and test the parser | general | coding |
| CLAUSE_OBJECTS | Explain why we run the unit test, refactor and deploy the server | general | coding |
| CLAUSE_OBJECTS | Explain why we test the run, refactor and test the parser | general | coding |
| CLAUSE_OBJECTS | Explain why we deploy the fix, refactor and test the parser | general | coding |
| CLAUSE_OBJECTS | Explain why we test the deploy, refactor and test the parser | general | coding |
| CLAUSE_OBJECTS | Explain why we fix the build, refactor and deploy the server | general | coding |
| CLAUSE_OBJECTS | Explain why the build, refactor and test the parser | general | coding |
| CLAUSE_OBJECTS | Explain why the unit test, refactor and deploy the server | general | coding |
| CLAUSE_OBJECTS | Explain how to run the build, refactor and test the parser | general | coding |
| CHAINED_SERIES | Explain why we install, configure and run, fix and test the parser | general | coding |
| CHAINED_SERIES | Explain why we build, test, and deploy, refactor and lint the parser | general | coding |
| CHAINED_SERIES | Explain why we build, test and deploy, refactor then lint the parser | general | coding |
| CHAINED_SERIES | Explain why we build, test or deploy, fix and test the parser | general | coding |
| CHAINED_SERIES | Explain why we build, test plus deploy, fix and test the parser | general | coding |
| CHAINED_SERIES | Explain why we build, test and also deploy, fix and test the parser | general | coding |
| CHAINED_SERIES | Explain why we build, test and then deploy, fix and test the parser | general | coding |
| CHAINED_SERIES | Explain why we lint, test, build and deploy, fix, refactor and test the parser | general | coding |
| CHAINED_SERIES | Explain why the developers build, test and deploy, fix and test the parser | general | coding |
| CHAINED_SERIES | Explain the reasons we install, configure and run, fix and test the parser | general | coding |
| CHAINED_SERIES | Can you explain why we install, configure and run, fix and test the parser? | general | coding |
| CHAINED_SERIES | Explain why we install, configure and run, and fix and test the parser | coding | coding |
| CHAINED_SERIES | Explain why we install, configure and run, then fix and test the parser | coding | coding |
| CHAINED_SERIES | Explain why we install, configure and run; fix and test the parser | coding | coding |
| CHAINED_SERIES | Explain why we install, configure and run the server, fix and test the parser | coding | coding |
| CHAINED_SERIES | Explain how to build, test and deploy, refactor and lint the parser | general | coding |
| CHAINED_SERIES | Explain how to build, test and deploy, fix the parser | general | coding |
| CODING_CONTROLS | Explain why we add tests, and fix the parser | coding | coding |
| CODING_CONTROLS | Explain the build, fix and test the parser | general | coding |
| CODING_CONTROLS | Explain the deploy, configure and run the server | general | coding |
| CODING_CONTROLS | Explain the build, fix the parser | coding | coding |
| CODING_CONTROLS | Build, test and deploy the server | coding | coding |
| EXPLANATIONS | Explain why we install, configure and run the server | general | general |
| EXPLANATIONS | Can you explain why we install, configure and run the server? | general | general |
| EXPLANATIONS | Explain why we build, test, and deploy the server | general | general |
| EXPLANATIONS | Explain why the developers build, test and deploy the server | general | general |
| EXPLANATIONS | Explain why the developers test, build and deploy the server | general | general |
| EXPLANATIONS | Explain why the developers run, test and deploy the server | general | general |
| EXPLANATIONS | Explain why the developers fix, test and deploy the server | general | general |
| EXPLANATIONS | Explain why the developers deploy, configure and run the server | general | general |
| EXPLANATIONS | Explain why we also install, configure and run the server | general | general |
| EXPLANATIONS | Explain what we should add, fix and remove in the package | general | general |
| EXPLANATIONS | Explain how to build, test and deploy the server | general | general |
| EXPLANATIONS | Explain how to also build, test and deploy the server | general | general |
| EXPLANATIONS | Explain the reasons we install, configure and run the server | general | general |
| EXPLANATIONS | Explain why we build, test and deploy, and why we install, configure and run the server | general | general |
| GENERAL_CONTROLS | Explain the build | general | general |
| GENERAL_CONTROLS | Explain the test | general | general |
| GENERAL_CONTROLS | Explain the run | general | general |
| GENERAL_CONTROLS | Explain the fix | general | general |
| GENERAL_CONTROLS | Explain the deploy | general | general |
| GENERAL_CONTROLS | Explain the build, write and update the summary | general | general |
| GENERAL_CONTROLS | Explain why we install, configure and run, write and update the summary | general | general |
| GENERAL_CONTROLS | Why do we install, configure and run, fix and test the parser? | general | general |

## Decisions on the three highlighted limits (report only)

The following behaviors are unchanged; no special cases were added for them.

| Phrase | Before / after | Decision and reason |
|---|---|---|
| Explain why we install, configure, run, then fix the parser | general / general | Retain the existing series reading for this ambiguous wording. With no earlier closing conjunction, `then` can finish the explanation's series. This remains a possible false general if `fix` was meant as a new command. Treating every such `then` as a boundary would break the required fixes14 expectation for `Explain why we build, test, deploy, then release the server`. Use a semicolon before the new command, or close the series first: `install, configure and run, then fix the parser`. |
| Explain why we build and then deploy the server | coding / coding | Retain the fixes12 explicit `then` boundary when no comma series is active. This favors detecting a second requested action and preserves `Explain why we add tests and then fix the bug`. It can overclassify a pure explanation; `Explain how to build and then deploy the server` makes the shared infinitive explicit. |
| Explain why we install, configure and run the server and fix the parser | general / general | Retain ordinary `and` coordination inside an explanation. Without a comma or other boundary, `fix` can be another explained action. Opening a command at every bare `and` would break existing explanatory coordination. Write `...run the server, and fix the parser` to request the second action explicitly. |

These decisions preserve the established distinctions rather than infer intent from the particular verbs. They do not remove the ambiguity. The other two limits noted in FIXES14-REPORT.md are also unchanged: two-verb comma forms open commands, and inflected forms are outside the base-verb vocabulary. The unpunctuated `also` run-on remains general as previously documented.

The noun/verb check is still a bounded lexical heuristic, not a part-of-speech parser. Its noun-subject fallback can be ambiguous with unfamiliar modifiers or complex relative clauses. The regression coverage establishes the listed determiner, compound-noun, object, subject, and series cases; it does not claim arbitrary English parsing.

## Verification

Full discovery was run with the exact requested command:

```sh
PYTHONPATH=sim python3 -B -m unittest discover -s sim
```

| Run | Tests run | Result | Skips | Log |
|---|---:|---|---:|---|
| Before (`a255e70`) | 328 | FAILED: 8 failure entries, exit 1 | 8 | `/tmp/fixes15-baseline.log` |
| After | 335 | FAILED: the same 8 failure entries, exit 1 | 8 | `/tmp/fixes15-after.log` |

**No new failures.** The seven additional test methods pass. Full discovery is not green in this sandbox; both runs encounter the same pre-existing host restrictions. Comparing the complete failure identifiers, including subtest labels, gives an exact match:

- `test_fixes6.GitMetadataEscapeTests.test_workspace_remains_writable_and_outside_stays_closed`: fallback sandbox denies creation of the workspace `build` directory.
- `test_fixes6.OrdinaryVerifierTests.test_node_child_processes_work`: child-process spawning reports `EPERM`.
- `test_fixes7.LimitedModeSuitesTests.test_mode_is_recorded_by_the_launcher_for_the_job_result`: records `fallback` instead of the expected `namespaced` mode.
- `test_fixes8.LimitedModeProcessIsolationTests.test_a_sigio_owner_cannot_name_another_process`: socket send reports `EPERM`.
- `test_fixes8.NamespacedModeSignalTests.test_sigqueue_calls_reach_the_own_child_in_the_namespaced_mode`: four failing subtests (`rt_sigqueueinfo`, `rt_tgsigqueueinfo`, `kill`, `tgkill`) because the sandbox reports `no user namespace`.

These failures are unrelated to command classification. No sandbox or code-job code was changed to work around them.

Focused classifier verification:

```sh
PYTHONPATH=sim python3 -B -m unittest \
  test_fixes15 test_fixes14 test_fixes13 test_fixes8_goal \
  test_fixes11.ExplanatoryScopeTests test_fixes12.GoalClassifierTests
```

**35 tests passed.** This includes all fixes8/11/12/13/14 classifier expectations and the new regressions. The edited Python files (`goal_classifier.py`, `test_fixes15.py`, `test_fixes8_goal.py`) also pass `ast.parse(..., feature_version=(3, 9))`; no Python 3.9 interpreter was executed. `git diff --check` passed.

The initial discovery was repeated before the new test module/table was added; both baseline runs reported 328 tests, 8 failure entries, and 8 skips. These are the measured counts on this host, not the 327 tests / 7 skips from the earlier fixes14 report. Failure entries include subtests, so subtracting eight from the test-method count would not produce an accurate passing-method count.

## Native Swift verification on the Mac

Swift was **not built or executed** here. The helper conditions, state resets, comma boundary, and word-list loading were reviewed against the Python port; shared phrase execution on Python is not a substitute for native Swift execution. Run from this checkout on the Mac:

```sh
set -eu
PYTHONPATH=sim /usr/bin/python3 -B -m unittest \
  test_fixes15 test_fixes14 test_fixes13 test_fixes8_goal \
  test_fixes11.ExplanatoryScopeTests test_fixes12.GoalClassifierTests -v
PYTHONPATH=sim /usr/bin/python3 -B -m unittest discover -s sim
swift build --skip-update --disable-automatic-resolution
swift test --skip-update --disable-automatic-resolution
```

The full `swift test` includes `plainGoalsAreClassifiedByTheRequestedAction` with the 243 shared phrases. Native build/test acceptance remains outstanding.
