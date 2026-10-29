# Macfix3 report

Applied a minimal Swift 6 isolation fix: the `AppStore.managedControl` function type now explicitly carries `@MainActor`, with a comment explaining why. No commit was made.

The brief names `d2387ae`, which is not available in this checkout. The starting HEAD is `f043274`; the fixes5 implementation is present in `bd5b98b`. The reported call at `AppStore+ManagedActions.swift:33` matches this checkout.

## Diff rationale

`AppStore` is main-actor isolated, but that isolation on the stored property does not make the property's async function type main-actor isolated. Previously, `managedRuntime` passed a mutable, non-Sendable `Bot` to a nonisolated async closure while the same bot remained accessible from the store. That is the actor-boundary transfer identified by the compiler diagnostic.

Changing the type to `(@MainActor (Bot, String, String, Data?) async throws -> ManagedRecord)?` keeps the injected implementation on the store's actor. Existing test closures receive the same contextual isolation, including the closure that mutates its captured runtime record. The bot does not need an unsafe Sendable conformance or a new identity lookup.

The only production source change is this closure annotation and its explanatory comment. Runtime fetching, fingerprint/gate/decider binding, receipt validation, pending-card persistence, retries and auditing remain unchanged. The real local subprocess still runs in `Task.detached`; it receives String/Data values and returns a Sendable `ManagedRecord`.

## Same-pattern audit

Reviewed the fixes5 Swift diff and searched source/tests for `managedControl`, `managedRuntime`, async closures taking `Bot`, and detached tasks:

- All three runtime calls (notification lookup, decision status lookup and decision submission) use the same corrected hook.
- All six injected test closures use that function type and inherit its main-actor isolation.
- Notification and decision tasks explicitly run on `@MainActor`; `managedRuntime` and `reconcileManagedDecision` inherit isolation from `AppStore`.
- `ManagedLocalControl.request` takes only Sendable value arguments; its detached worker creates its process and pipes internally.
- No additional instance of the same unsafe transfer was found in the fixes5 changes.

## Validation

- `git diff --check`: passed.
- Existing Python runtime-binding regressions: **2 passed**, using `PYTHONPATH=sim python3 -B -m unittest -v test_fixes5.RuntimeBindingTests.test_B3_decision_rejects_wrong_fingerprint_or_gate test_fixes5.RuntimeBindingTests.test_B3_structured_control_returns_immutable_operation_B`.
- No Swift toolchain is installed (`command -v swift` returned no path). Swift compilation and native tests could not be run; the Python results verify runtime binding only, not Swift isolation.

Remaining verification on the Mac: run `swift build` and `swift test` with the reported Swift 6 / Xcode macOS 27 SDK toolchain, including the managed-action binding and retry cases in `ManagedActionsTests.swift`.
