# FIXES14 report: comma-separated verb series inside explanations

Base: `c6b1c48` (fixes13), branch `swarmhub/peer-delivery`. Uncommitted. Hermes and code-job were not touched.

## Finding

Fixes13 made a comma close an explanatory why/what clause. That broke verb lists inside a pure explanation. In "Explain why we install, configure and run the server", the comma closed the clause, `configure` became a new imperative, and `server` made it **coding**. The polite form and the Oxford-comma form ("…why we build, test, and deploy the server") failed the same way. Before fixes13 all three were general.

## Change

Swift (`Sources/AgentApp/Models/ChatAutomation.swift`) and the Python port (`sim/goal_classifier.py`) got the same edit:

- **Verb series rule.** Inside an explanation, a comma right after the explanation's own verb continues the clause when it opens a series of two or more further verbs, such as "install, configure and run the server" or "build, test, and then deploy". "Own verb" means a change or coding-only verb that was not at clause start, so it is not an imperative. Connectors are `,`, `and`, `or`, `then`, `plus` and `also`. The whole series is skipped as part of the explained clause. In a why/what clause it also counts as the clause's coordinated verbs.
- **Where a series ends.** It stops at the verb after its first real conjunction, which is any connector other than `,` or `also` ("A, B and C"). So the series does not swallow a later command: "Explain why we build, test and deploy, then fix the parser" stays coding.
- **What still closes the clause.** A comma after an object ("Explain why we add tests, and fix the parser") still closes it and counts as coding. So does a comma followed by only one verb ("Explain why we install, configure the server" and "Explain why we build, and deploy the server"), and so does a comma followed by a conjunction ("Explain what we should add, then fix the parser").
- **New pieces.** `seriesConnectors` is a new Swift word list. The Python port reads it from the Swift source like the other lists (`LISTS`). There are two new helpers: `isVerb` / `is_verb` and `verbSeriesEnd` / `verb_series_end`. `innerVerb` / `inner_verb` records whether the previous verb was non-imperative.
- **Scope.** The rule only applies once an explain verb has been seen. Imperative lists ("Build, test and deploy the server") and questions behave as before.

### The "also" minor: kept general, on purpose

"Explain why the parser crashes also fix it" stays **general**. Without punctuation, the "also" here looks exactly like an adverb after a noun subject, as in "Explain why the developers also fix the parser". Only pronoun or modal subjects are in `subordinateMarkers`, so treating an unpunctuated "also V" as a command would turn every plural-noun explanation into a coding job. That is the over-eager direction both reviews flagged. Any punctuated version is coding and is now in the table: "Explain why the parser crashes, also fix it" and "…crashes; also fix it". The run-on is treated as a typo. Its general result is pinned beside the "developers" control it can't be told apart from.

### Known heuristic limits

- "Explain why we build and then deploy the server" (two verbs, no comma) stays **coding**. That is the fixes12 rule, where "then" after the clause's verb opens a command ("Explain why we add tests and then fix the bug"). Without a parser it can't be told apart from "Explain what we should add and then fix the parser". The three-verb comma series ("build, test and then deploy the server") is general.
- Two-verb comma forms ("why we install, configure the server", "why we build, and deploy the server") are treated as a comma splice or a separate command, so they are coding.
- Inflected verbs ("builds", "deploys") are not in `changeVerbs`, so they never form a series. They also never trigger coding, so this does no harm.
- When `then` ends an asyndetic series, it counts as the series' conjunction. So "Explain why we install, configure, run, then fix the parser" and "…build, test, deploy, then release the server" are **general**, which is a possible false general for the first one. Adding `and` ("…, and then …") doesn't change this. Putting the command after a comma once the series has closed does: "Explain why we build, test and deploy, then fix the parser" is coding.
- "Explain why we install, configure and run the server and fix the parser" (no comma before "and fix") is **general**. It used to be coding only because the fixes13 comma had already closed the clause. The result now matches the existing fixes12 rule, where a bare "and" after the clause's own verbs coordinates with them ("Explain why we add tests and remove Python packages").

An independent verifier (Sonnet, read-only) compared the Swift and Python diffs line by line and found no divergence and no syntax problem. It re-ran the 58 focused tests (OK), and confirmed the table membership, the 95/92 counts and the 3.9 grammar. 23 of its own 25 pre-labelled probes matched. The two that didn't are the two bullets just above.

