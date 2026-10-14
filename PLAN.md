# SwarmHub — Grok Bot parity plan

SwarmHub targets macOS, Windows, and Linux. The phases below cover the current macOS prototype; Windows and Linux implementations are planned.

Goals (Konrad, 2026-10-13): build the whole app with all Grok Bot functionalities; first milestone: SwarmHub
ready and working on the Mac with every Grok bot as it was made on Grok, including its history.
Order therefore: P0 → P1 → **P6** → install + live check → P2 → P3 → P4 → P5 → P7 → P8 → P9 (after Konrad accepts it).
Grok Bot is Cursor's hosted Mac agent app; SwarmHub reproduces its features on the user's own
Hermes box. Konrad's 16 Grok bots already live on his box as Hermes profiles `grok-<slug>`
(SOUL, skills, imported history), served at `https://konrad.agenthut.net/p/grok-<slug>/`.

## Standing constraints (from BRIEF*.md and SPEC-6.1)
- Copy Grok Bot's look and match its features with our own code and assets only. No Grok images,
  icons, fonts, prompts or tool definitions. Exception (P15, accepted 2026-10-13): the vendored, pinned MIT
  BotAvatarsKit (Jakub Antalik, Libraries.dev) under `Vendor/`, credited in `THIRD-PARTY-NOTICES.md`.
- No animations, except avatar motion by context (P15): list rows stay still unless that bot is working or hovered;
  the open bot's large mark and showcase views idle gently; a working bot hops everywhere; Settings → Appearance →
  Avatar motion can choose Calm everywhere or Off; macOS Reduce Motion is always honoured. Also allowed (P14): sidebar and
  right-column open/close (system split-view / inspector slide; none under Reduce Motion).
  Dark theme by default; fast and light; no built-in model.
- Never import or store secrets outside the Keychain. Imported routines start disabled.
- Tests use synthetic fixtures only and never call Konrad's servers.
- Files ≤500 lines, split by function (`AgentAppTests.swift` is already 734 lines and gets split in P1).
  `Vendor/` is exempt (the gate scans `Sources/` and `Tests/`).
- Pick features by what the server reports at `/v1/capabilities` (and by route presence),
  never by version number. The box runs Hermes 0.20.5 and may move to 0.21.x.

## How the work runs
- Each phase is a brief (`briefs/P<n>.md`) executed by Claude Code on the MacBook
  (`sb-mac-task --shell`) in `~/code/agentapp` on branch `p<n>`. The agent must get
  `./scripts/build.sh` and `swift test` green, then commits locally (author Konrad Sierzputowski).
