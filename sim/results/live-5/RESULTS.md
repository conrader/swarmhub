# QA live transport results

QA-LIVE5-20261019T121259-6e1eae

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
| QA-P02-webhook-register | PASS | entrypoint exit=0 |
| QA-P02-webhook-private-key | PASS | Key 0600, directory 0700; only path exported |
| QA-P02-webhook-idempotent | PASS | entrypoint exit=0 |
| QA-P02-webhook-stable-registration | PASS | Registration is idempotent |
| QA-P02-webhook-fire | PASS | entrypoint exit=0 |
| QA-P02-webhook-rotate | PASS | entrypoint exit=0 |
| QA-P02-webhook-reject-old-key | PASS | entrypoint exit=77 |
| QA-P02-webhook-http-stale | PASS | HTTP 403; {"error": "webhook rejected"}
 |
| QA-P02-webhook-http-rotated | PASS | HTTP 202; {"delivery": "delivery.d2636c9f8a30468d831e65c070b9c060", "profile": "QA-Infra", "routine": "QA-wake", "status": "pending"}
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
| QA-cleanup-run-run_0375a623ec354b1c80bb69e8e0900799 | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_0d3c3152930b488ba71546f8dd0ec074 | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_0dbf02a4b4f140bda7fdb899ae6331bf | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_18ab4d0fb9784af7a8c940588615cc9b | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_1a8e402ed67d4f1aa29294f17d4df9ca | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_467f629f090643fbaa5ddae03ee0c2be | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_5b79310e941f492289962bf92f9b1833 | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_605239c384814eddab0fc475075d0253 | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_65e99152d74a4102b2c12fcb1e4a4e10 | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_7dd3ff3ffbcd4d0f926cd31cfd12bafa | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_b0a3e03a7f6f40a0b883957408c94e32 | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_b836380cf3ed4e41a17e2f2a6ca8e1a6 | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_c42e66174c524c998635a69c31f92061 | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_c9e43d2f4c2048728eeb0f10f2e079ca | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_d02b38fda2a54e93b79d567b141d5185 | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_d361592620c54dfe8549f22add5c1ac1 | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_ddfc6e6559c84eb7acc0e5e360cf7a02 | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_e13299db86824477b2b6546fab8112fd | PASS | Remote terminal status=completed |
| QA-cleanup-session-QA-LIVE5-20261019T121259-6e1eae-QA-Ermes-from-QA-Infra | PASS | Exact owned session deleted and independently absent |
| QA-cleanup-session-QA-LIVE5-20261019T121259-6e1eae-QA-Ermes-from-QA-Jarvis | PASS | Exact owned session deleted and independently absent |
| QA-cleanup-session-QA-LIVE5-20261019T121259-6e1eae-QA-Ermes-from-QA-Swarmhub | PASS | Exact owned session deleted and independently absent |
| QA-cleanup-session-QA-LIVE5-20261019T121259-6e1eae-QA-Infra-from-QA-Infra | PASS | Exact owned session deleted and independently absent |
| QA-cleanup-session-QA-LIVE5-20261019T121259-6e1eae-QA-Infra-from-QA-Jarvis | PASS | Exact owned session deleted and independently absent |
| QA-cleanup-session-QA-LIVE5-20261019T121259-6e1eae-QA-Jarvis-from-QA-Swarmhub | PASS | Exact owned session deleted and independently absent |
| QA-cleanup-session-QA-LIVE5-20261019T121259-6e1eae-QA-Konrad-from-QA-Swarmhub | PASS | Exact owned session deleted and independently absent |
| QA-cleanup-session-QA-LIVE5-20261019T121259-6e1eae-QA-Swarmhub-from-QA-Ermes | PASS | Exact owned session deleted and independently absent |
| QA-cleanup-session-QA-LIVE5-20261019T121259-6e1eae-QA-Swarmhub-from-QA-Infra | PASS | Exact owned session deleted and independently absent |
| QA-cleanup-session-QA-LIVE5-20261019T121259-6e1eae-QA-Swarmhub-from-QA-Jarvis | PASS | Exact owned session deleted and independently absent |
| QA-cleanup-local-processes | PASS | No isolated runtime processes remain |
| QA-cleanup-private-files | PASS | Temporary QA credentials/state removed after evidence export |
