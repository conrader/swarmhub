# P10.0 — Grok Bot import spike findings (go/no-go)

Status: **live step pending.** The offline work (code, harness, pure tests) and the signed package + reinstall
are done; the two `--grok-spike` runs need Konrad at the Mac and have not been run. Nothing has contacted Grok,
nothing has read the Keychain secret, and no secret is recorded here.

## What is ready
- `GrokProtocol`, `GrokKeychain`, `GrokSafeStorage`, `GrokSecretsFile`/`GrokCredentials`, `SecretBytes`,
  `GrokChecksum`, `GrokRequestHeaders`, `GrokProtobuf` (`Sources/AgentApp/GrokExport/`).
- The throwaway harness `--grok-spike <report.json>` (`Sources/AgentApp/GrokImport/HeadlessGrok.swift`).
- Pure tests over every P10.0 vector (`Tests/AgentAppTests/GrokSpikeCryptoTests.swift`): checksum, PBKDF2,
  safeStorage, protobuf, JWT `exp`, `scoped:v1:` unwrap, machine-id / team-id rules, wrong-key rejection.
- The signed app packaged and reinstalled to `~/Applications/Torvli.app` (P6 backup rule).

## Live runs still to do (the one exception to "never call servers"; Konrad at the Mac, two clicks)
The harness writes `~/Library/Caches/Torvli-snapshots/grok-spike.json` (0600), rewritten after each step so a
hang keeps earlier results; numbers and booleans only. Start the **packaged** app with `open -n` (never the
debug binary; never plain ssh — it fails with `errSecInteractionNotAllowed`). Say which button to press first.

- **Run 1 (Deny):** Konrad clicks **Deny** on the macOS dialog (records the status; nothing is read).

  ```sh
  open -n ~/Applications/Torvli.app --args --grok-spike ~/Library/Caches/Torvli-snapshots/grok-spike.json
  ```

- **Run 2 (Allow):** Konrad clicks **Allow** (not Always Allow).

  ```sh
  open -n ~/Applications/Torvli.app --args --grok-spike ~/Library/Caches/Torvli-snapshots/grok-spike.json
  ```

After each run, read the report file (not console text). Relay and quote here, with no secrets and no message
text: the dialog's wording, whether it asked for a password, the name it showed ("Torvli" or "AgentApp"), the
buttons, and any other dialog (a folder-access prompt counts).

## Go/no-go (to be filled from the runs)
- (a) probe under 500 ms, no dialog: _pending_
- (b) cache readable, no prompt, ≥1 blob: _pending_
- (d) Deny gives a non-success status and nothing hangs; Allow gives bytes: _pending_
- (e) credential shapes OK and the account binding holds (or no slot blob): _pending_
- (f) HTTP 200 with ≥1 row decoded (if bytes still start `1f 8b`, gunzip manually and re-run (f)): _pending_
- (g) honest `user-agent` accepted?: _pending_

Red on any of (a)/(b)/(d)/(e)/(f) = STOP and report; Konrad then chooses cache-only or stopping.
