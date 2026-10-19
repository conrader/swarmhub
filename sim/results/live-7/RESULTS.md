# QA live transport results

QA-LIVE6-20261019T125425-f25fad

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
| QA-P01-first-verified | PASS | status done; cli-exit 0; evidence tests; commit false; tests true |
| QA-P01-next-launched-unasked | PASS | second job status done; cli-exit 0 |
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
| QA-P02-webhook-http-rotated | PASS | HTTP 202; {"delivery": "delivery.5435185d91b14a2a95dd66cd8edd5777", "profile": "QA-Infra", "routine": "QA-wake", "status": "pending"}
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
| QA-P07-corrected-scope-verified | PASS | Replacement ran the real CLI; evidence=tests |
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
| QA-cleanup-run-run_0d5a067272d94203a677bac0bd7afab7 | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_1a1e202029ae40d493e3864308a0ac72 | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_287133b478e7424db2694576e73654e5 | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_2913c7d8f99442fe8fc553694cf26441 | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_2ad3150f270947d780516171412f9406 | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_32bdea7956124a2284238e742e6f8553 | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_3517e694b2c94d5eb1b7381d91fa431e | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_359572f412634abaadee48878f453a6d | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_5004422c6a2b40b78c06916c7da214cd | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_57257f7419cd418d8fff7099d4b7f953 | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_758f99513ac4485f861168efac50e7e9 | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_86bc103aca9a4871b8244bd9252b3479 | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_98441c47d3ae49d49a43cec68abe4a35 | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_a3717dc30fd24e1db5d0885362d9d554 | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_c15a24a8e6324ce7b14b753de8584085 | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_c51d730841a842a5934bb5188bf4f891 | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_d79a9fcbc818489193fa18a719b02ab7 | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_e696643ce6eb4c4a9b0c049c7f99bc1f | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_eaa2cd2761024f2697736fbe37f636c2 | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_f129ae5948fe4ea0bbde9b98c723f675 | PASS | Remote terminal status=completed |
| QA-cleanup-session-QA-LIVE6-20261019T125425-f25fad-QA-Ermes-from-QA-Infra | PASS | Exact owned session deleted and independently absent |
| QA-cleanup-session-QA-LIVE6-20261019T125425-f25fad-QA-Ermes-from-QA-Jarvis | PASS | Exact owned session deleted and independently absent |
| QA-cleanup-session-QA-LIVE6-20261019T125425-f25fad-QA-Ermes-from-QA-Swarmhub | PASS | Exact owned session deleted and independently absent |
| QA-cleanup-session-QA-LIVE6-20261019T125425-f25fad-QA-Infra-from-QA-Infra | PASS | Exact owned session deleted and independently absent |
| QA-cleanup-session-QA-LIVE6-20261019T125425-f25fad-QA-Infra-from-QA-Jarvis | PASS | Exact owned session deleted and independently absent |
| QA-cleanup-session-QA-LIVE6-20261019T125425-f25fad-QA-Jarvis-from-QA-Swarmhub | PASS | Exact owned session deleted and independently absent |
| QA-cleanup-session-QA-LIVE6-20261019T125425-f25fad-QA-Konrad-from-QA-Swarmhub | PASS | Exact owned session deleted and independently absent |
| QA-cleanup-session-QA-LIVE6-20261019T125425-f25fad-QA-Swarmhub-from-QA-Ermes | PASS | Exact owned session deleted and independently absent |
| QA-cleanup-session-QA-LIVE6-20261019T125425-f25fad-QA-Swarmhub-from-QA-Infra | PASS | Exact owned session deleted and independently absent |
| QA-cleanup-session-QA-LIVE6-20261019T125425-f25fad-QA-Swarmhub-from-QA-Jarvis | PASS | Exact owned session deleted and independently absent |
| QA-source-auth-config-unchanged | PASS | Source auth/config contents and metadata unchanged |
| QA-cleanup-local-processes | PASS | No isolated runtime processes remain |
| QA-cleanup-private-files | PASS | Temporary QA credentials/state removed after evidence export |
