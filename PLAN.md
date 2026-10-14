# SwarmHub — Grok Bot parity plan

SwarmHub targets macOS, Windows, and Linux. The phases below cover the current macOS prototype; Windows and Linux implementations are planned.

Goals (Konrad, 2026-10-13): build the whole app with all Grok Bot functionalities; first milestone: SwarmHub
ready and working on the Mac with every Grok bot as it was made on Grok, including its history.
Order therefore: P0 → P1 → **P6** → install + live check → P2 → P3 → P4 → P5 → P7 → P8 → P9 (after Konrad accepts it).
Grok Bot is Cursor's hosted Mac agent app; SwarmHub reproduces its features on the user's own
Hermes box. Konrad's 16 Grok bots already live on his box as Hermes profiles `grok-<slug>`
(SOUL, skills, imported history), served at `https://konrad.agenthut.net/p/grok-<slug>/`.

## Open work (kept current by Claude; last update 2026-10-14 08:45 UTC; P23+P20 20538ee, P19 c31d0c0, P24 + release 0.4.1 deb1f7a, release 0.4.2 449a770, P10c 36b3af0 merged)

Everything planned that is not merged yet, so nobody has to remember it. Built = merged into `main`.
**Konrad 2026-10-14: "Build all, defaults"** — every row below is accepted with the recommended defaults (P16, P17, P21, P12 included; P13 Part C's live step has his go). Order: P23 → P19 → P24 → P10c → P10d → P10e → P13 C → D → E → P16 → P21 → P17 → P12; each merged when green; Claude reports results, comes back only for a real blocker.

| What | State | Next step |
|---|---|---|
| Group chats cut documents at 8,000 characters | building (`groupdocs`, MacBook) | merge when green |
| Automatic updates: prove a real update | v0.4.2 (notarized Developer ID, Apple submission cd59e74f Accepted) published; installed app is 0.4.1 | Konrad: SwarmHub → Check for Updates… (or wait for the daily check) → install; back up the Sparkle private key |
| P10d / P10e Grok import in the app (sheet, live) + P10c live steps | P10c merged 36b3af0 (435 green; probe on the real Mac OK, no click); P10d building (`p10d`) | after P10d ships in an update: one live session with Konrad (P10c ii-vi + P10e), Allow clicks |
| P13 Parts C / D / E model roles (prove, existing chats, sub-agents) | Parts A+B merged, C/D/E never started | queued; Part C live step has Konrad's go |
| P16 No reply is lost | accepted (build all) | queued |
| P17 Models from the agent's own backend | accepted (build all) | queued |
| P21 Simple settings + setup wizard | accepted (build all) | queued |
| Vanilla test bed: SwarmHub against untouched upstream Hermes 0.22.0 (no getermes patches, no layer), isolated HERMES_HOME + throwaway keys + two profiles; run --check-bots, ui-smoke facts, P22 manager flow against a mock | not started (Konrad 2026-10-14: "I hope this is vanilla hermes") | after P10c; proves SwarmHub needs nothing beyond stock Hermes |
| P12 Connect OpenClaw | accepted (build all), never started | queued last |
| Small: sidebar "Import from Grok Bot" item (needs P10d), attention badge for failed turns (needs P16), idle-pause for hidden windows | waiting on the phases named | with those phases |
| Box/ops: Codex login has no refresh token (Konrad re-logs in), DB password in plain text in the context-api unit, staged P9 bundles on the box to delete | open | flagged to Konrad |

## Standing constraints (from BRIEF*.md and SPEC-6.1)
- Copy Grok Bot's look and match its features with our own code and assets only. No Grok images,
  icons, fonts, prompts or tool definitions. Exception (P15, accepted 2026-10-13): the vendored, pinned MIT
  BotAvatarsKit (Jakub Antalik, Libraries.dev) under `Vendor/`, credited in `THIRD-PARTY-NOTICES.md`.
- No animations, except avatar motion by context (P15, revised 2026-10-14): list, focus and showcase marks animate
  without hover and face inward toward the conversation. Idle, focused, hover greeting, working, approval waiting and
  successful-reply completion select Libraries.dev's original states and gestures, with flat shading
  (see `docs/avatar-animation-scenarios.md`). Settings → Appearance → Avatar motion can choose Calm everywhere
  (slower continuous motion, no idle flips) or Off; macOS Reduce Motion is always honoured.
  All motion stops while the app is inactive or its main windows are hidden. Also allowed (P14): sidebar and
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
- **Never leave a test-mode SwarmHub running** (Konrad 2026-10-14: "check for updates" was greyed out because the open copy
  was the `--ui-smoke` launch, where updates are off by design). After any `--ui-smoke` / `--render-snapshot` / probe launch, quit
  that instance by pid and reopen the app normally with `open ~/Applications/SwarmHub.app`; report the normal instance's pid.
- **Ship through the updater:** a merged change reaches Konrad as a new notarized release (Developer ID, `plainsay-notary`,
  build number +1, appcast) that his installed app updates to; no hand-installs over his app once updates work.
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
| P22 | Main bot manages bots (v2, vanilla; merged 765753e, 347 green) | Everything inside SwarmHub, nothing on the box: SwarmHub sends the manager bot (Jarvis) a short bot-management text ON DEMAND only (Manage bots menu or a management request + its follow-ups), Jarvis uses stock `hermes profile` + shell to create bots, change instructions, retire; reply ends in a hidden swarmhub JSON block that SwarmHub applies (add bot, avatar, instructions). New bot keys = HMAC of the manager key, derived on both sides, never sent. Proven live on stock 0.21.7 2026-10-14. |
| P23 | Merge Codex's work + app icon (accepted) | Cherry-pick Codex's uncommitted menus/keyboard shortcuts/Sparkle updates/avatar animation (snapshot 44cc96c) onto main with P22 kept; wire Resources/AppIcon into the bundle (iconutil → AppIcon.icns, CFBundleIconFile). Then P20 (sidebar: name + last message) in the same run. |
| P24 | Hermes versions (accepted) | docs/hermes-versions.md lists the Hermes versions we run against; SwarmHub shows each box's Hermes version (from /health) with works/not-tested status, and maps the known 0.21.7+ `/v1/skills` 500 to a calm "can't list skills" note instead of an error. |
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
