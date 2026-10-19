# QA live transport results

QA-LIVE6-20261019T123723-3300b6

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
| QA-P01-first-verified | FAIL | status failed; cli-exit 0; evidence none; commit not-checked; tests not-run |
| QA-P01-next-launched-unasked | FAIL | second job status queued; cli-exit None |
| QA-QA-P01-CLI-queue | PASS | entrypoint exit=0 |
| QA-P01-P04-coordinator-correction | PASS | entrypoint exit=0 |
| QA-P01-stop-blocked-next | PASS | entrypoint exit=0 |
| QA-P01-stop-failed-first | PASS | entrypoint exit=0 |
| QA-P02-Infra-register-request | PASS | entrypoint exit=0 |
| QA-P02-unknown-origin-code-job | PASS | entrypoint exit=69 |
| QA-QA-P02-fallback | PASS | entrypoint exit=0 |
| QA-P04-correct-failed-report | PASS | entrypoint exit=0 |
| QA-P02-webhook-register | PASS | entrypoint exit=0 |
| QA-P02-webhook-private-key | PASS | Key 0600, directory 0700; only path exported |
| QA-P02-webhook-idempotent | PASS | entrypoint exit=0 |
| QA-P02-webhook-stable-registration | PASS | Registration is idempotent |
| QA-P02-webhook-fire | PASS | entrypoint exit=0 |
| QA-P02-webhook-rotate | PASS | entrypoint exit=0 |
| QA-P02-webhook-reject-old-key | PASS | entrypoint exit=77 |
| QA-P02-webhook-http-stale | PASS | HTTP 403; {"error": "webhook rejected"}
 |
| QA-P02-webhook-http-rotated | PASS | HTTP 202; {"delivery": "delivery.0e937a65638f4f34b41d5a546d1271b3", "profile": "QA-Infra", "routine": "QA-wake", "status": "pending"}
 |
