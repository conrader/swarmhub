# Torvli — Grok Bot parity plan

Goal (Konrad, 2026-10-13): build the whole app with all Grok Bot functionalities.
Grok Bot is Cursor's hosted Mac agent app; Torvli reproduces its features on the user's own
Hermes box. Konrad's 16 Grok bots already live on his box as Hermes profiles `grok-<slug>`
(SOUL, skills, imported history), served at `https://konrad.agenthut.net/p/grok-<slug>/`.

## Standing constraints (from BRIEF*.md and SPEC-6.1)
- Copy Grok Bot's look and match its features with our own code and assets only. No Grok images,
  icons, fonts, prompts or tool definitions.
- No animations; dark theme by default; fast and light; no built-in model.
- Never import or store secrets outside the Keychain. Imported routines start disabled.
- Tests use synthetic fixtures only and never call Konrad's servers.
- Files ≤500 lines, split by function (`AgentAppTests.swift` is already 734 lines and gets split in P1).
- Pick features by what the server reports at `/v1/capabilities` (and by route presence),
  never by version number. The box runs Hermes 0.20.5 and may move to 0.21.x.

## How the work runs
- Each phase is a brief (`briefs/P<n>.md`) executed by Claude Code on the MacBook
  (`sb-mac-task --shell`) in `~/code/agentapp` on branch `p<n>`. The agent must get
  `./scripts/build.sh` and `swift test` green, then commits locally (author Konrad Sierzputowski).
- The orchestrator on OVH fetches the branch over ssh, reviews it (adversarial verifier),
  merges to `main` in `/home/ubuntu/torvli`, pushes to `github.com/conrader/torvli`,
  and the next phase starts from that `main`.
- Hermes API reference: upstream tag `v2026.8.19` (byte-identical to the box's 0.20.5
  `gateway/platforms/api_server.py`); for 0.21.x, tag `v0.21.7`.

## Phases
| # | Phase | Grok features covered | Hermes surface |
|---|-------|----------------------|----------------|
| P0 | Baseline | Stale rules test fixed; first green suite on the MacBook | — |
| P1 | Bots on profiles | Each bot bound to a Hermes profile with its own Keychain key; "Add bots from box" (paste `profile=key` lines, probe each, name from slug); guard against multiplex-off silent fallback (`/v1/models` id must equal the profile); import binds to `grok-<slug>` when a key exists; split oversized test file | `/p/<profile>/v1/models`, `/v1/capabilities` |
| P2 | Routines | Routines tab backed by real jobs: list, create (schedule presets + cron), edit, pause/resume, run now, delete; completion inbox: job results appear in the bot's chat as cards and mark it unread | `/api/jobs*` |
| P3 | Skills, tools, model | Overview shows the bot's real skills and toolsets; per-chat model picker | `/v1/skills`, `/v1/toolsets`, `/api/model/options`, `/api/sessions/{id}/model` |
| P4 | Chat parity | Steer a running turn; fork/branch a conversation (threaded replies); attachments and images; inline cards (question with options, draft with Send, link pills, images); persisted tapbacks; manual unread; Media tab built from the transcript | `/v1/runs/{id}/steer`, `/api/sessions/{id}/fork`, session stream input |
| P5 | Members & group chats | Group threads with several bots; @mention routing; each bot keeps its own session; Members tab | client-side over P1 sessions |
| P6 | Bundle import | `agentapp-bot-bundle/v1` multi-bot import with read-only transcripts, routines disabled, secrets filtered | local |
| P7 | Settings & polish | Usage (session token counts), Updates (GitHub releases of conrader/torvli), Computers (noVNC URL per bot; take-over opens it), Account; README feature table brought up to date | `/api/sessions` fields |
| P8 | Acceptance | MacBook build + full suite green; every endpoint the app uses verified against Konrad's box from OVH; Konrad does the last-hop UI check with his keys in the Keychain | live box (read-only probes) |

## Out of scope (no Hermes API, or not part of Grok Bot)
- Telegram/WhatsApp channels (not native to Grok Bot; handled by sb tooling).
- Marketplace plugins/connectors, box VM provisioning, creating profiles or editing SOUL/memory
  on the server (stock Hermes exposes no write API; `memory_write_api` and `admin_config_rw` are false).

## Server-side changes this plan needs (reversible, on Konrad's box)
- nginx on `konrad.agenthut.net`: `/v1/` and `/api/sessions` are done (2026-10-13);
  `/p/grok-` already forwards every sub-path. Add `/api/jobs` and `/api/model` for the default profile in P2/P3.
