# Fixes10 — managed remote approval redirect refusal

Base: `5de25fd` on `swarmhub/peer-delivery`. Changes are uncommitted.

## Diagnosis and change

The reported Mac failure is in `ManagedRemoteControlTests.plaintextMissingKeyAndRedirectsFailClosed`.
The plaintext URL and missing-key guards already execute before session creation or dispatch.
The redirect branch only called `completionHandler(nil)`: it refused the destination but did not
terminate the original transfer. The existing `MockHermesProtocol` redirect fixture emits a redirect
and no subsequent body/completion, leaving the request to hit its 15-second deadline. This explains
the observed `NSURLErrorDomain -1001` instead of `ManagedControlError`.

`Sources/AgentApp/Models/ManagedRemoteControl.swift` now keeps a per-request redirect delegate with
a lock-protected rejection flag. The redirect callback records rejection, cancels that task, and
completes with `nil`. Both successful completion and transport-error paths check the flag and throw
`ManagedControlError.rejected`. Cancellation therefore ends the original transfer without waiting
for a response body, and cannot disguise the redirect as a transport failure. The delegate remains
attached to the individual task, including when the caller injects a session.

The existing HTTPS/key guards remain in place: invalid `get` requests throw `.unavailable`, while
preflight failures for `decide` remain `.unsent`. Redirects after dispatch remain `.rejected`, including
for `decide`, so an uncertain decision is not falsely marked safe to resend. Real connectivity errors
and deadlines retain their transport errors. Response status, origin, size, signature, expiry and
operation-binding checks are unchanged.

No Hermes code, shared URLProtocol fixture, Python simulator, bundled runtime, or dependency was
changed. No live service was contacted for testing.

## Regression coverage

`Tests/AgentAppTests/ManagedRemoteControlTests.swift` retains the original test's error-type and
request-count assertions and adds exact error-case checks, zero dispatch after each preflight
failure, and a two-second upper bound per refusal (with the original 15-second request timeout).

The added parameterized test covers 301, 302, 303, 307 and 308, each with same-origin, cross-origin
HTTPS and HTTP downgrade destinations, for both `get` and `decide` (30 cases). It requires `.rejected`
within two seconds against a five-second deadline, no target requests, and exactly one source request
per operation. The original response body deliberately never finishes. All requests use the existing
in-process URLProtocol stub, which intercepts every URL, including any erroneously followed target.

The decision preflight test now checks both plaintext and missing-key rejection as `.unsent`, with
zero dispatch and the same timing bound. Existing authenticated success, unreachable/deadline,
signature, retirement, and lost-receipt recovery tests remain intact.

## OVH validation

| Check | Result |
| --- | --- |
| `python3 -B -m unittest discover -s sim -p 'test_remote_approvals.py' -v` | 11/11 passed, 0.643 s |
| `python3 -B -m unittest discover -s sim -v` — edited tree | 255 tests, 25 failure assertions, 2 errors, 6 skips; 102.421 s |
| Same full command — clean `5de25fd` extracted with `git archive HEAD` | 255 tests, 25 failure assertions, 2 errors, 6 skips; 102.923 s |
| Failure comparison | All 27 failure/error entries identical; same 21 failing/error methods; no new failures |
| `git diff --check` | Passed |
| Diff of `sim`, `Resources`, `Sources/AgentApp/Backends`, and shared `TestSupport.swift` against HEAD | Empty |

The full suite is **not green** on this restricted host. Both runs have 228 successful methods,
21 failing/error methods and 6 skips; subtest assertions explain the larger failure count. The existing
failures include namespace/verifier restrictions and resulting coding-job/evidence failures, as in
the fixes9 report. The loopback receiver test skips because the sandbox forbids sockets; its in-process
HTTP-handler test passes. No live harness was run and no test failure was converted into a pass.

Local logs: `/tmp/fixes10-remote-approvals.log`, `/tmp/fixes10-sim.log`, and
`/tmp/fixes10-baseline-sim.log`. The clean comparison tree is `/tmp/fixes10-baseline.vB4NXc`.
The Swift implementation and tests are 140 and 350 lines respectively. No commit was made.

## Mac verification still required

Swift is not installed on OVH (`command -v swift` returned no path); neither compilation nor Swift
test execution is claimed. With the project's dependencies already available on the Mac, run:

```sh
swift test --skip-update --filter ManagedRemoteControlTests
```

Confirm the original `plaintextMissingKeyAndRedirectsFailClosed` passes without the former 15-second
pause, all five parameterizations of `redirectsRejectWithoutWaitingForBody` pass, and
`decisionPreflightFailureIsExplicitlyUnsent` passes for both inputs. All refusal timing assertions
must pass. Also confirm `unreachableAndDeadlineFailClosed` still receives `URLError`, the authenticated
round trip still verifies its record, and the lost-receipt/retirement regressions pass. Repeat the
focused suite to check cancellation timing under Swift Testing's normal parallel execution. These
tests must remain stub-only; no live Hermes, DNS endpoint, or loopback HTTP server is needed.
