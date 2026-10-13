# AgentApp bot bundle v1

CONFIDENTIAL: exported profiles can contain personal and infrastructure details even after credential redaction. Keep `out/` on the owner’s machines; do not commit or share it. Export directories use 0700 and files 0600.

Run `python3 export.py` from any directory with Python 3 (stdlib only). It reads the fixed sibling `snapshot/` and writes the fixed sibling `out/`. An existing export is replaced only after a successful build in a private temporary sibling directory; failed builds preserve it. Input symlinks are refused. SQLite opens read-only and immutable after checking sidecars; a nonempty WAL aborts the run. Empty WAL/SHM presence is reported. No remote calls are made.

`out/index.json` and each bot bundle carry `format: "agentapp-bot-bundle/v1"`. Reject unsupported format versions in Swift. Files are UTF-8 JSON; field names use snake_case. Unknown fields can be ignored. `null` means unavailable; empty lists mean no recoverable records, not proof that the original remote bot had none. All arrays preserve order. Routine import must leave execution disabled until configured for Hermes.

The index contains `bots: [{source_id, name, bundle, messages, events, redactions}]`, `skills: [{name, file}]` and `skill_redactions`. Bundle and skill paths are relative to the export root. Bot directories use a normalized name plus full source UUID for stable uniqueness. Use `source_id` for deduplication, not the display name.

Each `out/<bot-slug>/bundle.json` has:

| Field | Type / meaning |
| --- | --- |
| format | String, exact version identifier |
| source_id, slug, name, description | Strings; description may be empty |
| title | String or null; may be empty |
| avatar | `{shape: String?, colour: String?}`; source spelling, no invented defaults |
| instructions | String or null; stored profile description |
| instructions_source | `"profile.description"` or null |
| memory_facts | Array; empty in this snapshot. Future mapped records must use `{id: String, text: String, timestamp: String?}` |
| routines | Array; empty here. Contract for supported mappings: `{id: String, name: String, prompt: String, schedule: String?, trigger: String?, timezone: String?, enabled: Bool}`. Preserve source schedule syntax; never guess cron/timezone |
| skills | Array of `{name, file, basis}`; file relative to export root; basis identifies inferred profile mentions |
| messages | Ordered array using the message contract below; empty here |
| events | Array of `{id: String, seq: Int64, timestamp_ms: Int64, event: {type: "name-changed", from: String, to: String}}`; lifecycle events, not chat bubbles. Unix milliseconds; seq is authoritative. Only this event type and exactly these payload keys are supported |
| source | `{created_at_ms: Int64?, harness: String?, notify_on_agent_updates: Bool?}` |
| limitations | Array of human-readable strings describing missing/unmapped source data |
| statistics | `{transcript_rows, messages, events, tool_entries_dropped}` integer counts |
| redactions | `{total: Int, counts: {category: Int}}` |

The message contract is `{id: String, seq: Int64, role: String, author: String?, text: String, timestamp: String?, thread: String?, reply_to: String?, attachments: [{file: String, available: Bool}]}`. Roles are `user`, `assistant`, `system`, or `unknown`; timestamps, when mapped, must be ISO 8601 UTC strings. Sequence order takes precedence over timestamps. Preserve absent thread/reply/author/timestamp as null. File references must be export-root-relative safe paths, never absolute paths, URLs, or `..` traversal. `available: false` marks references whose bytes were not exported. Do not fetch external files during import.

**No message shape was observed, so this implementation deliberately fails on any non-event transcript row.** This contract specifies the importer target, not a claim that future Grok message shapes are supported. Likewise nonempty automation directories fail before guessing their schedule format. Tool-call internals are not exported; no optional tool section is generated. A future mapping must distinguish visible messages from internal tool entries and count dropped internals. Blobs are not exported; opaque/encrypted attachments cannot safely be scanned with stdlib alone.

Skill Markdown is copied to `out/skills/<skill>/SKILL.md` after redaction. Skills are inert reference material; import should not install or execute their instructions automatically. Global availability does not imply assignment to every bot.

Security uses an allowlist of exported fields and an explicit redaction pass over free text: name, title, description (reused as instructions), rename from/to, and skill Markdown. Structural fields (IDs, slug, seq, thread/reply_to, enum values and generated paths) never enter text redaction. Sensitive structured fields, including decoded `blobEncryptionKey`, are excluded. Strings redact private key blocks, credential assignments, authorization values, Google AIza keys, 32-character hex keys, UUIDs in key/token contexts, Stripe/Hugging Face keys, Telegram tokens including URL forms, prose passwords, pwd/pass/key/sig assignments and query parameters, full Cookie headers, JWTs, URL credentials, webhook URLs, and long opaque token-like strings without hyphens. `box-secrets` and `host-secrets` are never traversed or copied. Arbitrary KV state, raw database bytes and binaries are not exported. Redaction is conservative and can remove benign long strings; it is heuristic and cannot prove arbitrary prose free of every possible secret. Reports record categories/counts, never values or excerpts. Counts measure redaction occurrences and field exclusions, not unique credentials; skill counts are global rather than charged to every bot.

`out/redaction-report.json` contains per-bot reports and the global skill report. `out/SUMMARY.md` lists every bot, message/event counts, redactions, and mapping limitations. Unknown tables, nonempty encrypted root pointers/blobs/inboxes, unsupported transcript events, new snapshot/agent files, nonempty automation directories and nonempty WAL files fail before replacing out. Unknown profile/settings/metadata keys are excluded and listed under source_observations in the report. Empty sidecars and their sizes are also reported. Failures remove the temporary build and preserve the previous export. A successful replacement briefly moves the previous directory aside before installing the new one; readers should not import during replacement.

The literal `[REDACTED]` marker indicates a removed free-text match; treat it as ordinary display text, never as a credential placeholder to restore. A whole Cookie header may be replaced by one marker. Counts are occurrences per source field or excluded sensitive field, not unique credentials. Description/instructions share one source count. A source may itself contain the marker. `python3 export.py --self-test` runs only fake test cases; the same test suite runs before every export and aborts on failure.

Observed avatar shapes: `blob`, `cylinder`, `shield`, `gem`, `hex`, `leaf`; colours: `black`, `violet`, `blue`, `yellow`, `orange`, `green`. Empty source avatar values become null. Importers should preserve unknown future strings or display a fallback. The only v1 skill `basis` value is `"name mentioned in profile"`, an inferred relationship.

A small synthetic bundle is at [docs/examples/bundle.json](docs/examples/bundle.json); its IDs, profile and lifecycle event are fake. No skill or attachment bytes are required by that example.