| QA-QA-P02-webhook | PASS | entrypoint exit=0 |
| QA-P06-secure-intake | PASS | entrypoint exit=0 |
| QA-P06-configure-synthetic-provisioner | PASS | entrypoint exit=0 |
| QA-P06-synthetic-provision-gate | PASS | entrypoint exit=0 |
| QA-P06-owner-gate-before-hook | PASS | Synthetic hook cannot execute before owner decision |
| QA-P06-wrong-actor-rejected | PASS | entrypoint exit=64 |
| QA-P06-admin-fixture-approve | PASS | entrypoint exit=0 |
| QA-P06-synthetic-hook-completed | PASS | Synthetic provisioner consumed path; no real host or model key |
| QA-QA-P06-synthetic-provision | PASS | entrypoint exit=0 |
| QA-P03-held-FYI | PASS | entrypoint exit=0 |
| QA-P03-no-held-wake | PASS | Held admission caused zero HTTP/model requests |
| QA-P06-priority-late-provision | PASS | entrypoint exit=0 |
| QA-QA-P03-P06-held-and-late | PASS | entrypoint exit=0 |
| QA-P06-provision-gate | PASS | entrypoint exit=0 |
| QA-P06-admin-fixture-deny | PASS | entrypoint exit=0 |
| QA-P05-global-quota-policy | PASS | entrypoint exit=0 |
| QA-P05-broadcast-QA-Swarmhub | PASS | entrypoint exit=0 |
| QA-P05-broadcast-QA-Infra | PASS | entrypoint exit=0 |
| QA-P05-broadcast-QA-Ermes | PASS | entrypoint exit=0 |
| QA-P05-route-enforced | PASS | entrypoint exit=0 |
| QA-P05-no-speculation | PASS | entrypoint exit=64 |
| QA-QA-P05-policy-acks | PASS | entrypoint exit=0 |
| QA-P07-gate-money | PASS | entrypoint exit=0 |
| QA-P07-present-approval-fence | PASS | entrypoint exit=0 |
| QA-P07-deny-money | PASS | entrypoint exit=0 |
| QA-P07-denial-final-money | PASS | entrypoint exit=64 |
| QA-P07-gate-prod | PASS | entrypoint exit=0 |
| QA-P07-deny-prod | PASS | entrypoint exit=0 |
| QA-P07-denial-final-prod | PASS | entrypoint exit=64 |
| QA-P07-gate-secrets | PASS | entrypoint exit=0 |
| QA-P07-deny-secrets | PASS | entrypoint exit=0 |
| QA-P07-denial-final-secrets | PASS | entrypoint exit=64 |
| QA-P07-old-scope | PASS | entrypoint exit=0 |
| QA-P07-peer-child | PASS | entrypoint exit=0 |
| QA-P07-associated-held | PASS | entrypoint exit=0 |
| QA-P07-replace-scope | PASS | entrypoint exit=0 |
| QA-QA-P07-scope-cancel | PASS | entrypoint exit=0 |
| QA-P07-stop-gated-fixture | PASS | entrypoint exit=0 |
| QA-P07-running-scope | PASS | entrypoint exit=0 |
| QA-P07-real-job-running | PASS | code-job and its CLI tree alive before the scope change |
| QA-P07-kill-running-scope | PASS | entrypoint exit=0 |
| QA-P07-running-process-killed | PASS | status cancelled; cli-exit 125 |
| QA-QA-P07-running-scope-killed | PASS | entrypoint exit=0 |
| QA-P07-corrected-scope-verified | FAIL | Replacement ran the real CLI; evidence=none |
| QA-P09-autonomous-read | PASS | entrypoint exit=0 |
| QA-P09-outbound-FAKE | PASS | entrypoint exit=0 |
| QA-P09-no-send | PASS | FAKE argv never executed; allowlisted read completed without approval |
| QA-P07-exact-draft-FAKE-submit | PASS | entrypoint exit=0 |
| QA-P07-exact-draft-repeat | PASS | entrypoint exit=0 |
| QA-P07-draft-idempotent | PASS | Exact app-shaped draft spec admitted once; no native UI click |
| QA-P07-P09-policy-result | PASS | entrypoint exit=0 |
| QA-QA-P09-autonomy | PASS | entrypoint exit=0 |
| QA-P08-report-real-current-time | PASS | entrypoint exit=0 |
| QA-QA-P08-report-delivery | PASS | entrypoint exit=0 |
| QA-P10-offline-durable | PASS | entrypoint exit=0 |
| QA-QA-P10-unreachable-pending | PASS | entrypoint exit=0 |
| QA-QA-P10-automatic-retry | PASS | entrypoint exit=0 |
| QA-cleanup-run-run_01761b9d8c2d456ab77ab6d5b4df0481 | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_072f577212c347568fb28be743c32d3a | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_19887c5db99148d5971eeb4f5c83ba30 | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_1f03a19260ae4d6f863577ca0151534b | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_217db803f81a44788284b047cac48b79 | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_2c590161aa1742da9cc4e937d8690212 | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_4536abd065814e7ea23048fc55d86933 | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_5effb1e28def4f96baa819a4364536bd | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_66848380b31344f0b046328177f89dd6 | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_7e36db6353d24c2ea0443b5ecf39fc0f | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_8180a161b7f24f2e807297e83f0f7fa8 | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_8b0269792530488ab7d5386f7c13aa0a | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_8b5776e93e724cc18ff69c7a26c19a39 | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_96e7f9ebba1b40faa56ed5f32ca288ce | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_b08cc7f000fe4e8698286a47a2651eeb | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_c0b64d2e3844404e93462db66709bc62 | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_cc73189b4ed7444e8adf93f10677c9e8 | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_ea9eda1eec264b03a5b10d6bdbcf7025 | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_f5f94ddee23e4ba49df34ed4251ebe1f | PASS | Remote terminal status=completed |
| QA-cleanup-session-QA-LIVE6-20261019T123723-3300b6-QA-Ermes-from-QA-Infra | PASS | Exact owned session deleted and independently absent |
| QA-cleanup-session-QA-LIVE6-20261019T123723-3300b6-QA-Ermes-from-QA-Jarvis | PASS | Exact owned session deleted and independently absent |
| QA-cleanup-session-QA-LIVE6-20261019T123723-3300b6-QA-Ermes-from-QA-Swarmhub | PASS | Exact owned session deleted and independently absent |
| QA-cleanup-session-QA-LIVE6-20261019T123723-3300b6-QA-Infra-from-QA-Infra | PASS | Exact owned session deleted and independently absent |
| QA-cleanup-session-QA-LIVE6-20261019T123723-3300b6-QA-Infra-from-QA-Jarvis | PASS | Exact owned session deleted and independently absent |
| QA-cleanup-session-QA-LIVE6-20261019T123723-3300b6-QA-Jarvis-from-QA-Swarmhub | PASS | Exact owned session deleted and independently absent |
| QA-cleanup-session-QA-LIVE6-20261019T123723-3300b6-QA-Konrad-from-QA-Swarmhub | PASS | Exact owned session deleted and independently absent |
| QA-cleanup-session-QA-LIVE6-20261019T123723-3300b6-QA-Swarmhub-from-QA-Ermes | PASS | Exact owned session deleted and independently absent |
| QA-cleanup-session-QA-LIVE6-20261019T123723-3300b6-QA-Swarmhub-from-QA-Infra | PASS | Exact owned session deleted and independently absent |
| QA-cleanup-session-QA-LIVE6-20261019T123723-3300b6-QA-Swarmhub-from-QA-Jarvis | PASS | Exact owned session deleted and independently absent |
| QA-source-auth-config-unchanged | PASS | Source auth/config contents and metadata unchanged |
| QA-cleanup-local-processes | PASS | No isolated runtime processes remain |
| QA-cleanup-private-files | PASS | Temporary QA credentials/state removed after evidence export |
