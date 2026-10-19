# QA live transport results

QA-LIVE1-20261019T083116-33aed6

App/Swift projections are source-derived, not runtime execution.

| Scenario | Status | Detail |
| --- | --- | --- |
| QA-auth-models-missing | PASS | Expected HTTP 401; observed 401 |
| QA-auth-models-wrong | PASS | Expected HTTP 401; observed 401 |
| QA-auth-capabilities-missing | PASS | Expected HTTP 401; observed 401 |
| QA-auth-capabilities-wrong | PASS | Expected HTTP 401; observed 401 |
| QA-auth-session-missing | PASS | Expected HTTP 401; observed 401 |
| QA-auth-session-wrong | PASS | Expected HTTP 401; observed 401 |
| QA-health-public | PASS | Expected HTTP 200; observed 200 |
| QA-health-detailed | PASS | Expected HTTP 200; observed 200 |
| QA-models-valid | PASS | Expected HTTP 200; observed 200 |
| QA-model-listed | PASS | Configured QA model is advertised |
| QA-capabilities | PASS | Expected HTTP 200; observed 200 |
| QA-native-selected | PASS | HermesBackend.transport() selects nativeSessions |
| QA-auth-chat-missing | PASS | Expected HTTP 401; observed 401 |
| QA-auth-create-missing | PASS | Expected HTTP 401; observed 401 |
| QA-auth-native-stream-missing | PASS | Expected HTTP 401; observed 401 |
| QA-auth-chat-wrong | PASS | Expected HTTP 401; observed 401 |
| QA-auth-create-wrong | PASS | Expected HTTP 401; observed 401 |
| QA-auth-native-stream-wrong | PASS | Expected HTTP 401; observed 401 |
| QA-missing-route | PASS | Expected HTTP 404; observed 404 |
| QA-wrong-method | PASS | Expected HTTP 405; observed 405 |
| QA-missing-session | PASS | Expected HTTP 404; observed 404 |
| QA-create-native | PASS | Expected HTTP 201; observed 201 |
| QA-identity-native | PASS | Session preserves exact QA ID and title |
| QA-duplicate-session | PASS | Expected HTTP 409; observed 409 |
| QA-legacy-malformed-broken-json | PASS | Expected HTTP 400; observed 400 |
| QA-native-malformed-broken-json | PASS | Expected HTTP 400; observed 400 |
| QA-legacy-malformed-empty-object | PASS | Expected HTTP 400; observed 400 |
| QA-native-malformed-empty-object | PASS | Expected HTTP 400; observed 400 |
| QA-legacy-malformed-empty-messages | PASS | Expected HTTP 400; observed 400 |
| QA-native-malformed-empty-messages | PASS | Expected HTTP 400; observed 400 |
| QA-legacy-malformed-invalid-message | FAIL | Expected HTTP 400; observed 500 |
| QA-native-malformed-invalid-message | PASS | Expected HTTP 400; observed 400 |
| QA-legacy-malformed-array | FAIL | Expected HTTP 400; observed 500 |
| QA-native-malformed-array | PASS | Expected HTTP 400; observed 400 |
| QA-legacy-malformed-null | FAIL | Expected HTTP 400; observed 500 |
| QA-native-malformed-null | PASS | Expected HTTP 400; observed 400 |
| QA-legacy-malformed-scalar | FAIL | Expected HTTP 400; observed 500 |
| QA-native-malformed-scalar | PASS | Expected HTTP 400; observed 400 |
| QA-native-invalid-input | PASS | Expected HTTP 400; observed 400 |
| QA-native-stream-framing | PASS | HTTP 200, SSE content type, complete blank-line frames, JSON data |
| QA-native-stream-error-terminal | PASS | Expected missing-provider failure followed by stream terminator |
| QA-native-stream-swift-failure-outcome | FAIL | Source-derived app outcome: completed; Swift runtime unavailable |
| QA-native-run-status | PASS | Expected HTTP 200; observed 200 |
| QA-native-history | PASS | Expected HTTP 200; observed 200 |
| QA-legacy-stream-framing | PASS | HTTP 200, SSE content type, complete blank-line frames, JSON data |
| QA-legacy-stream-error-terminal | PASS | Expected missing-provider failure followed by stream terminator |
| QA-legacy-stream-swift-failure-outcome | FAIL | Source-derived app outcome: completed; Swift runtime unavailable |
| QA-legacy-app-model-framing | PASS | HTTP 200, SSE content type, complete blank-line frames, JSON data |
| QA-legacy-app-model-error-terminal | PASS | Expected missing-provider failure followed by stream terminator |
| QA-legacy-app-model-swift-failure-outcome | FAIL | Source-derived app outcome: completed; Swift runtime unavailable |
| QA-legacy-nonstream-error | PASS | Expected HTTP 200; observed 200 |
| QA-legacy-nonstream-failure-flags | PASS | HTTP 200 is intentional soft failure: warning text plus finish_reason=error and hermes.failed=true |
| QA-create-native-abort-byte | PASS | Expected HTTP 201; observed 201 |
| QA-identity-native-abort-byte | PASS | Session preserves exact QA ID and title |
| QA-native-abort-byte | PASS | Client closed real response after byte; remote cancellation race requires status verification |
| QA-native-abort-byte-reconnect | PASS | Expected HTTP 200; observed 200 |
| QA-create-native-abort-frame | PASS | Expected HTTP 201; observed 201 |
| QA-identity-native-abort-frame | PASS | Session preserves exact QA ID and title |
| QA-native-abort-frame | PASS | Client closed real response after frame; remote cancellation race requires status verification |
| QA-native-abort-frame-reconnect | PASS | Expected HTTP 200; observed 200 |
| QA-native-abort-frame-status | PASS | Expected HTTP 200; observed 200 |
| QA-legacy-abort-byte | PASS | Client closed real response after byte; remote cancellation race requires status verification |
| QA-legacy-abort-byte-reconnect | PASS | Expected HTTP 200; observed 200 |
| QA-legacy-abort-frame | PASS | Client closed real response after frame; remote cancellation race requires status verification |
| QA-legacy-abort-frame-reconnect | PASS | Expected HTTP 200; observed 200 |
| QA-native-reconnect-chat-framing | PASS | HTTP 200, SSE content type, complete blank-line frames, JSON data |
| QA-native-reconnect-chat-error-terminal | PASS | Expected missing-provider failure followed by stream terminator |
| QA-native-reconnect-chat-swift-failure-outcome | FAIL | Source-derived app outcome: completed; Swift runtime unavailable |
| QA-legacy-reconnect-chat-framing | PASS | HTTP 200, SSE content type, complete blank-line frames, JSON data |
| QA-legacy-reconnect-chat-error-terminal | PASS | Expected missing-provider failure followed by stream terminator |
| QA-legacy-reconnect-chat-swift-failure-outcome | FAIL | Source-derived app outcome: completed; Swift runtime unavailable |
| QA-create-concurrent-0 | PASS | Expected HTTP 201; observed 201 |
| QA-identity-concurrent-0 | PASS | Session preserves exact QA ID and title |
| QA-create-concurrent-1 | PASS | Expected HTTP 201; observed 201 |
| QA-identity-concurrent-1 | PASS | Session preserves exact QA ID and title |
| QA-create-concurrent-2 | PASS | Expected HTTP 201; observed 201 |
| QA-identity-concurrent-2 | PASS | Session preserves exact QA ID and title |
| QA-create-concurrent-3 | PASS | Expected HTTP 201; observed 201 |
| QA-identity-concurrent-3 | PASS | Session preserves exact QA ID and title |
| QA-concurrent-0-framing | PASS | HTTP 200, SSE content type, complete blank-line frames, JSON data |
| QA-concurrent-0-error-terminal | PASS | Expected missing-provider failure followed by stream terminator |
| QA-concurrent-0-swift-failure-outcome | FAIL | Source-derived app outcome: completed; Swift runtime unavailable |
| QA-concurrent-1-framing | PASS | HTTP 200, SSE content type, complete blank-line frames, JSON data |
| QA-concurrent-1-error-terminal | PASS | Expected missing-provider failure followed by stream terminator |
| QA-concurrent-1-swift-failure-outcome | FAIL | Source-derived app outcome: completed; Swift runtime unavailable |
| QA-concurrent-2-framing | PASS | HTTP 200, SSE content type, complete blank-line frames, JSON data |
| QA-concurrent-2-error-terminal | PASS | Expected missing-provider failure followed by stream terminator |
| QA-concurrent-2-swift-failure-outcome | FAIL | Source-derived app outcome: completed; Swift runtime unavailable |
| QA-concurrent-3-framing | PASS | HTTP 200, SSE content type, complete blank-line frames, JSON data |
| QA-concurrent-3-error-terminal | PASS | Expected missing-provider failure followed by stream terminator |
| QA-concurrent-3-swift-failure-outcome | FAIL | Source-derived app outcome: completed; Swift runtime unavailable |
| QA-create-shared-concurrent | PASS | Expected HTTP 201; observed 201 |
| QA-identity-shared-concurrent | PASS | Session preserves exact QA ID and title |
| QA-shared-concurrent-0-http | PASS | Same-session parallel requests return a stream or explicit admission rejection |
| QA-shared-concurrent-0-framing | PASS | HTTP 200, SSE content type, complete blank-line frames, JSON data |
| QA-shared-concurrent-0-error-terminal | PASS | Expected missing-provider failure followed by stream terminator |
| QA-shared-concurrent-0-swift-failure-outcome | FAIL | Source-derived app outcome: completed; Swift runtime unavailable |
| QA-shared-concurrent-1-http | PASS | Same-session parallel requests return a stream or explicit admission rejection |
| QA-shared-concurrent-1-framing | PASS | HTTP 200, SSE content type, complete blank-line frames, JSON data |
| QA-shared-concurrent-1-error-terminal | PASS | Expected missing-provider failure followed by stream terminator |
| QA-shared-concurrent-1-swift-failure-outcome | FAIL | Source-derived app outcome: completed; Swift runtime unavailable |
| QA-stream-http-error-detail | FAIL | Source review: validate(response) discards real error.message on SSE open; server message=Missing or invalid 'messages' field |
| QA-partial-upload-client-timeout | PASS | Real incomplete HTTP upload; client timed out at 0.2s and closed socket. Does not test Swift stream idle/open deadlines. |
| QA-after-timeout-reconnect | PASS | Expected HTTP 200; observed 200 |
| QA-provider-token-stream | BLOCKED | No provider key: successful tokens, tool lifecycle, long generation and provider fault timing unavailable. |
| QA-server-idle-timeout-keepalive | BLOCKED | Missing provider finishes immediately; cannot exercise real 30s keepalives or Swift 90s idle timeout. |
| QA-swift-runtime | BLOCKED | Linux box has no Swift toolchain/macOS UI. Compatibility conclusions use raw live traces plus source review. |
| QA-app-qa-catalog | BLOCKED | Native DEBUG app and attested QA gateway absent. This direct transport pass does not run/claim the 65 app scenarios. |
| QA-provider-429-503 | BLOCKED | No provider credentials/fault control; observed genuine 500/502 only where server returns them. No fabricated 429/503. |
| QA-mid-token-abort | BLOCKED | First-byte/frame aborts exercised; an abort during meaningful generated content needs provider output. |
| QA-swift-captured-truncation | BLOCKED | No Swift execution. Captured prefix has no terminal and source would throw StreamBreak; runtime verification deferred. |
| QA-cleanup-run-run_2d6a25256ab74095920134bd1470417c | PASS | Remote run terminal status=failed |
| QA-cleanup-run-run_34015647dea34edaba794cd12750cdb7 | PASS | Remote run terminal status=failed |
| QA-cleanup-run-run_5a120e9bba514258b108bfc3846bb338 | PASS | Remote run terminal status=failed |
| QA-cleanup-run-run_933af3d93ab742e28cdb3abab21d9f93 | PASS | Remote run terminal status=failed |
| QA-cleanup-run-run_b54b12ff024748b6b4605658a9f52fc5 | PASS | Remote run terminal status=failed |
| QA-cleanup-run-run_cdc94ce5fa5a46cea754c40d90dc0d5c | PASS | Remote run terminal status=failed |
| QA-cleanup-run-run_cf9eee7a136644cea3930c6de2541411 | PASS | Remote run terminal status=failed |
| QA-cleanup-run-run_d9885f641cc64ca7a582e446489886ab | PASS | Remote run terminal status=failed |
| QA-cleanup-run-run_fc5f8ca7238c4cd8adb927a4610765c7 | PASS | Remote run terminal status=failed |
| QA-cleanup-QA-LIVE1-20261019T083116-33aed6-concurrent-0 | PASS | Owned QA session deletion or already absent |
| QA-cleanup-verify-QA-LIVE1-20261019T083116-33aed6-concurrent-0 | PASS | Exact owned session no longer readable |
| QA-cleanup-QA-LIVE1-20261019T083116-33aed6-concurrent-1 | PASS | Owned QA session deletion or already absent |
| QA-cleanup-verify-QA-LIVE1-20261019T083116-33aed6-concurrent-1 | PASS | Exact owned session no longer readable |
| QA-cleanup-QA-LIVE1-20261019T083116-33aed6-concurrent-2 | PASS | Owned QA session deletion or already absent |
| QA-cleanup-verify-QA-LIVE1-20261019T083116-33aed6-concurrent-2 | PASS | Exact owned session no longer readable |
| QA-cleanup-QA-LIVE1-20261019T083116-33aed6-concurrent-3 | PASS | Owned QA session deletion or already absent |
| QA-cleanup-verify-QA-LIVE1-20261019T083116-33aed6-concurrent-3 | PASS | Exact owned session no longer readable |
| QA-cleanup-QA-LIVE1-20261019T083116-33aed6-legacy-abort-byte | PASS | Owned QA session deletion or already absent |
| QA-cleanup-verify-QA-LIVE1-20261019T083116-33aed6-legacy-abort-byte | PASS | Exact owned session no longer readable |
| QA-cleanup-QA-LIVE1-20261019T083116-33aed6-legacy-abort-frame | PASS | Owned QA session deletion or already absent |
| QA-cleanup-verify-QA-LIVE1-20261019T083116-33aed6-legacy-abort-frame | PASS | Exact owned session no longer readable |
| QA-cleanup-QA-LIVE1-20261019T083116-33aed6-legacy-app-model | PASS | Owned QA session deletion or already absent |
| QA-cleanup-verify-QA-LIVE1-20261019T083116-33aed6-legacy-app-model | PASS | Exact owned session no longer readable |
| QA-cleanup-QA-LIVE1-20261019T083116-33aed6-legacy-reconnect-chat | PASS | Owned QA session deletion or already absent |
| QA-cleanup-verify-QA-LIVE1-20261019T083116-33aed6-legacy-reconnect-chat | PASS | Exact owned session no longer readable |
| QA-cleanup-QA-LIVE1-20261019T083116-33aed6-legacy-stream | PASS | Owned QA session deletion or already absent |
| QA-cleanup-verify-QA-LIVE1-20261019T083116-33aed6-legacy-stream | PASS | Exact owned session no longer readable |
| QA-cleanup-QA-LIVE1-20261019T083116-33aed6-native | PASS | Owned QA session deletion or already absent |
| QA-cleanup-verify-QA-LIVE1-20261019T083116-33aed6-native | PASS | Exact owned session no longer readable |
| QA-cleanup-QA-LIVE1-20261019T083116-33aed6-native-abort-byte | PASS | Owned QA session deletion or already absent |
| QA-cleanup-verify-QA-LIVE1-20261019T083116-33aed6-native-abort-byte | PASS | Exact owned session no longer readable |
| QA-cleanup-QA-LIVE1-20261019T083116-33aed6-native-abort-frame | PASS | Owned QA session deletion or already absent |
| QA-cleanup-verify-QA-LIVE1-20261019T083116-33aed6-native-abort-frame | PASS | Exact owned session no longer readable |
| QA-cleanup-QA-LIVE1-20261019T083116-33aed6-nonstream | PASS | Owned QA session deletion or already absent |
| QA-cleanup-verify-QA-LIVE1-20261019T083116-33aed6-nonstream | PASS | Exact owned session no longer readable |
| QA-cleanup-QA-LIVE1-20261019T083116-33aed6-shared-concurrent | PASS | Owned QA session deletion or already absent |
| QA-cleanup-verify-QA-LIVE1-20261019T083116-33aed6-shared-concurrent | PASS | Exact owned session no longer readable |
| QA-final-quiescence | PASS | Remote health: active_agents=0, active_runs=0 |
