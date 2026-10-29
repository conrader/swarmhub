# FIXES16 report: modifier-led noun objects inside why/what/how clauses

Base: `swarmhub/peer-delivery` @ a62f935, uncommitted. Hermes and code-job untouched.

## Finding (fixes15 review)

`isSeriesHead` / `is_series_head` treated a homograph (build, test, run, fix, deploy) as a noun only when a determiner stood **directly** before it. With a modifier in between ("why the **nightly** build, refactor and test the parser"), the noun headed an explanatory verb series, the series swallowed "refactor and test", and the goal came out general. "Explain the nightly build, refactor and test the parser" was already coding because it never opens a why/what clause.

## Change

Python and Swift use the same logic:

- `followsDeterminer(words, at:)` / `follows_determiner(words, index)`: scans back up to 4 words from the homograph. It returns true (a noun phrase) when it reaches a determiner/possessive from `nounDeterminers` before it reaches a stop word. A stop word is a series connector (`,` and or then plus also), a subordinate marker (we, they, to, should, …), a question starter, a clause word, or a plural-looking word.
- `looksPlural` / `looks_plural`: longer than 3 letters, ends in `s`, and does not end in `ss`/`us`/`is`. A bare (non-`-s`) verb after a noun subject needs a plural subject, so "the developers build" stays a predicate. "the nightly build" and "the previous build" become noun phrases.
- In `isSeriesHead`, the old `!nounDeterminers.contains(previous)` is replaced by `!followsDeterminer(words, at: index)`. A determiner directly before the homograph is still covered (zero modifiers). The marker, `also`, coordinated and compound-noun guards are unchanged.

Files: `Sources/AgentApp/Models/ChatAutomation.swift`, `sim/goal_classifier.py`, `Tests/AgentAppTests/GoalTests.swift` (+15 coding / +13 general table entries), `sim/test_fixes16.py` (new), `sim/test_fixes8_goal.py` (table count 136/107 → 151/120). No word lists changed.

## Before / after (a62f935 classifier vs this change, Python port)

| Phrase | a62f935 | fixes16 | expected |
|---|---|---|---|
| `Explain why the nightly build, refactor and test the parser` | general | coding | coding |
| `Explain why our nightly build, refactor and test the parser` | general | coding | coding |
| `Explain why the slow test, fix and deploy the server` | general | coding | coding |
| `Explain why the previous build, refactor and test the parser` | general | coding | coding |
| `Explain why a clean build, refactor and test the parser` | general | coding | coding |
| `Explain why their latest deploy, fix and test the parser` | general | coding | coding |
| `Explain why this quick fix, refactor and test the parser` | general | coding | coding |
| `Explain why the slow unit test, refactor and deploy the server` | coding | coding | coding |
| `Explain why our nightly smoke run, fix and test the parser` | general | coding | coding |
| `Explain why our team's nightly build, refactor and test the parser` | general | coding | coding |
| `Explain what the nightly build, refactor and test the parser` | general | coding | coding |
| `Explain how the slow test, fix and deploy the server` | general | coding | coding |
| `Can you explain why the nightly build, refactor and test the parser?` | general | coding | coding |
| `Explain why the nightly build, and refactor and test the parser` | coding | coding | coding |
| `Explain why the nightly build, then fix the parser` | coding | coding | coding |
| `Explain why the nightly build fails` | general | general | general |
| `Explain why our nightly build fails` | general | general | general |
| `Explain why the slow test times out` | general | general | general |
| `Explain what the slow unit test does` | general | general | general |
| `Explain how the nightly build works` | general | general | general |
| `Explain how the nightly build, test and deploy steps work` | general | general | general |
| `Explain why the nightly build, write and update the summary` | general | general | general |
| `Why does the nightly build fail?` | general | general | general |
| `Explain why the developers build, test and deploy the server` | general | general | general |
| `Explain why the senior developers build, test and deploy the server` | general | general | general |
| `Explain why our senior developers fix, test and deploy the server` | general | general | general |
| `Explain why the team members build, test and deploy the server` | general | general | general |
| `Explain why the developers often build, test and deploy the server` | general | general | general |
| `Explain why the developers also build, test and deploy the server` | general | general | general |

"the slow unit test" and the two ", and/then" variants were already coding: "unit test" is a code phrase, and "and"/"then" after the comma reopen an imperative. They stay as regression guards. Across the whole shared Swift table (271 phrases), old vs new Python results differ only on the 12 phrases above that flip from general to coding. Every fixes8/11/12/13/14/15 expectation is unchanged, including "Explain why the developers build, test and deploy the server" (general), "Explain why we install, configure and run the server" (general) and "Explain why we add tests, and fix the parser" (coding).

## Tests

- `sim/test_fixes16.py`: 5 test methods, 29 phrases (15 coding, 14 general), plus unit checks of `follows_determiner` / `looks_plural`. Every phrase is asserted to be in the Swift table with the same expectation. 28 are new Swift entries; "the developers build, test and deploy the server" was already in the general table.
- Full discovery, `PYTHONPATH=sim python3 -B -m unittest discover -s sim`:
  - before (a62f935): **Ran 335 tests, OK (skipped=7)**, exit 0
  - after: **Ran 340 tests, OK (skipped=7)**, exit 0
  - Both logs also contain an early `Ran 0 tests … NO TESTS RAN` block. It is printed in the middle of the dot stream (probably by a test that starts a child unittest run; not traced further). The discovery totals are the final `Ran` lines above.
- Swift: **not built or run here** (no toolchain on this Linux host). The Swift edit mirrors the Python line for line. The Python port reads the Swift word lists, and the Python test checks the Swift table contents, but not the Swift control flow. On the Mac:

```sh
cd <checkout> && swift build
swift test --filter GoalTests
swift test
```

## Limits (heuristic, no POS tagging)

- Collective or irregular-plural subjects count as modifiers: "Explain why the team build, test and deploy the server" and "… the children build, test and deploy …" are now **coding** (they were general). In American English the first is ungrammatical ("the team builds"), and the second is rare in goals.
- A plural-looking word inside the noun phrase stops the scan, so a plural possessive keeps the old (general) result: "the developers' nightly build, refactor and test the parser" (tokenised as "developers nightly build"). Adjectives ending in -ous ("previous", "various") are not treated as plural and do give coding.
- The scan covers at most 3 modifiers. "the really slow nightly smoke test, fix and deploy the server" (4) is still general.
- "that" is in `nounDeterminers`, so "… that <word> build, …" used as a complementizer is read as a noun phrase. This is unchanged in kind from fixes15.
