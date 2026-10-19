# QA live transport results

QA-LIVE5-20261019T120917-1980b7

App/Swift projections are source-derived, not runtime execution.

| Scenario | Status | Detail |
| --- | --- | --- |
| QA-P02-register-QA-Ermes | PASS | entrypoint exit=0 |
| QA-P02-register-QA-Infra | PASS | entrypoint exit=0 |
| QA-P02-register-QA-Jarvis | PASS | entrypoint exit=0 |
| QA-P02-register-QA-Konrad | PASS | entrypoint exit=0 |
| QA-P02-register-QA-Swarmhub | PASS | entrypoint exit=0 |
| QA-P07-P08-policy | PASS | entrypoint exit=0 |
| QA-P01-submit-first | PASS | entrypoint exit=0 |
| QA-P01-submit-next | PASS | entrypoint exit=0 |
| QA-P01-first-verified | FAIL | status failed; cli-exit 1; evidence none; commit not-checked; tests not-run |
| QA-preflight-interrupted | FAIL | CLI startup failed before provider call: auth home read-only. Harness interrupted while waiting for held next job; exact cleanup resumed from retained evidence. |
| QA-cleanup-session-QA-LIVE5-20261019T120917-1980b7-QA-Jarvis-from-QA-Swarmhub | PASS | Exact owned session deleted and independently absent |
| QA-cleanup-local-processes | PASS | No isolated runtime processes remain |
| QA-cleanup-private-files | PASS | Temporary QA credentials/state removed after evidence export |
