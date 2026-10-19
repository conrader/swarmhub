# QA live transport results

QA-LIVE9-20261019T140108-a8c9ce

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
| QA-P01-Jarvis-relay | PASS | {"receiving_turn": "QA-bridge-002", "action": {"op": "relay", "job": "job.f56bd0e729ee4805866ff473c3bd0450", "instruction": "Completion reports worker exit 0, a fresh report, and verification command exit 0. HEAD is unchanged; report and implementation correctness remain unverified. Check whether this job has already been handled before repeating any action. Review the durable record, report, verification output, and actual diff; fix any issues and verify correctness. Commit the reviewed changes, rebuild and verify the resulting build, then select the next work under current policy. Report actual review findings, commit ID, build results, and selected next work; do not claim success without evidence."}} |
| QA-P01-first-output-and-build-compile-test | PASS | entrypoint exit=0 |
| QA-P01-first-output-and-build | PASS | {"job": "task.f56bd0e729ee4805866ff473c3bd0450", "report_sha256": "b478a45643a31e2303731f58323d7e806c669e701520baac73debbe05db1a394", "fields": {"status": "ok", "exit": "0", "cli-exit": "0", "model": "gpt-6-astra", "effort": "high", "report": "/tmp/QA-LIVE9-et3x3wqq/QA-repo/QA-P01-first.txt", "report-valid": "true", "report-sha256": "b478a45643a31e2303731f58323d7e806c669e701520baac73debbe05db1a394", "head-before": "30a382d2d4ea07839a942d04525eab0244981415", "head-after": "30a382d2d4ea07839a942d04525eab0244981415", "commit-evidence": "false", "verify-exit": "0", "tests-passed": "true"}, "verification": {"time_ns": 1792418519331324137, "source_sha256": "ba1a531f581d2e6094e978ed6f7aca7a8d92eeb62c6e7ad73ee692f7f18bc772", "compiled": true, "tests_run": 2, "passed": true}, "proof_sha256": "b122e38c841476e5cd2cf1462d5bda0b228b1c37514955dfaee84e9bca4f3e58"} |
| QA-P01-review-diff | PASS | entrypoint exit=0 |
| QA-P01-ordering-review | PASS | entrypoint exit=0 |
| QA-P01-ordering-reviewed | PASS | {"receiving_turn": "QA-bridge-004", "action": {"op": "review_commit_rebuild", "job": "task.f56bd0e729ee4805866ff473c3bd0450", "report_sha256": "b478a45643a31e2303731f58323d7e806c669e701520baac73debbe05db1a394", "head": "30a382d2d4ea07839a942d04525eab0244981415", "review": "The supplied source diff corrects add(a, b) from subtraction to addition, matching the stated task, with no other function changes shown. Independent verification records successful compilation and two passing tests with verification exit 0; test inputs are not provided, so broader coverage cannot be assessed. The report claims a NOTES.md append and no changes to protected files, but those claims are not independently established by the supplied source-only diff. Completion evidence shows HEAD unchanged and commit-evidence false, so no commit or post-commit build success is claimed. No prior review-action receipt is supplied; check the durable action record for duplicate handling before committing. Commit the reviewed changes and review only if the bindings and pending state match, and return the actual commit and rebuild/test receipt. Next-work selection remains pending that receipt."}} |
| QA-P01-reviewed-head | PASS | entrypoint exit=0 |
| QA-P01-ordering-stage | PASS | entrypoint exit=0 |
| QA-P01-ordering-commit | PASS | entrypoint exit=0 |
| QA-P01-ordering-new-head | PASS | entrypoint exit=0 |
| QA-P01-ordering-committed-diff | PASS | entrypoint exit=0 |
| QA-P01-ordering-rebuild-test | PASS | entrypoint exit=0 |
| QA-P01-ordering-commit-rebuilt | PASS | {"head_before": "30a382d2d4ea07839a942d04525eab0244981415", "head_after": "0b0bd07098979b14efda73bf5290acad928f8eeb", "verification": {"time_ns": 1792418530211644469, "source_sha256": "ba1a531f581d2e6094e978ed6f7aca7a8d92eeb62c6e7ad73ee692f7f18bc772", "compiled": true, "tests_run": 2, "passed": true}} |
| QA-P01-ordering-pick-next | PASS | entrypoint exit=0 |
| QA-P01-ordering-selected-next | PASS | {"receiving_turn": "QA-bridge-006", "action": {"op": "launch_next", "head": "0b0bd07098979b14efda73bf5290acad928f8eeb", "build_sha256": "b712534e979e0317a611041be493c78117db185e011cfbb8188d7f529fab1d42", "next": "multiply"}} |
| QA-P01-bot-selected-next-submit | PASS | entrypoint exit=0 |
| QA-P01-next-submitted-unasked | PASS | {"job": "task.6eca136d862446a6889228b4a67efe09", "selected_by": "P01-ordering-selected-next", "preloaded_queue": false} |
| QA-P01-next-verified-compile-test | PASS | entrypoint exit=0 |
| QA-P01-next-verified | PASS | {"job": "task.6eca136d862446a6889228b4a67efe09", "report_sha256": "00ff6816fece95c2a737b496cc7329dc9fa9ac157b148a938bcd9db12a732812", "fields": {"status": "ok", "exit": "0", "cli-exit": "0", "model": "gpt-6-astra", "effort": "high", "report": "/tmp/QA-LIVE9-et3x3wqq/QA-repo/QA-P01-next-multiply.txt", "report-valid": "true", "report-sha256": "00ff6816fece95c2a737b496cc7329dc9fa9ac157b148a938bcd9db12a732812", "head-before": "0b0bd07098979b14efda73bf5290acad928f8eeb", "head-after": "02fdca30df00a9714d51ed3d029ca07dbeba0dd0", "commit-evidence": "true", "verify-exit": "0", "tests-passed": "true"}, "verification": {"time_ns": 1792418600382295960, "source_sha256": "e7f018d15cf4f7906638bfd1b52b2d18263b491ffd555320de3eb0b9cc970c3a", "compiled": true, "tests_run": 2, "passed": true}, "proof_sha256": "d2f8c12d48883d254c1a5dbff9c92fe8e0b284cb62ad629f39e948543b7d73a9"} |
| QA-P01-next-launched-unasked | PASS | {"job": "task.6eca136d862446a6889228b4a67efe09", "cli_exit": "0", "selected_by": "P01-ordering-selected-next", "preloaded_queue": false} |
| QA-QA-P01-full-chain | PASS | entrypoint exit=0 |
| QA-P04-submit-real-empty | PASS | entrypoint exit=0 |
| QA-P04-real-empty-rejected | PASS | {"job": "task.5bd49699c669491c8230dfcc3818fe88", "fields": {"status": "failed", "exit": "65", "cli-exit": "0", "model": "gpt-6-astra", "effort": "high", "report": "/tmp/QA-LIVE9-et3x3wqq/QA-repo/QA-P04-empty.txt", "report-valid": "false", "report-sha256": "missing-or-empty", "head-before": "02fdca30df00a9714d51ed3d029ca07dbeba0dd0", "head-after": "-", "commit-evidence": "not-checked", "verify-exit": "-", "tests-passed": "not-run"}} |
| QA-P04-Jarvis-corrected | PASS | {"receiving_turn": "QA-bridge-010", "action": {"op": "correct", "job": "job.5bd49699c669491c8230dfcc3818fe88", "model": "gpt-6-astra", "effort": "high", "instruction": "Relaunch the failed job to correct its output contract. The receipt reports exit 65, no report, and no verification run; nothing is verified. Produce a fresh, nonempty report at /tmp/QA-LIVE9-et3x3wqq/QA-repo/QA-P04-empty.txt. Independently check report freshness and contents against the actual work, review the implementation and commit state, and run /usr/bin/python3 /tmp/QA-LIVE9-et3x3wqq/QA-repo/QA-verify.py /tmp/QA-LIVE9-et3x3wqq/QA-repo add /tmp/QA-LIVE9-et3x3wqq/QA-repo/QA-P04-empty-verify.json. Inspect fresh verification output and actual test results before declaring success; report any remaining failures or blockers honestly. Do not repeat a correction already recorded for this job."}} |
| QA-P04-deliver-actionable-correction | PASS | entrypoint exit=0 |
| QA-P04-receiver-requested-relaunch | PASS | {"receiving_turn": "QA-bridge-012", "action": {"op": "relaunch", "failed_job": "task.5bd49699c669491c8230dfcc3818fe88", "model": "gpt-6-astra", "effort": "high"}} |
| QA-P04-explicit-high-relaunch | PASS | entrypoint exit=0 |
| QA-P04-success-report-held-for-check | PASS | {"receiving_turn": "QA-bridge-014", "action": {"op": "await_independent_check", "job": "job.476a47689cba4ce7acd2b976f6947e6d"}} |
| QA-P04-fresh-output-independently-verified-compile-test | PASS | entrypoint exit=0 |
| QA-P04-fresh-output-independently-verified | PASS | {"job": "task.476a47689cba4ce7acd2b976f6947e6d", "report_sha256": "022d4043ed7487c9892578c18f9ffa8a3d1b8128188fa784a1c48bf2b4d8dbc5", "fields": {"status": "ok", "exit": "0", "cli-exit": "0", "model": "gpt-6-astra", "effort": "high", "report": "/tmp/QA-LIVE9-et3x3wqq/QA-repo/QA-P04-corrected.txt", "report-valid": "true", "report-sha256": "022d4043ed7487c9892578c18f9ffa8a3d1b8128188fa784a1c48bf2b4d8dbc5", "head-before": "02fdca30df00a9714d51ed3d029ca07dbeba0dd0", "head-after": "39588fea9604bb3ed5fd0fd908c912c14246957b", "commit-evidence": "true", "verify-exit": "0", "tests-passed": "true"}, "verification": {"time_ns": 1792418685192764859, "source_sha256": "e7f018d15cf4f7906638bfd1b52b2d18263b491ffd555320de3eb0b9cc970c3a", "compiled": true, "tests_run": 2, "passed": true}, "proof_sha256": "5f54af9ae2b184f2275204cbd8ef1381e529c88d92b78a613977b36684695e9f"} |
| QA-P04-verified-result-for-report | PASS | entrypoint exit=0 |
| QA-P04-success-after-independent-check | PASS | {"receiving_turn": "QA-bridge-016", "action": {"op": "report_success", "job": "task.476a47689cba4ce7acd2b976f6947e6d", "proof_sha256": "5f54af9ae2b184f2275204cbd8ef1381e529c88d92b78a613977b36684695e9f", "summary": "Independent receipt confirms a fresh valid report at /tmp/QA-LIVE9-et3x3wqq/QA-repo/QA-P04-corrected.txt, worker and CLI exit 0, and commit evidence with HEAD 39588fea9604bb3ed5fd0fd908c912c14246957b. Source compilation succeeded; both tests passed and verification exited 0. This requests success reporting; bridge acceptance is not yet confirmed."}} |
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
| QA-P02-webhook-http-rotated | PASS | HTTP 202; {"delivery": "delivery.485abd45f1d642528fd76f8a4a480906", "profile": "QA-Infra", "routine": "QA-wake", "status": "pending"}
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
| QA-source-auth-config-unchanged | PASS | Source auth/config contents and metadata unchanged |
| QA-cleanup-run-run_0b1e95fbffb14626a471f24fc505cfd2 | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_0e00dde04b014edd85ec04a57ee50af6 | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_12486fc70e0d48d39df77dab2d7a7265 | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_1f390a1a0dc54a92a0f18b3cc61e4d07 | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_374b61814c454dd09025127341bde4fc | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_43625a220e2848dc8e5e1f4419699144 | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_54f8ea1dbee84e7d9cae86b4694af719 | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_6403bedd974542ef99329390e4c7f4b6 | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_6de91b5ce4b54a3da90bf714460851bb | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_6e9dba84125a4413aaad04fe4d8f3276 | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_7122abc145c54ae58dac330f438bf449 | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_7498f071db194daa98840581f1bab59a | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_76545be6175f42c89ad70f4c3d9456bd | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_772895d10fc84fdd9e8c162e94a959d7 | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_8996229dc36d490e8b8d88b7d2c2089e | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_8c07d003e77242248ff629523e2e7ca8 | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_8cff23ea1d1c42edb37a5bea3e66fa75 | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_be40dec306114925bcbf1c487e30a125 | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_c4e7ca6e2ea848a59a94139fc79f3f54 | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_ccad5926679f4310bd1face22062826f | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_ec81f408bcc44fbeb0cf38e9f84fb189 | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_f41fbd714d6e4ba7aa5be9757cacc49c | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_f74aa6878b1c4103b8c03bf5d60843a1 | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_fce205d31c9746e19bff8d4d93bce18b | PASS | Remote terminal status=completed |
| QA-cleanup-session-QA-LIVE9-20261019T140108-a8c9ce-QA-Ermes-from-QA-Infra | PASS | Exact owned session deleted and independently absent |
| QA-cleanup-session-QA-LIVE9-20261019T140108-a8c9ce-QA-Ermes-from-QA-Jarvis | PASS | Exact owned session deleted and independently absent |
| QA-cleanup-session-QA-LIVE9-20261019T140108-a8c9ce-QA-Ermes-from-QA-Swarmhub | PASS | Exact owned session deleted and independently absent |
| QA-cleanup-session-QA-LIVE9-20261019T140108-a8c9ce-QA-Infra-from-QA-Infra | PASS | Exact owned session deleted and independently absent |
| QA-cleanup-session-QA-LIVE9-20261019T140108-a8c9ce-QA-Infra-from-QA-Jarvis | PASS | Exact owned session deleted and independently absent |
| QA-cleanup-session-QA-LIVE9-20261019T140108-a8c9ce-QA-Jarvis-from-QA-Swarmhub | PASS | Exact owned session deleted and independently absent |
| QA-cleanup-session-QA-LIVE9-20261019T140108-a8c9ce-QA-Konrad-from-QA-Swarmhub | PASS | Exact owned session deleted and independently absent |
| QA-cleanup-session-QA-LIVE9-20261019T140108-a8c9ce-QA-Swarmhub-from-QA-Ermes | PASS | Exact owned session deleted and independently absent |
| QA-cleanup-session-QA-LIVE9-20261019T140108-a8c9ce-QA-Swarmhub-from-QA-Infra | PASS | Exact owned session deleted and independently absent |
| QA-cleanup-session-QA-LIVE9-20261019T140108-a8c9ce-QA-Swarmhub-from-QA-Jarvis | PASS | Exact owned session deleted and independently absent |
| QA-cleanup-local-processes | PASS | No isolated runtime processes remain |
| QA-cleanup-private-files | PASS | Temporary QA credentials/state removed |