## Phrase table

57 phrases are in `sim/test_fixes14.py`. 54 are new to the shared Swift table (20 coding, 34 general). Three were already there from fixes13. The fixes13 column is the clean `c6b1c48` port (`git archive` to `/tmp/fixes14/base`). Changed rows are in bold.

| Group | Phrase | fixes13 | fixes14 (expected) |
|---|---|---|---|
| REVIEW_SERIES | Explain why we install, configure and run the server | coding | **general** |
| REVIEW_SERIES | Can you explain why we install, configure and run the server? | coding | **general** |
| REVIEW_SERIES | Explain why we build, test, and deploy the server | coding | **general** |
| SERIES | Explain why we build, test, deploy the server | coding | **general** |
| SERIES | Explain why we lint, test, build and deploy the server | coding | **general** |
| SERIES | Explain why we lint, test, build, and deploy the server | coding | **general** |
| SERIES | Explain why we build, test or deploy the server | coding | **general** |
| SERIES | Explain why we build, test and also deploy the server | coding | **general** |
| SERIES | Explain why we refactor, test and deploy the parser | coding | **general** |
| SERIES | Explain why we build, test, and then deploy the server | coding | **general** |
| SERIES | Explain why we build, test and then deploy the server | coding | **general** |
| SERIES | Explain why we install, configure, and then run the server | coding | **general** |
| SERIES | Explain why we build, test, deploy, then release the server | coding | **general** |
| SERIES | Explain why we build, test and deploy it | coding | **general** |
| SERIES | Explain why we install and configure the server | general | general |
| OTHER_WH_SERIES | Explain how we build, test and deploy the server | coding | **general** |
| OTHER_WH_SERIES | Explain where we install, configure and run the server | coding | **general** |
| OTHER_WH_SERIES | Describe when we build, test, and deploy the server | coding | **general** |
| OTHER_WH_SERIES | Explain who can build, test and deploy the server | coding | **general** |
| OTHER_WH_SERIES | Explain what we build, test and deploy on the server | coding | **general** |
| OTHER_WH_SERIES | Explain what we should add, fix and remove in the package | coding | **general** |
| OTHER_WH_SERIES | Explain which tests we write, run and fix in the parser | coding | **general** |
| OTHER_WH_SERIES | Explain the reasons we install, configure and run the server | coding | **general** |
| OTHER_WH_SERIES | Explain why the developers build, test and deploy the server | coding | **general** |
| OTHER_WH_SERIES | Explain how to build, test and deploy the server | general | general |
| OTHER_WH_SERIES | Explain how to build, test, and then deploy the server | general | general |
| POLITE_AND_QUESTION_SERIES | Could you explain why we build, test, and deploy the server? | coding | **general** |
| POLITE_AND_QUESTION_SERIES | Would you describe how we install, configure and run the server? | coding | **general** |
| POLITE_AND_QUESTION_SERIES | Can you explain why we lint, test, build and deploy the server? | coding | **general** |
| POLITE_AND_QUESTION_SERIES | Why do we build, test and deploy the server? | general | general |
| POLITE_AND_QUESTION_SERIES | How do we install, configure, and run the server? | general | general |
| SERIES_THEN_NON_CODE | Explain why we build, test, and deploy the server; also describe the parser | coding | **general** |
| SERIES_THEN_NON_CODE | Explain why we build, test and deploy the server, and write a summary | coding | **general** |
| ALSO_EXPLANATIONS | Explain why the parser crashes also fix it | general | general |
| ALSO_EXPLANATIONS | Explain why the developers also fix the parser | general | general |
| SERIES_THEN_COMMANDS | Explain why we install, configure and run the server, and fix the parser | coding | coding |
| SERIES_THEN_COMMANDS | Explain why we build, test, and deploy the server, then fix the parser | coding | coding |
| SERIES_THEN_COMMANDS | Explain why we build, test and deploy the server, fix the parser | coding | coding |
| SERIES_THEN_COMMANDS | Can you explain why we install, configure and run the server, and fix the parser? | coding | coding |
| SERIES_THEN_COMMANDS | Explain why we build, test and deploy, then fix the parser | coding | coding |
| SERIES_THEN_COMMANDS | Explain why we install, configure and run the server; fix the parser | coding | coding |
| SERIES_THEN_COMMANDS | Explain why we install; configure and run the server | coding | coding |
| SERIES_THEN_COMMANDS | Explain why we build, test, and deploy; then fix the server | coding | coding |
| COMMA_COMMANDS | Explain why we add tests, and fix the parser | coding | coding |
| COMMA_COMMANDS | Explain why we install, fix the parser, and run tests | coding | coding |
| COMMA_COMMANDS | Explain why we add tests, and build, test and deploy the server | coding | coding |
| COMMA_COMMANDS | Explain why we test, fix the parser | coding | coding |
| COMMA_COMMANDS | Explain why we install, configure the server | coding | coding |
| COMMA_COMMANDS | Explain why we build, and deploy the server | coding | coding |
| COMMA_COMMANDS | Explain what we should add, then fix the parser | coding | coding |
| COMMA_COMMANDS | Explain why we add, then fix the parser | coding | coding |
| COMMA_COMMANDS | Explain why we build and then deploy the server | coding | coding |
| IMPERATIVE_SERIES | Build, test and deploy the server | coding | coding |
| IMPERATIVE_SERIES | Install, configure, and run the server | coding | coding |
| IMPERATIVE_SERIES | Explain the result, then build, test and deploy the server | coding | coding |
| ALSO_COMMANDS | Explain why the parser crashes, also fix it | coding | coding |
| ALSO_COMMANDS | Explain why the parser crashes; also fix it | coding | coding |

