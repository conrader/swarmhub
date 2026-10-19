# QA live transport results

QA-LIVE8-20261019T131927-cbc9f5

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
| QA-P01-Jarvis-relay | PASS | {"receiving_turn": "QA-bridge-002", "action": {"op": "relay", "job": "job.879dd917a161465498be920945e11b38", "instruction": "QA-Jarvis review: the receipt reports worker exit 0, a fresh report, and verification-command exit 0. Work correctness and report correctness remain unverified; HEAD is unchanged, so no commit is verified. Check whether this job has already been handled before repeating any action. Review the durable record, report, diff, and verification evidence; test the acceptance criteria and fix any issues. After review passes, commit the reviewed changes, rebuild and verify the result, then select the next work under the current policy. Report actual review findings, test and rebuild outcomes, commit ID, and selected next work; do not claim success without evidence."}} |
| QA-P01-first-output-and-build-compile-test | PASS | entrypoint exit=0 |
| QA-P01-first-output-and-build | PASS | {"job": "task.879dd917a161465498be920945e11b38", "report_sha256": "f1b7cc34b75f457ac95f8cef4f5312c429eb61c27d809cefcc1bf37b1336933d", "fields": {"status": "ok", "exit": "0", "cli-exit": "0", "model": "gpt-6-astra", "effort": "high", "report": "/tmp/QA-LIVE8-s5_0yd3c/QA-repo/QA-P01-first.txt", "report-valid": "true", "report-sha256": "f1b7cc34b75f457ac95f8cef4f5312c429eb61c27d809cefcc1bf37b1336933d", "head-before": "0f5e2b54b4480dcca5d97e30285bac3bd5996a5a", "head-after": "0f5e2b54b4480dcca5d97e30285bac3bd5996a5a", "commit-evidence": "false", "verify-exit": "0", "tests-passed": "true"}, "verification": {"time_ns": 1792416021641929004, "source_sha256": "ba1a531f581d2e6094e978ed6f7aca7a8d92eeb62c6e7ad73ee692f7f18bc772", "compiled": true, "tests_run": 2, "passed": true}, "proof_sha256": "a2fdb298579d65921b48dbb6368c1a1ce4f5b11c5f41461cfff775f9adc67ee1"} |
| QA-P01-review-diff | PASS | entrypoint exit=0 |
| QA-P01-ordering-review | PASS | entrypoint exit=0 |
| QA-P01-ordering-reviewed | PASS | {"receiving_turn": "QA-bridge-004", "action": {"op": "review_commit_rebuild", "job": "task.879dd917a161465498be920945e11b38", "report_sha256": "f1b7cc34b75f457ac95f8cef4f5312c429eb61c27d809cefcc1bf37b1336933d", "head": "0f5e2b54b4480dcca5d97e30285bac3bd5996a5a", "review": "The supplied source diff correctly fixes add(a, b) by replacing subtraction with addition; it shows no other function changes. The supplied independent verification records successful compilation, two passing tests, and verification exit 0, consistent with the report. The report names test_add and test_next, but the independent proof supplies only their aggregate count. NOTES.md and its requested line are reported but not shown in the supplied diff, so their contents remain unverified. HEAD before and after are identical and commit-evidence is false: no commit or post-commit rebuild is established. No prior handled action appears in the supplied evidence; durable deduplication must be checked before repeating a mutation. Request the bound review/commit/rebuild operation, with NOTES.md acceptance verification and duplicate-action checking before committing. Commit ID, rebuild outcome, and next-work selection remain pending the real receipt."}} |
| QA-P01-reviewed-head | PASS | entrypoint exit=0 |
| QA-P01-ordering-stage | PASS | entrypoint exit=0 |
| QA-P01-ordering-commit | PASS | entrypoint exit=0 |
| QA-P01-ordering-new-head | PASS | entrypoint exit=0 |
| QA-P01-ordering-committed-diff | PASS | entrypoint exit=0 |
| QA-P01-ordering-rebuild-test | PASS | entrypoint exit=0 |
| QA-P01-ordering-commit-rebuilt | PASS | {"head_before": "0f5e2b54b4480dcca5d97e30285bac3bd5996a5a", "head_after": "f2c4d6af789d2eedfa25bf80c81f5df325f32589", "verification": {"time_ns": 1792416030871451327, "source_sha256": "ba1a531f581d2e6094e978ed6f7aca7a8d92eeb62c6e7ad73ee692f7f18bc772", "compiled": true, "tests_run": 2, "passed": true}} |
| QA-P01-ordering-pick-next | PASS | entrypoint exit=0 |
| QA-P01-ordering-selected-next | PASS | {"receiving_turn": "QA-bridge-006", "action": {"op": "launch_next", "head": "f2c4d6af789d2eedfa25bf80c81f5df325f32589", "build_sha256": "fb6db02973550e73f492adddff19f090d392a9bda0864745a9880645512ee944", "next": "multiply"}} |
| QA-P01-bot-selected-next-submit | PASS | entrypoint exit=0 |
| QA-P01-next-submitted-unasked | PASS | {"job": "task.2b1f6419e3f04d5db2d7c7a726c4c1ef", "selected_by": "P01-ordering-selected-next", "preloaded_queue": false} |
| QA-P01-next-verified-compile-test | PASS | entrypoint exit=0 |
| QA-P01-next-verified | PASS | {"job": "task.2b1f6419e3f04d5db2d7c7a726c4c1ef", "report_sha256": "ab31b25932a714f95d18d1f3f3294036333d3616b5e759184c53ebb032d4f9d5", "fields": {"status": "ok", "exit": "0", "cli-exit": "0", "model": "gpt-6-astra", "effort": "high", "report": "/tmp/QA-LIVE8-s5_0yd3c/QA-repo/QA-P01-next-multiply.txt", "report-valid": "true", "report-sha256": "ab31b25932a714f95d18d1f3f3294036333d3616b5e759184c53ebb032d4f9d5", "head-before": "f2c4d6af789d2eedfa25bf80c81f5df325f32589", "head-after": "1517b64ff8138121e6342ade1c42c80aefde7009", "commit-evidence": "true", "verify-exit": "0", "tests-passed": "true"}, "verification": {"time_ns": 1792416087587978501, "source_sha256": "e7f018d15cf4f7906638bfd1b52b2d18263b491ffd555320de3eb0b9cc970c3a", "compiled": true, "tests_run": 2, "passed": true}, "proof_sha256": "5a36f59e0d899228ce77c835e88c3207d9d86d891a73e9b059091b8d82ba7249"} |
| QA-P01-next-launched-unasked | PASS | {"job": "task.2b1f6419e3f04d5db2d7c7a726c4c1ef", "cli_exit": "0", "selected_by": "P01-ordering-selected-next", "preloaded_queue": false} |
| QA-QA-P01-full-chain | PASS | entrypoint exit=0 |
| QA-P04-submit-real-empty | PASS | entrypoint exit=0 |
| QA-P04-real-empty-rejected | PASS | {"job": "task.ed6678ceec4a410facf21dd47eb7b4fe", "fields": {"status": "failed", "exit": "65", "cli-exit": "0", "model": "gpt-6-astra", "effort": "high", "report": "/tmp/QA-LIVE8-s5_0yd3c/QA-repo/QA-P04-empty.txt", "report-valid": "false", "report-sha256": "missing-or-empty", "head-before": "1517b64ff8138121e6342ade1c42c80aefde7009", "head-after": "-", "commit-evidence": "not-checked", "verify-exit": "-", "tests-passed": "not-run"}} |
| QA-P04-Jarvis-corrected | PASS | {"receiving_turn": "QA-bridge-010", "action": {"op": "correct", "job": "job.ed6678ceec4a410facf21dd47eb7b4fe", "model": "gpt-6-astra", "effort": "high", "instruction": "Relaunch the failed job to correct its output contract. The receipt records exit 65, no report, and no verification run; this is not success. Produce a fresh, nonempty report at /tmp/QA-LIVE8-s5_0yd3c/QA-repo/QA-P04-empty.txt. Independently check report freshness and contents, review the actual work against its acceptance criteria, and run /usr/bin/python3 /tmp/QA-LIVE8-s5_0yd3c/QA-verify.py /tmp/QA-LIVE8-s5_0yd3c/QA-repo add /tmp/QA-LIVE8-s5_0yd3c/QA-P04-empty-verify.json. Check that verification output is fresh and confirms passing tests; command exit alone is insufficient. Verify any required commit separately. Report real evidence and remaining failures, and do not claim success until independent fresh-output and test checks pass. Deduplicate this correction by job ID."}} |
| QA-P04-deliver-actionable-correction | PASS | entrypoint exit=0 |
| QA-P04-receiver-requested-relaunch | PASS | {"receiving_turn": "QA-bridge-012", "action": {"op": "relaunch", "failed_job": "task.ed6678ceec4a410facf21dd47eb7b4fe", "model": "gpt-6-astra", "effort": "high"}} |
| QA-P04-explicit-high-relaunch | PASS | entrypoint exit=0 |
| QA-P04-success-report-held-for-check | PASS | {"receiving_turn": "QA-bridge-014", "action": {"op": "await_independent_check", "job": "job.7e21b2f87e6d4034ad82f283727b823f"}} |
| QA-P04-fresh-output-independently-verified-compile-test | PASS | entrypoint exit=0 |
| QA-P04-fresh-output-independently-verified | PASS | {"job": "task.7e21b2f87e6d4034ad82f283727b823f", "report_sha256": "7ce793c239cc0b133042d0f50284d0a2f498a2dcb40db9d4039e499bec1496a4", "fields": {"status": "ok", "exit": "0", "cli-exit": "0", "model": "gpt-6-astra", "effort": "high", "report": "/tmp/QA-LIVE8-s5_0yd3c/QA-repo/QA-P04-corrected.txt", "report-valid": "true", "report-sha256": "7ce793c239cc0b133042d0f50284d0a2f498a2dcb40db9d4039e499bec1496a4", "head-before": "1517b64ff8138121e6342ade1c42c80aefde7009", "head-after": "ec334adbdfabe639571ed843d9ad20b6f057e98b", "commit-evidence": "true", "verify-exit": "0", "tests-passed": "true"}, "verification": {"time_ns": 1792416170502385703, "source_sha256": "e7f018d15cf4f7906638bfd1b52b2d18263b491ffd555320de3eb0b9cc970c3a", "compiled": true, "tests_run": 2, "passed": true}, "proof_sha256": "e85023c5e918735c454292dab6eeb2c3ce8b83d4a6a39e4ba2c092d1d551749f"} |
| QA-P04-verified-result-for-report | PASS | entrypoint exit=0 |
| QA-P04-success-after-independent-check | PASS | {"receiving_turn": "QA-bridge-016", "action": {"op": "report_success", "job": "task.7e21b2f87e6d4034ad82f283727b823f", "proof_sha256": "e85023c5e918735c454292dab6eeb2c3ce8b83d4a6a39e4ba2c092d1d551749f", "summary": "Independent proof confirms a fresh valid report at /tmp/QA-LIVE8-s5_0yd3c/QA-repo/QA-P04-corrected.txt, worker and CLI exit 0, successful source compilation, and two passing tests with verification exit 0. Commit evidence is true; HEAD advanced to ec334adbdfabe639571ed843d9ad20b6f057e98b. The report uses QA-P04-corrected.txt rather than the originally requested QA-P04-empty.txt."}} |
| QA-QA-P04-full-correction-chain | PASS | entrypoint exit=0 |
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
| QA-P02-webhook-http-rotated | PASS | HTTP 202; {"delivery": "delivery.42546e578ab042e795301dfa6a8d7fc8", "profile": "QA-Infra", "routine": "QA-wake", "status": "pending"}
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
| QA-P07-corrected-scope-verified | PASS | Replacement ran the real CLI; evidence=commit+tests |
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
| QA-cleanup-run-run_0b922cad129842f2a940bd87f610a65d | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_2292c6c4d85b43df96bf9a6eebdc41da | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_239936f13481436d883b4c9f7e2866dc | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_24859d354b064a378e3294af177c804d | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_24bcec6b409a488c89d86f7d013f012e | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_26c3513f61704ee68fc050a9ad0eeaff | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_2b379ebf70dd444798e4a206f676cc44 | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_3513df7a1fa144088960abe7b583a979 | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_3b559f4c93e64582978dbbe64c4d8f1c | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_3efaf02fd29c4afab2b3f7dd371a2311 | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_5175524d4b3b4f2598bf8f9aa8fb09d3 | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_51b2ccb6800c4528a00d39bf55e0e636 | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_55e2bedfbc5140d5aff4e5387463d7f2 | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_6b033f4369f241f8ad8a2eac80f908dc | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_6d0b6cc7d23c436eaa1bffea11670226 | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_7709ddc3b094473ea566fc7e8f710cf0 | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_87fc3afba6b548fa965b85dd0618b08e | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_97e65e16d40e4ba1b072f277a824dbfb | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_a6175fcae6cd4711b07742b79289375c | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_cde7e5ba83d547629ccc5690c4fd8419 | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_d1eea8754e3d45eaae8c598ebbf04fa2 | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_d9c3cd751b074063952cb3c40df291fe | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_dc25967ca4e243519be751eedaa53607 | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_dd938f2a5f7b4d8dad6ed340f12ca425 | PASS | Remote terminal status=completed |
| QA-cleanup-session-QA-LIVE8-20261019T131927-cbc9f5-QA-Ermes-from-QA-Infra | PASS | Exact owned session deleted and independently absent |
| QA-cleanup-session-QA-LIVE8-20261019T131927-cbc9f5-QA-Ermes-from-QA-Jarvis | PASS | Exact owned session deleted and independently absent |
| QA-cleanup-session-QA-LIVE8-20261019T131927-cbc9f5-QA-Ermes-from-QA-Swarmhub | PASS | Exact owned session deleted and independently absent |
| QA-cleanup-session-QA-LIVE8-20261019T131927-cbc9f5-QA-Infra-from-QA-Infra | PASS | Exact owned session deleted and independently absent |
| QA-cleanup-session-QA-LIVE8-20261019T131927-cbc9f5-QA-Infra-from-QA-Jarvis | PASS | Exact owned session deleted and independently absent |
| QA-cleanup-session-QA-LIVE8-20261019T131927-cbc9f5-QA-Jarvis-from-QA-Swarmhub | PASS | Exact owned session deleted and independently absent |
| QA-cleanup-session-QA-LIVE8-20261019T131927-cbc9f5-QA-Konrad-from-QA-Swarmhub | PASS | Exact owned session deleted and independently absent |
| QA-cleanup-session-QA-LIVE8-20261019T131927-cbc9f5-QA-Swarmhub-from-QA-Ermes | PASS | Exact owned session deleted and independently absent |
| QA-cleanup-session-QA-LIVE8-20261019T131927-cbc9f5-QA-Swarmhub-from-QA-Infra | PASS | Exact owned session deleted and independently absent |
| QA-cleanup-session-QA-LIVE8-20261019T131927-cbc9f5-QA-Swarmhub-from-QA-Jarvis | PASS | Exact owned session deleted and independently absent |
| QA-source-auth-config-unchanged | PASS | Source auth/config contents and metadata unchanged |
| QA-cleanup-local-processes | PASS | No isolated runtime processes remain |
| QA-cleanup-private-files | PASS | Temporary QA credentials/state removed after evidence export |
