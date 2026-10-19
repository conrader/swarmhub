# QA live transport results

QA-LIVE2-20261019T085018-fc2eae

App/Swift projections are source-derived, not runtime execution.

| Scenario | Status | Detail |
| --- | --- | --- |
| QA-initial-idle | PASS | Health before model calls |
| QA-create-B01-native | PASS | Exactly registered QA session |
| QA-B01-native | PASS | Generated native answer and Unicode survive SSE; UI untested |
| QA-create-B01-legacy | PASS | Exactly registered QA session |
| QA-B01-legacy | FAIL | Legacy successful model stream |
| QA-create-B02-tool-order | PASS | Exactly registered QA session |
| QA-B02-tool-order | PASS | Real todo tool lifecycle before final answer; no wait tool installed |
| QA-create-B03-stop | PASS | Exactly registered QA session |
| QA-B03-stop | PASS | Stop during actual text delta; independently polled terminal status=cancelled |
| QA-A03-failure-precedence-wire | PASS | Cancellation must beat assistant.completed and done; Swift execution blocked |
| QA-create-B04-steer | PASS | Exactly registered QA session |
| QA-B04-steer | PASS | Tool-time steer acceptance and final correction |
| QA-A12-late-control | PASS | Terminal run refuses late steer; peer held/priority delivery requires bot-msg |
| QA-create-B07-reconnect | PASS | Exactly registered QA session |
| QA-B07-reconnect | FAIL | Socket closed after generated delta; new client reads terminal status/history with no replay |
| QA-A02-explicit-continuation | PASS | One explicit new turn after reconciliation; app restart/ticker not executed |
| QA-create-A01-done-claim | PASS | Exactly registered QA session |
| QA-A01-done-claim-capture | PASS | Real generated unverified done fixture captured; acceptance gate requires app/source assessment |
| QA-create-A04-backlog | PASS | Exactly registered QA session |
| QA-A04-backlog-representation | PASS | Real task list and blocker response; no autonomous queue/scheduler claim certified |
| QA-create-A09-clarify | PASS | Exactly registered QA session |
| QA-A09-clarify-tool-invoked | PASS | Real clarify invocation; inspect receipt for actual interactive support |
| QA-A09-late-answer | PASS | Resolved generation refuses duplicate/late response |
| QA-create-A15-timeout | PASS | Exactly registered QA session |
| QA-A15-client-timeout | PASS | Real 50 ms socket deadline, separate client polls late terminal result; 90s Swift idle timer untested |
| QA-create-B09-same | PASS | Exactly registered QA session |
| QA-create-B09-distinct-0 | PASS | Exactly registered QA session |
| QA-create-B09-distinct-1 | PASS | Exactly registered QA session |
| QA-B09-concurrency | PASS | Four parallel requests: two same session, two independent; app 6/4 slot policy untested |
| QA-create-F09-persona | PASS | Exactly registered QA session |
| QA-F09-session-persona | FAIL | Stored session system prompt behavior |
| QA-F09-rename | PASS | Expected HTTP 200; observed 200 |
| QA-F09-persona-edit-refusal | PASS | Expected HTTP 400; observed 400 |
| QA-F11-model-lock | PASS | Expected HTTP 200; observed 200 |
| QA-F11-locked-execution | PASS | Inspect runtime for actual configured model after explicit session lock |
| QA-cleanup-run-run_02eb3f31a02443f28d3b1dca877fd1af | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_10b439cf3f37454085aedf824a507033 | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_16770845143245a5b247405328522e25 | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_19dfe9e8c1b044a0a05fb0497500781a | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_1b45f806a5074a01acdb2fd12c9b73df | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_45c4d07fa0f345238e9cdd9e9fae5b6b | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_54d7b7df86344523a2a2145b7aaecd74 | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_659aa86fff9041b58ac6d85c15d5ef75 | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_6c496668c1e44012a413458314b42c6d | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_7ab7d1708e8b4388a98e7167775c73d2 | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_80db2d558fc14632b864016397a902a8 | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_8285d28602a54755aa987118d6f1b4c2 | PASS | Remote terminal status=cancelled |
| QA-cleanup-run-run_b8b95cf680974a76ba889d73bc6739bb | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_ce3ef1c4143b46a7bb90f5b1b749f5a3 | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_ee7942603f5341d1b50ec07e95e6a89d | PASS | Remote terminal status=completed |
| QA-cleanup-run-run_fc58c0c48b4440e983f559b8688d1064 | PASS | Remote terminal status=completed |
| QA-cleanup-session-QA-LIVE2-20261019T085018-fc2eae-A01-done-claim | PASS | Exact owned session deleted and independently absent |
| QA-cleanup-session-QA-LIVE2-20261019T085018-fc2eae-A04-backlog | PASS | Exact owned session deleted and independently absent |
| QA-cleanup-session-QA-LIVE2-20261019T085018-fc2eae-A09-clarify | PASS | Exact owned session deleted and independently absent |
| QA-cleanup-session-QA-LIVE2-20261019T085018-fc2eae-A15-timeout | PASS | Exact owned session deleted and independently absent |
| QA-cleanup-session-QA-LIVE2-20261019T085018-fc2eae-B01-legacy | PASS | Exact owned session deleted and independently absent |
| QA-cleanup-session-QA-LIVE2-20261019T085018-fc2eae-B01-native | PASS | Exact owned session deleted and independently absent |
| QA-cleanup-session-QA-LIVE2-20261019T085018-fc2eae-B02-tool-order | PASS | Exact owned session deleted and independently absent |
| QA-cleanup-session-QA-LIVE2-20261019T085018-fc2eae-B03-stop | PASS | Exact owned session deleted and independently absent |
| QA-cleanup-session-QA-LIVE2-20261019T085018-fc2eae-B04-steer | PASS | Exact owned session deleted and independently absent |
| QA-cleanup-session-QA-LIVE2-20261019T085018-fc2eae-B07-reconnect | PASS | Exact owned session deleted and independently absent |
| QA-cleanup-session-QA-LIVE2-20261019T085018-fc2eae-B09-distinct-0 | PASS | Exact owned session deleted and independently absent |
| QA-cleanup-session-QA-LIVE2-20261019T085018-fc2eae-B09-distinct-1 | PASS | Exact owned session deleted and independently absent |
| QA-cleanup-session-QA-LIVE2-20261019T085018-fc2eae-B09-same | PASS | Exact owned session deleted and independently absent |
| QA-cleanup-session-QA-LIVE2-20261019T085018-fc2eae-F09-persona | PASS | Exact owned session deleted and independently absent |
