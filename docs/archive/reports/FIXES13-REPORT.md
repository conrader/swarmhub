# FIXES13 — explanatory goal-clause boundaries

Base: `swarmhub/peer-delivery` at `0443a53`. Changes are uncommitted. Hermes was not modified.

## Changes

`Sources/AgentApp/Models/ChatAutomation.swift` and `sim/goal_classifier.py` use the same updated control flow:

- A comma closes a finite explanatory clause and clears its coordination flag. The trailing imperative in **“Explain why we add tests, and fix the parser”** is now coding, including bare-comma, `, and`, `, then`, `, and then`, and `, also` variants.
- Polite explanatory requests (`Can/Could/Would/Will you explain …`) can reopen at a comma. Direct wh-questions retain their general classification.
- `plus` works like `and`, both as a conjunction after an explanation and as a command lead-in after punctuation. A subordinate verb's bare coordination stays inside the explanation.
- Starting a new wh-clause clears coordination inherited from the previous explained clause; it cannot suppress a later independent command.
- `we also add` still identifies an explained clause's own verb. `also` and `plus` do not count as an infinitive's object. These changes fix three explanation-only false positives found while probing.

Semicolons and sentence breaks already reset the scope; their regressions are included. Bare `also` remains an adverb rather than a clause boundary: a trailing command needs punctuation or a conjunction to establish its own scope. This preserves “Explain why they also fix the parser”.

The classifier remains a word-based heuristic. These changes address explanatory boundaries and adjacent coordination; they do not attempt unrestricted subject or grammar parsing.

## Regression coverage

- `sim/test_fixes13.py`: 9 tests, 80 explicit phrases (38 coding / 42 general), including a check that each phrase occurs in the correct Swift table.
- `Tests/AgentAppTests/GoalTests.swift`: 72 additional phrases; all 61 existing entries retained. The shared table now has **133 unique phrases: 75 coding / 58 general**.
- `sim/test_fixes8_goal.py`: updated exact table counts and decoding of JSON-compatible string escapes, so the Swift `\n` probe runs as an actual newline in Python too.
- Compared with the clean baseline, the 80 probes correct **24 false negatives and 3 false positives**. The other 53 keep their classifications.
- All existing fixes11 and fixes12 classifier expectations pass, including “Explain why we add tests and remove Python packages” (general).

## Phrase table

Every fixes13 phrase appears below and in both test files. `\n` denotes an actual newline. The final column is the expected shared classification and the observed Python result; Swift execution remains a Mac acceptance step.

| Phrase | `0443a53` Python | Fixes13 |
|---|---|---|
| Explain why we add tests, and fix the parser | general | coding |
| Explain why we add tests, fix the parser | general | coding |
| Explain why we add tests, then fix the parser | coding | coding |
| Explain why we add tests, and then fix the parser | coding | coding |
| Explain why we add tests, also fix the parser | general | coding |
| Explain why we add tests, and also fix the parser | general | coding |
| Explain why we add tests, plus fix the parser | general | coding |
| Explain what we should add, then fix the parser | coding | coding |
| Explain what we should add, and fix the parser | general | coding |
| Explain where we install Python packages, fix the parser | general | coding |
| Explain how we build the parser, and then fix it | coding | coding |
| Explain when we run tests, also fix the parser | general | coding |
| Explain which tests we run, plus fix the parser | general | coding |
| Explain who can add tests, and fix the parser | general | coding |
| Explain why we add tests, refactor the parser | general | coding |
| Explain why we add tests, and fix it | general | coding |
| Explain why we also add tests, and fix the parser | coding | coding |
| Can you explain why we add tests, and fix the parser? | general | coding |
| Could you explain what we should add, fix the parser? | general | coding |
| Would you describe where we install Python packages, also fix the parser? | general | coding |
| Will you explain when we run tests, plus fix the parser? | general | coding |
| Can you explain how to build the parser, and fix it? | general | coding |
| Explain why we add tests; fix the parser | coding | coding |
| Explain why we add tests; and fix the parser | coding | coding |
| Explain why we add tests; and then fix the parser | coding | coding |
| Explain why we add tests; also fix the parser | coding | coding |
| Explain why we add tests; plus fix the parser | general | coding |
| Explain why we add tests. Also fix the parser | coding | coding |
| Explain why we add tests. Plus fix the parser | general | coding |
| Explain why we add tests! Then fix the parser | coding | coding |
| Explain why we add tests? Fix the parser | coding | coding |
| Explain why we add tests\nThen fix the parser | coding | coding |
| Explain why we add tests and then fix the bug | coding | coding |
| Explain why the parser crashes plus fix it | general | coding |
| Explain how to build the parser, plus fix it | general | coding |
| Explain why we add tests and also why the parser crashes and fix it | general | coding |
| Explain why we add tests and what went wrong and fix the parser | general | coding |
| Explain why we add tests, and why the parser crashes and fix it | general | coding |
| Explain why we add tests and remove Python packages | general | general |
| Explain why we add tests and also remove Python packages | general | general |
| Explain why we add tests plus remove Python packages | general | general |
| Explain what we should add and remove in the package | general | general |
| Explain where we install and remove Python packages | general | general |
| Explain when we add tests and remove Python packages | general | general |
| Explain how we build and test the parser | general | general |
| Explain who can add tests and remove Python packages | general | general |
| Explain which tests we add and remove | general | general |
| Explain why we add tests, and why we remove Python packages | general | general |
| Explain why we add tests, and how to remove Python packages | general | general |
| Explain why we add tests, and they remove Python packages | general | general |
| Explain why we add tests, and describe the parser | general | general |
| Explain why we add tests, and then explain how to fix the parser | general | general |
| Explain why we add tests; also describe the parser | general | general |
| Explain why we add tests. Plus explain how to fix the parser | general | general |
| Explain why we also add tests and remove Python packages | coding | general |
| Explain why we also add tests plus remove Python packages | general | general |
| Explain why the parser crashes also fix it | general | general |
| Explain why they also fix the parser | general | general |
| Why do we add tests, and fix the parser? | general | general |
| What should we add, then remove in the Python package? | general | general |
| Where do we install Python packages, and run tests? | general | general |
| How do I add tests, then fix the build? | general | general |
| When do we add tests, plus fix the parser? | general | general |
| Who can add tests, and also fix the parser? | general | general |
| Which tests should we add, and remove? | general | general |
| Can you explain why we add tests, and how to fix the parser? | general | general |
| Explain how to build and test the parser | general | general |
| Describe how to add and remove a Python package | general | general |
| Can you explain how to build and then test the parser? | general | general |
| Explain how to build and also test the parser | general | general |
| Explain how to build and then test the parser | general | general |
| Explain how to build plus test the parser | general | general |
| Explain how to also build and then test the parser | coding | general |
| Explain how to build plus then test the parser | coding | general |
| Explain how to install the package and configure the database | general | general |
| Explain why we add tests, and write a summary | general | general |
| Explain why we add tests, plus write a summary | general | general |
| Explain why we add tests; also write a summary | general | general |
| Explain why we add tests. Then build a presentation | general | general |
| Can you explain why we add tests, and write a summary? | general | general |

