# P8a — Download the FULL Grok Bot history (not just the local cache)

Read `PLAN.md`; standing constraints apply. Start from `main`. Branch `p8a`.
Konrad's goal requires every bot's whole Grok history. The local cache holds only the latest 28–200 entries per
conversation; sequence numbers show ~6,200 older entries on Grok's servers (e.g. Jarvis starts at seq 2928).
This is Konrad's own account and data on his own Mac; he asked for it to be downloaded.

## How the Grok Bot app pages history (find the details yourself, read-only)
`/Applications/Grok Bot.app/Contents/Resources/app.asar` (41 MB; extract with `npx --yes @electron/asar extract`
into a temp dir OUTSIDE the repo, or grep it directly) contains `ListGrokBotTranscriptEntries`
(Request/Response types), `getAgentTranscriptPage`, `getAgentTranscriptWindow`, `getAgentTranscriptTail`,
`loadOlderTranscript`, `transcriptHasOlder`. Identify: the RPC base URL and full service/method path, protocol
(Connect/gRPC-web; prefer Connect JSON if supported), request fields (agent/bot id, cursor/before-seq, limit),
response shape (entries in the same `kind/seq/timestampMs/...` format as the cache), and how the app authenticates
(where its session/access token comes from: `~/Library/Application Support/Grok Bot/` files such as
`sand-secrets.json`, or the macOS Keychain; and any required headers like client version).

## Hard rules
- READ-ONLY calls only (list/get transcript pages). Never call anything that sends, edits, deletes, marks read,
  or changes settings. Sequential, ≤2 requests/second, stop on any 4xx other than an expected end-of-history signal.
- The Grok token is a secret: read it in-process only; never print, log, write to disk, commit, or pass it on a command
  line (use env or stdin). If reading it needs a Keychain prompt, stop and report.
- Output only to `~/Documents/Torvli Grok Export/` (0700/0600). Never commit real data; tests use synthetic fixtures.
- If the API cannot be used without breaking these rules, stop and report what you found.

## Must do
1. Extend `scripts/export-grokbot.py` with `--fetch-server-history`: for each of the 17 conversations (bot UUIDs from
   the roster/cache), page backwards from the oldest cached seq to seq 1 (or until the server says no older), merge
   with the cache (dedupe by entry id/seq), run the same mapping + secret filter, and rewrite the bundles. Report per
   bot: entries fetched, oldest/newest date, total messages, and whether seq coverage is now complete (1..max with no
   gaps; list gaps if any). Unit-test the paging/merge/dedupe logic with a fake server (synthetic).
2. Re-run `AgentApp --import-grok` (installed binary) on the updated export (back up store.json + grok-history first);
   confirm the re-import updates archives without duplicating bots or messages; report per-bot archive counts.
3. Build + `swift test` + python tests green; commit on `p8a` (author Konrad Sierzputowski <konrad@dmt.zone>); no push.
   Final report: endpoint/protocol summary (no secrets), per-bot coverage table, import counts, anything incomplete.
