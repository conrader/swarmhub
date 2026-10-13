# P6b — Keys in, live check of every bot

Read `PLAN.md`; standing constraints apply. Start from `main` (P6 merged, 4f5624f or later). Branch `p6b`.

1. **Import keys** (Konrad approved): `~/Applications/Torvli.app/Contents/MacOS/AgentApp --import-keys ~/.torvli-keys.import`
   (17 lines: `default=` + 16 `grok-*`). Report only profile names + OK/failed; confirm the file is gone afterwards.
   Never print, log or copy a key.
2. **Add `AgentApp --check-bots [--chat "<bot name>" "<text>"]`** (headless, like `--import-grok`; file
   `GrokImport/HeadlessCommands.swift` or a new one, ≤500 lines): for every Hermes bot in the real store, using the
   same backend construction the app uses for sending (base URL, `/p/<profile>`, Keychain key): print one line
   `name | profile | key: present/missing | models: <id> (match/MISMATCH) | caps: session_chat_streaming=…, jobs=…`
   from `/v1/models` and `/v1/capabilities` (read-only). With `--chat`, send one real turn to that ONE bot through the
   exact send path the UI uses (native sessions if advertised) and print the reply's first 200 characters plus the
   session id; exit non-zero on any failure. Unit tests with the URLProtocol mock for the line format and mismatch case.
3. Build + `swift test` green, package, reinstall `~/Applications/Torvli.app` (same backup rule as P6).
4. **Live run** with the installed app binary: `--check-bots` (expect 17 Hermes bots: default/Ermes-on-default if
   present plus 16 grok-*; all key present, all model ids matching), then `--chat "Jarvis" "Reply with exactly: Torvli OK"`.
   This sends one real message to Konrad's Jarvis bot — allowed, once.
5. Commit on `p6b` (author Konrad Sierzputowski <konrad@dmt.zone>), no push. Report: sha, totals, the full
   `--check-bots` output (it contains no secrets), the chat result line, and anything that failed.