## Validation

Linux, Python 3.12. The previously recorded unrestricted `0443a53` result is **309 tests, OK (7 skips)**. This session's sandbox cannot reproduce that unrestricted environment. I exported the same commit with `git archive` to `/tmp/fixes13/base` and ran the requested suites on both that clean baseline and the final tree.

| Check | Clean `0443a53` in this sandbox | Final tree |
|---|---|---|
| `PYTHONPATH=sim python3 -B -m unittest discover -s sim -p 'test_*.py'` | 309 tests; 8 failures, 1 error, 8 skips; exit 1 | 318 tests; **same 8 failures, 1 error, 8 skips**; exit 1 |
| Focused classifier modules: fixes13, fixes8_goal, fixes11.ExplanatoryScopeTests, fixes12.GoalClassifierTests | — | **19 tests, OK**, including all 133 shared phrases |
| `sh Tests/Scripts/code-job-test.sh <code-job>` | **22 passed, 0 failed** | **22 passed, 0 failed** |
| `sh Tests/Scripts/bot-msg-test.sh <bot-msg>` | Skipped, exit 77: loopback sockets denied | Same skip and reason, exit 77 |
| Python 3.9 grammar: `ast.parse(..., feature_version=(3, 9))` | — | All 3 touched Python files pass |
| `git diff --check` | — | Pass |

There are **no new failing test/subtest identities**: sorted `FAIL:`/`ERROR:` records match exactly between baseline and final discovery. The 9 additional test methods all pass. Full discovery is **not green in this sandbox**, and the bot-msg cases could not execute here; the historical 309/7 result is not presented as a fresh successful run.

The matching environmental failures/errors are:

- `test_fixes12.CodeJobLayoutTests.test_snapshot_is_kept_in_launcher_state_outside_codex_writable_roots`: cannot create the fixture under `/home/ubuntu` (read-only filesystem).
- `test_fixes6.GitMetadataEscapeTests.test_workspace_remains_writable_and_outside_stays_closed`: user namespaces unavailable; fallback denies creation of the top-level `build` directory.
- `test_fixes6.OrdinaryVerifierTests.test_node_child_processes_work`: child process launch gets `EPERM`.
- `test_fixes7.LimitedModeSuitesTests.test_mode_is_recorded_by_the_launcher_for_the_job_result`: expected namespaced mode, observed fallback.
- `test_fixes8.LimitedModeProcessIsolationTests.test_a_sigio_owner_cannot_name_another_process`: socket send gets `EPERM`.
- Four subtests of `test_fixes8.NamespacedModeSignalTests.test_sigqueue_calls_reach_the_own_child_in_the_namespaced_mode`: user namespaces unavailable.

Logs: `/tmp/fixes13/baseline-python.log`, `/tmp/fixes13/final-python.log`, `/tmp/fixes13/classifier.log`, and `/tmp/fixes13/{baseline,final}-{code-job,bot-msg}.log`. No sandbox settings or unrelated production scripts were changed to hide these restrictions; all existing phrase classifications are retained.

## Mac acceptance

Run from this checkout on the Mac. The first Python command covers the touched test modules and the prior classifier regressions. The second runs full discovery. `swift test` is the full suite, without a filter.

```sh
set -eu
PYTHONPATH=sim /usr/bin/python3 -B -m unittest \
  sim.test_fixes13 sim.test_fixes8_goal \
  sim.test_fixes11.ExplanatoryScopeTests sim.test_fixes12.GoalClassifierTests -v
PYTHONPATH=sim /usr/bin/python3 -B -m unittest discover -s sim -p 'test_*.py'
sh Tests/Scripts/code-job-test.sh "$PWD/Resources/Skills/swarmhub-coding/scripts/code-job"
sh Tests/Scripts/bot-msg-test.sh "$PWD/Resources/Skills/swarmhub-messages/scripts/bot-msg"
swift build --skip-update --disable-automatic-resolution
swift test --skip-update --disable-automatic-resolution
```

Swift build and tests were not run on this Linux host. The Swift/Python changes were reviewed for matching branch conditions and state resets; native Swift behavior must still be confirmed on the Mac. The three touched Python files pass Python 3.9 grammar parsing, but no Python 3.9 interpreter was run here.
