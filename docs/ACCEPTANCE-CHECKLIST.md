# Native UI acceptance (local Mac)

Launch from this checkout with:

```sh
SWARMHUB_UI_ACCEPTANCE=1 ./scripts/run-ui-acceptance.sh
```

The script builds debug and runs the real SwiftUI app with isolated fixtures. Build dependencies must already be available for an offline build. The running acceptance app uses no network. Remove Hermes, Composio, OpenClaw, Keychain or other QA environment settings first; conflicting settings deliberately exit 78. Do not use real keys.

Every tab must retain **ACCEPTANCE MODE - nothing is sent**. Each launch creates a new private `swarmhub-ui-acceptance-*` temporary directory; its path appears at the bottom and on stdout. Normal app data is not imported. This checklist is a manual Mac handoff, not a claim that UI acceptance ran on Linux.

## Managed approval

1. Open **Approvals**, find `managed-dummy`, and expand its **Bound operation details**. Check its task ID, fingerprint, owner gate, `fake: true`, recipient and text.
2. Click **Approve**. Confirm only that card disappears and its matching task ID appears as approved, simulated, with no operation executed.
3. Click **Reset approval fixtures** and **Decline** the new managed card. Confirm its matching task is denied and the remote card remains.

**Pass:** both decisions affect only the reviewed operation; no message or command executes. Reset creates fresh IDs rather than reviving a decided operation.

## Remote approval variant

1. In **Approvals**, inspect `remote-dummy` and its bound details. Confirm the displayed origin is `https://acceptance.invalid`.
2. Click **Approve**; confirm its matching task receives the simulated approval and only that card disappears.
3. Reset fixtures and **Decline** the remote card; confirm the matching task is denied and the managed card remains.

**Pass:** the normal app reconciliation accepts an operation-bound in-process receipt, including origin/runtime/profile binding. This does not test TLS, remote authentication, lost responses or a deployed approval service.

## Secure key sheet

1. Open **Secure key → Open secure key sheet**. Verify the acceptance banner and in-memory storage description; the empty save button is disabled.
2. Type `dummy-acceptance-key`, verify the field masks it, and choose **Save dummy key** (or Return).
3. Reopen the sheet. Verify the field is empty; type another dummy value and press Escape/Cancel.

**Pass:** the sheet closes after saving, the tab says the dummy key was saved in memory, and no value appears in chat, evidence files or logs. Cancel does not save. Quitting discards the in-memory store; no Keychain item or secret file is created.

## Draft Send

1. Open **Draft Send** and review `a@example.invalid`, subject `Acceptance draft`, and the dummy body.
2. Click **Send**. Verify the card and receipt list show **simulated:true, delivered:false** and Send becomes disabled.
3. Inspect `send-<attempt UUID>.json` in the displayed evidence directory. Confirm the exact draft, source/conversation IDs, `simulated: true` and `delivered: false`. Click **New draft fixture** to exercise a second attempt.

**Pass:** one private receipt per accepted card; repeated Send cannot deliver or create a second attempt for that card. A recording error displays an error and never marks the draft sent.

## Startup refusal

1. Run `./scripts/run-ui-acceptance.sh` without the opt-in variable; expect exit 78.
2. Run `SWARMHUB_UI_ACCEPTANCE=1 HERMES_URL=https://example.invalid ./scripts/run-ui-acceptance.sh`; expect exit 78 before build/launch, with a configuration refusal and no echoed value.
3. Launch a release binary with `SWARMHUB_UI_ACCEPTANCE=1`; expect exit 78 before normal app initialization. Launch normally without the variable; acceptance mode must remain absent.

**Pass:** there is no fallback to ordinary app startup for a malformed, conflicting or unsupported acceptance request. On Linux, a valid isolated request exits 2 because a local Mac is required.
