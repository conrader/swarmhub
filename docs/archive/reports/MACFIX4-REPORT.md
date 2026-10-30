# Macfix4 report

Restored `Tests/AgentAppTests/GoalTests.swift` from `bd5b98b~1`, retained the fixes5 regression test verbatim, and adjusted three goal commands for fixes5's explicit coding-evidence mode. No application code changed. No commit was made. Starting HEAD: `4218f34`.

## What was wrong

Confirmed the brief's hunch: `bd5b98b` replaced the entire goal test suite with an exact copy of all 182 lines of `Sources/AgentApp/Models/ChatAutomation.swift`, followed by `goalEvidenceFollowsExplicitTypeAndRejectsPlaceholders`. It removed all 13 original tests, both private helpers, the reply fixtures, `import Testing`, and `@testable import AgentApp`.

The copied model declarations were compiled inside the test module without access to app types such as `LoopRun` and `SwarmhubBlock`. The unresolved loop type also caused cascading Codable/Equatable diagnostics on `ChatAutomation`. The missing Testing import explains the unknown `@Test` and `#expect` diagnostics. Restoring the test file removes those duplicate declarations and restores the required imports.

## Diff rationale

Compared with the pre-fixes5 suite, the repaired file differs only by the appended fixes5 test and three `/goal --coding` prefixes:

- `aGoalRunsRoundsUntilTheDoneBlock`: explicitly requests coding evidence so its exact commit/report claim on the completion card remains required.
- `evidenceRequestsRespectPauseAndTheRoundBudget`: explicitly requests coding evidence so `bareDoneReply` still lacks sufficient evidence. Its visible text, `All shipped.`, would otherwise satisfy the general-goal rule introduced by fixes5.
- `aDoneWithoutEvidenceIsSentBackAndThenBlocks`: explicitly requests coding evidence so the retry, evidence prompt, blocked state, and eventual commit/report completion assertions still exercise their original contract.

Every original assertion is unchanged. The remaining ten original tests retain their original commands because they test parsing, evidence validation, or lifecycle behavior that does not require the coding mode. The restored evidence-parser test still rejects placeholder commits and report paths. The preserved fixes5 test checks acceptance of a general deliverable, rejection of a placeholder deliverable, rejection of prose/deliverable-only evidence for coding goals, and acceptance of tests plus a report for coding goals. The repaired suite contains 14 tests.

## Other Swift files audited

Reviewed every other Swift diff in `bd5b98b` and `4218f34` for replacement of unrelated content or copied declarations:

| File | Finding |
| --- | --- |
| `Sources/AgentApp/Models/ChatAutomation.swift` | Targeted goal-type, prompt, and deliverable parsing changes; this was the source of the accidental test-file copy. |
| `Sources/AgentApp/Models/GroupChat.swift` | Targeted managed-approval persistence additions. |
| `Sources/AgentApp/Models/ManagedActions.swift` | Targeted removal of model-mediated decisions and shared secret-intake path changes. |
| `Sources/AgentApp/Models/ManagedControl.swift` | New runtime-record/control implementation with its own declarations; no unrelated file copied into it. |
| `Sources/AgentApp/Models/Models.swift` | Two managed-approval state fields added. |
| `Sources/AgentApp/Stores/AppStore+Goals.swift` | Targeted explicit coding flag and evidence-by-type changes, used to reason through the restored tests. |
| `Sources/AgentApp/Stores/AppStore+ManagedActions.swift` | Intentional replacement of decision-turn methods with runtime lookup, bound decisions, and receipt reconciliation; secret methods retained. |
| `Sources/AgentApp/Stores/AppStore+ModelPolicy.swift` | Managed approvals added to store serialization. |
| `Sources/AgentApp/Stores/AppStore.swift` | Control injection/state and approval restoration additions in fixes5; only the closure's `@MainActor` annotation/comment in macfix3. |
| `Tests/AgentAppTests/BotMessageSkillTests.swift` | Two skill-version expectations updated; test imports and suite retained. |
| `Tests/AgentAppTests/CodingSkillTests.swift` | Skill-version and sandbox-helper packaging expectations updated; test imports and suite retained. |
| `Tests/AgentAppTests/ManagedActionsTests.swift` | Intentional runtime-binding/retry test replacements and secret-writer integration test; test imports and other tests retained. |

No other accidental overwrite or duplication of this kind was found. A whole-file containment scan compared all 13 distinct changed Swift files at `4218f34` against 642 tracked Swift source/test files. Its only match was the broken `GoalTests.swift` containing `ChatAutomation.swift`.

## Verification

- Static comparison against `git show bd5b98b~1:Tests/AgentAppTests/GoalTests.swift` passed: reversing exactly the three command-prefix changes and removing the preserved fixes5 test reproduces the original file byte for byte.
- Verified all 13 original test names remain, the fixes5 test is preserved verbatim, the Testing/app imports are restored, and the copied model declarations are absent.
- `git diff --check` passed.
- `command -v swift` returned no path. Swift compilation and tests could not run here; these static checks do not establish a passing native build.

On the Mac, run `swift build && swift test` to verify the repaired suite and the rest of the Swift package.
