# QA live transport results

QA-LIVE2-20261019T085320-01fd3e

App/Swift projections are source-derived, not runtime execution.

| Scenario | Status | Detail |
| --- | --- | --- |
| QA-create-A08-queue | PASS | Exactly registered QA session |
| QA-A09-pending-observable | PASS | Detached run exposes actual unanswered clarify in status |
| QA-B05-idempotent-replay | PASS | Fresh connection replays same Idempotency-Key; same run, no second accepted execution |
| QA-A03-busy-queue | PASS | Same-session second turn waits behind human input |
| QA-A08-cancel-before-dispatch | PASS | Queued turn cancelled before owner answers |
| QA-A10-no-pending-approval | FAIL | Approval decision cannot resolve a clarify-only wait; actual dangerous tools disabled |
| QA-A10-stale-generation | PASS | Wrong generation cannot consume live question |
| QA-A09-answer-resume | PASS | One actual question answer resumes only its owner run |
| QA-B07-detached-reconnect | PASS | New events subscriber recovers settled detached run without model replay |
| QA-create-B08-model-failure | PASS | Exactly registered QA session |
| QA-B08-model-failure | PASS | Single deliberate unavailable-model turn; explicit terminal failure beats done |
| QA-create-A16-verification | PASS | Exactly registered QA session |
| QA-A16-reject-unverified-claim | PASS | Independent session rejects wrong arithmetic and missing verification; same model, cross-model gating untested |
| QA-cleanup-run-run_929776a9e8a5476c85b4e6b4fa76f660 | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_d1d5d93ab59e462db66c8f14cc7809b3 | PASS | Remote terminal status=cancelled |
| QA-cleanup-run-run_f3e82ecb067c4ebdad0c2a98a535d376 | PASS | Remote terminal status=failed |
| QA-cleanup-run-run_fd15ae95f77f4474bc08d476c489d8aa | PASS | Remote terminal status=completed |
| QA-cleanup-session-QA-LIVE2-20261019T085320-01fd3e-A08-queue | PASS | Exact owned session deleted and independently absent |
| QA-cleanup-session-QA-LIVE2-20261019T085320-01fd3e-A16-verification | PASS | Exact owned session deleted and independently absent |
| QA-cleanup-session-QA-LIVE2-20261019T085320-01fd3e-B08-model-failure | PASS | Exact owned session deleted and independently absent |
