# Hermes versions SwarmHub works with

SwarmHub talks to stock Hermes over its own API (`/v1/*`, `/api/*`, `/p/<profile>/` multiplexing). Nothing is installed on the
box. This list says which Hermes versions we have actually run SwarmHub against. Updated 2026-10-14 09:00 UTC.

| Hermes | Where we ran it | Status | Known issues |
|---|---|---|---|
| **0.22.0** (newest stable, upstream tag 2026-10-13) | Konrad's box since 2026-10-14 08:50 UTC (getermes build with patch 0003) | works | stock upstream 0.22.0 still returns 500 on `GET /v1/skills`; our build fixes it (178 skills listed per bot) |
| **0.21.7** | Konrad's box 2026-10-14 05:48–08:50 UTC | works | `GET /v1/skills` returns 500 for every profile (upstream bug: `include_editorial` passed to `_find_all_skills`), so the Overview can't list skills; chat, sessions, jobs, models, multiplexing all work |
| **0.20.5** | the getermes fleet; Konrad's box until 2026-10-14 | works | none known for SwarmHub |
| older | — | not supported | — |

SwarmHub carries the same list in `HermesCompatibility` (`Sources/AgentApp/Models/HermesCompatibility.swift`; a test keeps the
two equal) and shows each connection's version from `/health` in Settings → Advanced → Servers and keys and the bot's Overview: a listed version shows
its status, any other version "not tested yet", anything older than 0.20.5 "not supported". On a version listed with the
`/v1/skills` issue, that exact 500 ("Failed to enumerate skills") shows as "This Hermes version can't list skills (known Hermes
bug)" instead of an error.

**Stock upstream check (2026-10-14):** `AgentApp --check-server` against an untouched upstream Hermes 0.22.0 (no getermes
patches, no hosting layer, multiplexing on, two profiles): health/version, auth, models, capabilities, model options, toolsets,
sessions, jobs and a session create/delete all PASS on every profile; skills = KNOWN (upstream bug); another profile's key = 401.
Not covered: a chat turn (the test server had no provider keys). SwarmHub needs nothing beyond stock Hermes except provider keys
for chat and `gateway.multiplex_profiles: true` for more than one bot per server.

OpenClaw: supported since P12 (Gateway WebSocket protocol 4), tested against a scripted Gateway only; see [openclaw-integration.md](openclaw-integration.md).

What SwarmHub needs from a box: `/v1/models`, `/v1/chat/completions` or `/v1/responses`, `/api/sessions`, `/api/jobs`,
`/api/model/options`, `/v1/skills`, `/v1/toolsets`, `/health` (version), and `gateway.multiplex_profiles` for more than one bot per
box (each profile needs its own `API_SERVER_KEY`). Bot management (P22) needs the manager bot's terminal and the stock
`hermes profile` command.
