# QA live transport results

QA-LIVE3-20261019T090236-30ca1f

App/Swift projections are source-derived, not runtime execution.

| Scenario | Status | Detail |
| --- | --- | --- |
| QA-P01-async-reply-routing | PASS | Unmodified bot-msg forwards one real worker result into the asking coordinator's reverse session |
| QA-P01-job-service | BLOCKED | No sb-codejob completion producer, commit/build tools or durable automatic next-job worker enabled; runner initiated the relay |
| QA-P02-automatic-fallback-webhook | BLOCKED | Recorded request delivered; webhook registration and unknown-origin wake router unavailable; no key generated or exposed |
| QA-P03-FYI-wakes-immediately | PASS | Gap reproduction: no-wait creates a real peer model turn immediately; it is not Grok held delivery |
| QA-P06-delayed-provisioning-reply | PASS | Actual action ask and reply, including native timeout/late route when rc=124; provisioning itself unavailable |
| QA-P04-no-artifact-in-fixture | PASS | Runner independently checked absent QA report; model has no file tool; not a product evidence gate |
| QA-P05-enforced-global-routing | BLOCKED | Broadcast delivered to all QA peers; runner performs fan-out, no global quota subscription or automatic model policy exercised |
| QA-P07-enforced-gates-cancel | BLOCKED | No approval-producing, outbound or code-job tool; final denial, changed-scope process kill/relaunch and cancellation propagation not executable |
| QA-P08-enforced-report-routing | BLOCKED | Policy replay only; no app notification driver, actual off-hours run or brokered human/coordinator delivery |
| QA-P09-reversible-action | PASS | Actual reversible todo receipt without a clarify question; no claim of enforced outbound permissions |
| QA-P10-unreachable-diagnostic | PASS | Real refused loopback connection; bot-msg fails truthfully before a model turn |
| QA-P10-autonomous-retry | BLOCKED | Later retry was initiated by the QA runner; bot-msg has no persistent scheduled retry |
| QA-P03-no-transport-reply-loop | PASS | Bounded observation after every late worker finished; no recursive follow-up, not proof of arbitrary model-loop prevention |
| QA-cleanup-run-run_0169fe72f632434d8d47163ac2f11468 | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_02183324ccac43b79d92bf275e2e5523 | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_278aefae8729495c8754ea2760bafaea | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_40da39273a654ccf97555aef9a663e87 | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_472deba6876643dd91b7ff0942068516 | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_4a299ac56a0f4f5a865e27102b05b000 | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_6aa7f43543fa4c2b94d54a3c3c2ed372 | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_7c762c554f904ef6a8acea7ff7c728dc | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_a46493653fe7467f94b913a66f6b089b | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_b23bcabbe09a4e1fab511d56c6aa49b0 | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_c0547bba5acc4940ad64c1cea7867200 | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_cf39282267034fc3a65859d1a06e1abe | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_d6a144bc92c14e93910e95e96d932a27 | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_d74e47b2f08748bdbd1b6d325503efb2 | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_eba9db6d9d864f509fd6e4ac8079e86a | PASS | Remote terminal status=completed |
| QA-cleanup-session-QA-LIVE3-20261019T090236-30ca1f-QA-Ermes-from-QA-Infra | PASS | Exact owned session deleted and independently absent |
| QA-cleanup-session-QA-LIVE3-20261019T090236-30ca1f-QA-Ermes-from-QA-Jarvis | PASS | Exact owned session deleted and independently absent |
| QA-cleanup-session-QA-LIVE3-20261019T090236-30ca1f-QA-Ermes-from-QA-Swarmhub | PASS | Exact owned session deleted and independently absent |
| QA-cleanup-session-QA-LIVE3-20261019T090236-30ca1f-QA-Infra-from-QA-Jarvis | PASS | Exact owned session deleted and independently absent |
| QA-cleanup-session-QA-LIVE3-20261019T090236-30ca1f-QA-Jarvis-from-QA-Swarmhub | PASS | Exact owned session deleted and independently absent |
| QA-cleanup-session-QA-LIVE3-20261019T090236-30ca1f-QA-Swarmhub-from-QA-Ermes | PASS | Exact owned session deleted and independently absent |
| QA-cleanup-session-QA-LIVE3-20261019T090236-30ca1f-QA-Swarmhub-from-QA-Infra | PASS | Exact owned session deleted and independently absent |
| QA-cleanup-session-QA-LIVE3-20261019T090236-30ca1f-QA-Swarmhub-from-QA-Jarvis | PASS | Exact owned session deleted and independently absent |