28 rows changed, all coding → general. No phrase moved from general to coding. The other 29 already had their expected label, including every coding control.

## Tests (Linux, Python 3.12)

| Command | Baseline `c6b1c48` (clean export) | Final tree |
|---|---|---|
| `PYTHONPATH=sim python3 -B -m unittest discover -s sim -p 'test_*.py'` | 318 tests, **OK** (7 skips), exit 0 | 327 tests, **OK** (7 skips), exit 0 |
| `PYTHONPATH=sim python3 -B -m unittest test_fixes14 test_fixes13 test_fixes8_goal test_fixes12 test_fixes11` | — | 58 tests, OK |
| Python 3.9 grammar: `ast.parse(..., feature_version=(3, 9))` | — | `goal_classifier.py`, `test_fixes14.py`, `test_fixes8_goal.py` pass |

- Unlike the fixes13 session, full discovery is green in both runs on this host, so there are no sandbox failures to compare. The 9 extra tests are the new `test_fixes14` methods, and they all pass.
- The skip count is unchanged at 7.
- All fixes8, 11, 12 and 13 phrase expectations still pass.
- `sim/test_fixes8_goal.py` now expects the shared table to have **95 coding / 92 general** phrases (it was 75 / 58).
- Logs: `/tmp/fixes14/baseline-python.log`, `/tmp/fixes14/final-python.log`.

**Files:** `Sources/AgentApp/Models/ChatAutomation.swift` (+34 lines), `sim/goal_classifier.py` (+29), `Tests/AgentAppTests/GoalTests.swift` (+56 table lines, 495 lines total), `sim/test_fixes8_goal.py` (count), new `sim/test_fixes14.py`.

## Mac acceptance

Run these from this checkout on the Mac. `swift test` runs the full suite, which includes the shared `plainGoalsAreClassifiedByTheRequestedAction` table.

```sh
set -eu
PYTHONPATH=sim /usr/bin/python3 -B -m unittest \
  sim.test_fixes14 sim.test_fixes13 sim.test_fixes8_goal \
  sim.test_fixes11.ExplanatoryScopeTests sim.test_fixes12.GoalClassifierTests -v
PYTHONPATH=sim /usr/bin/python3 -B -m unittest discover -s sim -p 'test_*.py'
swift build --skip-update --disable-automatic-resolution
swift test --skip-update --disable-automatic-resolution
```

## Not verified

- **Swift was not built or run.** There is no toolchain on this host. I checked the Swift edit by reading it against the Python port branch by branch. I avoided the contextual keyword `final` as an identifier (the variable is `closing`). Native behaviour still has to be confirmed by `swift test` on the Mac.
- **No Python 3.9 interpreter was run.** The touched files only passed a 3.9 grammar parse.
- **Shell suites were not rerun.** I didn't run the code-job and bot-msg shell suites because neither script was touched.
