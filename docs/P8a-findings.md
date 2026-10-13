# P8a findings — Grok Bot server history (stopped at authentication)

Status: **stopped before any network call.** The API is identified, but the only access token on this Mac
is encrypted with a key held in the macOS Keychain, and reading it would show a Keychain prompt. The brief's
hard rule says to stop in that case. No request was sent to Grok/Cursor, and no export or import was re-run.

## Endpoint and protocol (from `/Applications/Grok Bot.app/Contents/Resources/app.asar`, read-only)
- Base URL: `https://api2.cursor.sh` (`CURSOR_API_BASE_URL` override; `backend.backendUrl`).
- Service: `aiserver.v1.GrokBotService`, unary method `ListGrokBotTranscriptEntries`
  → `POST https://api2.cursor.sh/aiserver.v1.GrokBotService/ListGrokBotTranscriptEntries`.
- Protocol: Connect (connect-es, `useBinaryFormat: true`, HTTP/1.1, gzip/br accepted). The app sends
  protobuf; a Connect server normally also takes `Content-Type: application/json`, but that is untested.
- Request `ListGrokBotTranscriptEntriesRequest`: `1 agent_id string`, `2 generation uint32?`,
  `3 before_seq int64?` (exclusive cursor), `4 limit uint32` (app caps at 500 and asks `limit+1`
  to learn `hasMore`), `5 session_id string`, `6 unread_boundary_ms int64?`.
- Response `ListGrokBotTranscriptEntriesResponse`: `1 entries GrokBotTranscriptEntry[]` (newest first;
  the app reverses them), `2 generation`, `3 cloud_agent_peer_ids`, `4 cloud_agent_peer_ids_known`,
  `5 unread_anchor`.
- `GrokBotTranscriptEntry`: `1 seq int64`, `2 entry_kind string`, `3 body bytes?` (UTF-8 JSON in the
  same `kind/seq/timestampMs/...` shape as the cache), `4 blob_hash string?`, `5 updated_seq`,
  `6 entry_id string?`, `7 body_omitted bool`.
  - `body` missing + `blob_hash` → `GrokBotService/PresignSandBoxStoreReads {relPaths:["blobs/<hash>"]}`
    returns presigned GET URLs (404 = gone).
  - `body_omitted` → re-list that one row with `before_seq = seq+1, limit = 1`.
  - Paging backwards: next `before_seq` = smallest `seq` of the page; stop when fewer than `limit` rows.
- Headers (`o_e`/`kC` in `electron-main/main-app.cjs`): `authorization: Bearer <cursor access token>`,
  optional `x-cursor-team-id`, `x-cursor-checksum` (derived from the machine id), `x-ghost-mode`,
  the client headers from `getSandBackendClientHeaders` (client version etc.), `x-request-id`.

## Why it stopped: the token
- `~/Library/Application Support/Grok Bot/sand-secrets.json` holds `cursor-accounts` →
  `cursor-access-token` / `cursor-refresh-token`, and `cursor-machine-id` (needed for the checksum header).
- Every value is Electron `safeStorage` ciphertext (`v10` prefix). The AES key is the login-Keychain
  generic password `svce="Grok Bot Safe Storage"`, `acct="Grok Bot Key"`, trusted only by Grok Bot.app;
  any other process reading it gets a Keychain access prompt.
- No plaintext token exists elsewhere in the app data (Local Storage, Session Storage, Partitions,
  `sand-client-persistence`: 0 JWT-shaped strings).

## Options for Konrad (each needs his decision)
1. Approve one Keychain read of "Grok Bot Safe Storage" (click *Allow* once, not *Always Allow*) for
   the exporter run; the exporter would decrypt the token in-process and never store it.
2. Hand the token to the exporter on stdin/env from a source he chooses.
3. Use Grok Bot's own data export, if the account offers one, and feed that file to the exporter.

Nothing for `--fetch-server-history` was implemented: the brief says to stop and report when the API
cannot be used within the rules.
