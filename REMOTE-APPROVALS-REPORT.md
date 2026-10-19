Implemented remote managed approvals on top of fixes5 in Swarm Hub, its bundled messaging skill and regression tests. Base: `fb605f3`, branch `swarmhub/peer-delivery`. No commit, Hermes modification, live deployment or real outbound action was performed. The two existing untracked brief files were left untouched.

The app now uses the bot's existing Hermes HTTPS connection and existing `hermes` / `hermes.<profile>` Keychain lookup for remote approvals. An app-owned service, launched with `swarmctl control serve`, runs on the remote runtime host. Its loopback listener is exposed through a dedicated route on the existing HTTPS reverse proxy. It reads the profile's existing `API_SERVER_KEY` from `.env` for each request, using the same source as bot-msg. No separate credential is generated, persisted, logged or passed on a command line.

The bundled `swarmhub-messages` skill is now **1.3.6**. Its operator setup section includes the command and nginx route. Installing the skill alone does not activate a server or change proxy configuration: the operator must supervise the service and configure that route. The implementation and tests do not modify Hermes.

| Boundary | Implementation |
|---|---|
| Transport authentication | HTTPS with normal certificate validation, existing profile Bearer key, and domain-separated HMAC-SHA256 over the exact request/response bytes. Redirects are refused. Plaintext remote URLs, URL credentials and unsupported URL paths are refused. |
| Exact operation | Every decision binds the fixes5 task ID and SHA-256 fingerprint, gate, deciding profile and exact boolean choice. The server recomputes the stored spec digest under the transaction lock; the app also compares the complete spec with the reviewed card. |
| Host/runtime binding | Signed requests name the operator-configured HTTPS origin. Cards persist the returned origin, durable runtime UUID and deciding profile. A changed origin, runtime, profile, digest or spec cannot approve the old card. Forwarded headers never establish identity. |
| Freshness/replay | Requests carry a random nonce and a maximum 60-second validity window. The server checks expiry again after acquiring the database lock. Signed responses bind the SHA-256 of the entire request and its expiry; an old response cannot satisfy a fresh query. Decision nonces cannot be reused for different content. |
| Idempotency/receipt | The action decision, nonce and durable receipt commit in one SQLite transaction. Concurrent/repeated matching decisions return the same receipt; a conflicting choice is refused. Denial also cancels the task tree in that transaction. The receipt confirms the decision, not successful execution of the underlying work. |
| Lost responses/restart | Cards persist the reviewed binding and original choice. Every retry queries first. A matching authenticated receipt removes the card and finalizes its audit. Errors, timeout, absent receipts and mismatches retain the card; the opposite choice is refused while the earlier decision is uncertain. Notifications cannot overwrite that card. |
| Fail closed | The client has a 15-second wall-clock deadline and rejects unsigned, malformed, expired, wrong-operation and wrong-origin responses. The server rejects invalid authentication, role changes, corrupt specs and expired requests. There is no fallback to a model turn or remote shell command. |

The service uses the existing private `~/.hermes/swarmhub/control.sqlite`, adding runtime identity, nonce and approval receipt tables. The submitting profile can read its own pending operation to route a notification; only the configured deciding profile can approve or deny. Local approvals continue through the fixes5 subprocess interface and share the transaction-level decision validation.

Supported remote addresses are an HTTPS origin, optionally followed by `/v1`. The public control endpoint is `/swarmhub/control/v1/<profile>`. The service accepts only a configured origin and binds `127.0.0.1:8653` by default. Keep the plaintext hop private and clocks synchronized. The existing shared Unix account remains the trust boundary: this does not isolate a hostile process that already has access to the profile key or runtime database. Do not clone the database into independently writable runtimes at the same origin; backup rollback is outside the replay guarantee. A newly initialized runtime gets a different UUID and cannot accept old cards.

Validation on this Linux host:

| Check | Result |
|---|---|
| `python3 -B -m unittest discover -s sim -p 'test_remote_approvals.py' -v` | **11 passed**. Real SQLite and shipped service logic; synthetic credentials, all outbound specs `fake: true`, worker wake mocked, no sockets or real sends. |
| `python3 -B -m unittest discover -s sim -p 'test_*.py' -v` | **227 test methods:** 201 successful, 22 failing/error methods, 4 skipped. unittest reports 25 failure assertions and 3 errors because some failures are subtests. All 11 new tests passed. |
| fixes5 `RuntimeBindingTests` | **5 passed**, including exact digest/gate rejection and real structured `swarmctl control get`. |
| Skill version regression tests | **2 passed**; packaging expectations include `swarm_remote.py` and version 1.3.6. |
| Full code-job shell tests under `/bin/sh` | **10 passed, 12 failed**, exit 1. |
| Full code-job shell tests under `/bin/dash` | **10 passed, 12 failed**, exit 1. |
| Python syntax and `git diff --check` | Passed. |
| Swift build/tests | **Not run:** this host cannot compile the macOS app. |

The broad failures involve the existing verifier: `Operation not permitted` / exit 77, unavailable user namespaces, limited-mode filesystem/signal restrictions, and a verifier subprocess timeout. Dependent coding jobs consequently report `unverified` / exit 66. The code-job shell suite copies only unchanged coding scripts; neither those scripts nor the shell test were modified. The verifier's working-tree SHA-256 matches HEAD: `6f4bc30352c5925cca40487780ade417e568e5b9ac0c2b941f8a882f6cc252fd`. These results are not a green full-suite claim.

For comparison, the full Python suite was also run against an isolated `git archive` of clean `fb605f3`: **216 methods, 190 successful, 22 failing/error methods, 4 skipped**, likewise 25 failure assertions and 3 errors. Twenty-one failing methods match. The remaining failure is a verifier timeout that shifted between `test_pytest_style_module_passes_under_the_sandbox` in the updated tree and `test_forced_fallback_runs_the_pytest_style_module_with_pool_timeout_and_self_signal` in the baseline. Both verifier paths are unchanged. The updated tree adds 11 successful remote approval tests.

Raw local logs: `/tmp/swarmhub-remote-python.log`, `/tmp/swarmhub-remote-code-job-sh.log`, `/tmp/swarmhub-remote-code-job-dash.log`. A clean HEAD comparison is recorded in `/tmp/swarmhub-remote-baseline-python.log`.

The Python regression tests cover authenticated reads/decisions; final denial and descendant cancellation; body/signature/key tampering and duplicate JSON keys; wrong host/runtime/profile/digest/gate/task; durable idempotent replay after restart and nonce reuse against another task; concurrent duplicate decisions; timeout after commit followed by query-only recovery; expired/future requests and expiry during lock acquisition; changed policy/corrupt spec; key rotation/missing key without key copies; and a shared Python/Swift HMAC fixture.

On the Mac, run `swift test --filter ManagedRemoteControlTests`, then the existing approval/persistence and packaging regressions (or the full `swift test` suite). The six new tests are:

- `pythonSignatureFixtureRejectsTamperReplayWrongHostAndExpiry`
- `authenticatedTransportUsesHermesProfileKey`
- `plaintextMissingKeyAndRedirectsFailClosed`
- `unreachableAndDeadlineFailClosed`
- `lostReceiptPersistsCardAndChoiceThenQueriesWithoutResending` (both Approve and Deny)
- `changedHostRuntimeOrDigestKeepsPendingCard` (also changed spec and missing receipt)

Existing Mac regressions to include: `realControlGetCardDecideAndReceiptBindTheRuntimeRecord`, `theAppApprovesARealRuntimeRecordThroughSwarmctlAndRemovesTheCardOnItsReceipt`, `aFenceDescribingActionAForTaskBDisplaysOnlyRuntimeBAndCannotApproveA`, `failedOrUnexecutedManagedDecisionsKeepRetryableCards`, `staleManagedRecordCannotBeApprovedAndPendingSurvivesPersistence`, `missingControlInterfaceNeverMakesAModelFenceAnApproval`, `messagesSkillShipsWithItsScript`, `renderedMessagesSkillSendsAsThisBot`, and `installsAtThePreviousSkillVersionsAreOutdated`.

After the Mac tests, verify the installed service through the configured TLS proxy using an isolated FAKE operation: approve/deny, interrupt the response after commit, restart the app, retry, and confirm receipt recovery without another decision. That deployment-level TLS/Keychain check remains unrun; the offline tests do not claim it.
