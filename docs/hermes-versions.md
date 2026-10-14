# Hermes versions SwarmHub works with

SwarmHub talks to stock Hermes over its own API (`/v1/*`, `/api/*`, `/p/<profile>/` multiplexing). Nothing is installed on the
box. This list says which Hermes versions we have actually run SwarmHub against. Updated 2026-10-14 09:00 UTC.

| Hermes | Where we ran it | Status | Known issues |
|---|---|---|---|
| **0.22.0** (newest stable, upstream tag 2026-10-13) | Konrad's box since 2026-10-14 08:50 UTC (getermes build with patch 0003) | works | stock upstream 0.22.0 still returns 500 on `GET /v1/skills`; our build fixes it (178 skills listed per bot) |
| **0.21.7** | Konrad's box 2026-10-14 05:48–08:50 UTC | works | `GET /v1/skills` returns 500 for every profile (upstream bug: `include_editorial` passed to `_find_all_skills`), so the Overview can't list skills; chat, sessions, jobs, models, multiplexing all work |
| **0.20.5** | the getermes fleet; Konrad's box until 2026-10-14 | works | none known for SwarmHub |
| older | — | not supported | — |

OpenClaw: not supported yet (planned, P12).

What SwarmHub needs from a box: `/v1/models`, `/v1/chat/completions` or `/v1/responses`, `/api/sessions`, `/api/jobs`,
`/api/model/options`, `/v1/skills`, `/v1/toolsets`, `/health` (version), and `gateway.multiplex_profiles` for more than one bot per
box (each profile needs its own `API_SERVER_KEY`). Bot management (P22) needs the manager bot's terminal and the stock
`hermes profile` command.