- The orchestrator on OVH fetches the branch over ssh, reviews it (adversarial verifier),
  merges to `main` in the orchestrator checkout, pushes to `github.com/conrader/swarmhub`,
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
| P6 | Grok import | Exporter reads the Grok Bot app cache on the Mac (latest 62–200 entries per conversation, roster) into `agentapp-bot-bundle/v1`; app import (UI + headless CLI) with read-only history archive, avatar mapping, `grok-<slug>` binding; keys CLI; install to ~/Applications | local; `/p/grok-<slug>/` |
| P7 | Settings & polish | Usage (session token counts), Updates (GitHub releases of conrader/swarmhub), Computers (noVNC URL per bot; take-over opens it), Account; README feature table brought up to date | `/api/sessions` fields |
| P8 | Acceptance | MacBook build + full suite green; every endpoint the app uses verified against Konrad's box from OVH; Konrad does the last-hop UI check with his keys in the Keychain | live box (read-only probes) |
| P9 | History on the box | Grok history (6,843 messages, seq 1 onward) written into each `grok-*` profile's `state.db` as `grok-import` archive sessions (one per day) through the box's own `SessionDB`, so bots can `session_search` it and clients can list it; SwarmHub shows one archive per bot. Canary on Rapper, backups, rollback (`briefs/P9.md`) | per-profile `state.db` (no API exists to append messages) |
| P10 | Grok import in-app (proposed) | One in-app flow replaces the exporter + `--import-grok`: native Swift port (no Python), one macOS Keychain prompt, read-only full-history fetch, existing importer; phased P10.0 (go/no-go) → P10a offline core → P10b fake-server → P10c command → P10d sheet → P10e live. Awaits Konrad's D1–D5 (`briefs/P10.md`) | Grok private RPC (read-only); local |
| P11 | Model from the box's supplier | Overview picker mirrors `/api/model/options` per profile, grouped and labelled by supplier, default first, reasons for every state; enhances P3 (`briefs/P11.md`) | `/api/model/options`, `/api/sessions/{id}/model` |
| P12 | Connect OpenClaw | Finish `OpenClawBackend`: Gateway WebSocket v4 handshake + device pairing (A), streaming chat/steer/history (B), approvals/threads/attachments (C) (`briefs/P12.md`) | OpenClaw Gateway WS RPC |
| P13 | Model roles (proposed) | Two roles with a SwarmHub-wide default and a per-bot override (override > SwarmHub default > box default): Conversation (client-side, via the session lock) and Coding (a client-side "coding thread" fork + the box-side sub-agent model `delegation.*`, which no API can set). Read-only display first; box canary P13.0 before any config write. Awaits Konrad's D1–D5 (`briefs/P13.md`) | `/api/sessions` create/lock/fork; profile `delegation.*` (box-side) |
| P18 | Rename to SwarmHub | Visible name SwarmHub from one constant (AppConstants.name) with a guard test; SwarmHub.app + zips; honest user-agent SwarmHub/<version>; Updates URL conrader/swarmhub; export folder and self-test prefix renamed with fallbacks; internal AgentApp ids, bundle id, data folder and Keychain unchanged (`briefs/P18.md`) | — |
| P20 | Sidebar like Grok Bot | 36 pt marks, two lines (name + latest message / Draft / Typing), flat list, round search and + buttons, user-initial bottom button (`briefs/P20.md`) | local store only |
| P19 | PDF and document attachments | Hermes accepts no file parts (0.20.5 and 0.21.7), so PDFs are read on the Mac: PDFKit text split into <=60k-char parts, scanned pages as images or on-device OCR; fixes the silent 65,536-char truncation of today's text attachments (`briefs/P19.md`) | session chat text + image parts |
| P21 | Simple settings + setup wizard (proposed) | Settings becomes a short simple page (connection status with Test and Set up, your name, appearance, notifications, about) with everything difficult behind Advanced (servers and keys, models, auto-review, computers, usage, build details); a first-run wizard connects an existing box (address, key, choose agents) or shows "Set up a new one" as an inert coming-soon card (managed hosting deferred; provider name not hardcoded). Decisions D1-D12 with defaults. |
| P22 | Jarvis manages bots (accepted, in progress) | Jarvis (grok-jarvis) gets a box skill to create bots (profile + own key + SOUL), list them, read/edit their instructions (diff + previous kept) and retire them (moved, never deleted), asking Konrad first; SwarmHub discovers new bots from Jarvis's registry without pasted keys and shows each bot's box instructions as the source of truth. Accepted 2026-10-14 with the recommended D1-D5. |
| P15 | Bot marks | Bot avatars become BotAvatarsKit marks in Grok's shapes and 11 colours (stored words, else derived from the id like Grok), group clusters, motion by context with Settings → Appearance → Avatar motion (By context, Calm everywhere, Off) and Reduce Motion; lazy additive migration of imported bots (`briefs/P15.md`) | local |
| P16 | No reply is lost (proposed) | A turn is finished only when the box closed the run; cut or unsent turns are stored as incomplete / not sent with a Retry button that reads the box first; replies finished while the Mac was away are fetched, never regenerated; group sessions reconciled from the box; `--reconcile [--dry-run]` heals stores hurt by the old behaviour. Decisions D1–D5 with defaults. |
| P17 | Models from the agent's own backend (proposed) | Every model an agent's settings offer or SwarmHub applies comes from that agent's own backend: Hermes = its profile's `/api/model/options` (top-level model = agent default); OpenClaw = its Gateway's list through a backend-neutral catalog P12 plugs into; the SwarmHub-wide default stays a pair, shown and applied only where the bot's list offers it. Awaiting Konrad's yes. |

## Out of scope (no Hermes API, or not part of Grok Bot)
- Telegram/WhatsApp channels (not native to Grok Bot; handled by sb tooling).
- Marketplace plugins/connectors, box VM provisioning, creating profiles or editing SOUL/memory
  on the server (stock Hermes exposes no write API; `memory_write_api` and `admin_config_rw` are false). The one
  exception is P9's archive sessions, written through the box's own `SessionDB` once Konrad accepts it.

## Server-side changes this plan needs (reversible, on Konrad's box)
- nginx on `konrad.agenthut.net`: `/v1/` and `/api/sessions` are done (2026-10-13);
  `/p/grok-` already forwards every sub-path. Add `/api/jobs` and `/api/model` for the default profile in P2/P3.
- P9: `grok-import` archive sessions in each `grok-*` profile's `state.db` (backups in `/root/grok-import-backup-<ts>/`;
  `--rollback` removes only `grok-import` sessions).
