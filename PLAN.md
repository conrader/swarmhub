# SwarmHub — Grok Bot parity plan

SwarmHub targets macOS, Windows, and Linux. The phases below cover the current macOS prototype; Windows and Linux implementations are planned.

Goals (Konrad, 2026-10-13): build the whole app with all Grok Bot functionalities; first milestone: SwarmHub
ready and working on the Mac with every Grok bot as it was made on Grok, including its history.
Order therefore: P0 → P1 → **P6** → install + live check → P2 → P3 → P4 → P5 → P7 → P8 → P9 (after Konrad accepts it).
Grok Bot is Cursor's hosted Mac agent app; SwarmHub reproduces its features on the user's own
Hermes box. Konrad's 16 Grok bots already live on his box as Hermes profiles `grok-<slug>`
(SOUL, skills, imported history), served at `https://konrad.agenthut.net/p/grok-<slug>/`.

## Open work (kept current by Claude; last update 2026-10-14 08:45 UTC; P23+P20 20538ee, P19 c31d0c0, P24 + release 0.4.1 deb1f7a, release 0.4.2 449a770, P10c 36b3af0, group documents 46619c1, release 0.4.3 1a61357, P13 Part C 55be45a, P10d 6ec4eee merged; release 0.4.4 published; P21 + P16 shipped in 0.4.5 (a1ef85c), P17 6eabea5, --check-server 8261bb4, P21b e04fbb7, P13 Part D f39e151 merged; release 0.4.6 published (b6f9452; roles e2e 8/8 from the notarized build))

Everything planned that is not merged yet, so nobody has to remember it. Built = merged into `main`.
**Release cadence (Konrad 2026-10-14): "we dont need to make publishes every 30 minutes"** — green phases merge into `main`; releases happen only when Konrad names the moment ("let me name the moment where we publish"); until then keep working and merging.
**Konrad 2026-10-14: "Build all, defaults"** — every row below is accepted with the recommended defaults (P16, P17, P21, P12 included; P13 Part C's live step has his go). Order: P23 → P19 → P24 → P10c → P10d → P10e → P13 C → D → E → P16 → P21 → P17 → P12; each merged when green; Claude reports results, comes back only for a real blocker.

| What | State | Next step |
|---|---|---|
| Automatic updates | proven: Konrad updated 0.4.1 → 0.4.2 via Sparkle; 0.4.3 (Keychain fix, notarized) published + hand-installed, "works, no prompts" (Konrad) | Konrad: back up the Sparkle private key |
| P10e live acceptance + P10c live steps (Grok import on Konrad's real account) | P10d merged (482 green): sheet, + → Import from Grok Bot…, Settings → Account → Grok Bot | shipped in 0.4.4; one live session with Konrad (Allow clicks) |
| P13 Part E sub-agent guidance | P13.0 canary 2026-10-14: NO-GO (check 2: Hermes 0.22.0 drops an async delegation result if the parent turn is still active ~15 s after the child finishes) — `docs/P13-canary.md`; Part D merged f39e151 | stays off; to revive: Hermes must deliver after the turn ends (upstream report or getermes core patch — Konrad's call), then re-run the canary |
| P16 last hop | shipped in 0.4.5 (588 green) | Konrad: Wi-Fi off mid-answer → Incomplete then completes; send offline → Not sent, Retry once; quit mid-answer → partial kept |
| P12 Connect OpenClaw | shipped in 0.4.7 (merge 4624ca7, release 9e32b17, notarized; feed + zip verified 2026-10-14; Hermes e2e 8/8 x4 A/B vs 0.4.6, one earlier steer 409 = server timing) | real-Gateway last hop needs an OpenClaw Gateway (`docs/openclaw-integration.md`) |
| P25 OpenClaw in the setup window | shipped in 0.4.8 (merge eb5d89f, 726 green; release 02687a7 notarized, feed + zip verified 2026-10-14) | real-Gateway last hop needs an OpenClaw Gateway |
| P26 Manager agent on OpenClaw | shipped in 0.4.8 (merge a8dfd28, 736 green x2 with P25; Hermes e2e 8/8 from the notarized build) | real-Gateway last hop: mark an OpenClaw agent manager, create a bot, approve exec |
| P27 SwarmHub skills installed into bots + model recipe + live tool activity | shipped in 0.4.9 (merge d8ae419; release af1d808 notarized; feed + zip verified 2026-10-14) | Konrad: Install banner on Jarvis, then "switch all agents to <model>" |
| P27 follow-up: OpenClaw skills | D8: OpenClaw agents keep P26's on-demand text this phase; installing SwarmHub skills into an OpenClaw agent (its own skills folder, through its manager's exec) and the model recipe for OpenClaw are a later phase | after P27 ships |
| P28 Steer that actually lands (+ reply order, 401 loop, hermetic tests) | shipped in 0.4.9 (merge da8bcb6, 783 green x3; live e2e 9/9 from the notarized build incl. b1 steer-during-text and b2 steer-during-tool) | — |
| P29 Steps row unfolds while working + P30 unpinned chat shows the agent default + faster model recipe (skill 1.0.1) | merged (P29 5f3531b, P30 a3fbf72/3f5f9b2 via 6860cab) | shipped in 0.5.0 (release 23ade84, notarized; live e2e 9/9 from the notarized build; feed + zip verified 2026-10-15) |
| P32 Keep what the app promises (12 audit items) | merged (6860cab first half; cc3534c second half, 851 green) | shipped in 0.5.0 |
| P33 Overview spread over tabs (Overview · Model · Skills · Activity · Routines · Media · Computer; symbol + caption tab bar) | merged (4ed042a, 851 green x2 + independent check) | shipped in 0.5.0 |
| P34 Bot-to-bot messages (`bot-msg` skill script, recipient chip, thread sheet, arrival line + badge, Activity list, ⌘K) | merged (cf348cb, 868 green x2) | shipped in 0.5.0; live check: install the skill, then Jarvis → Infra |
| P35 Connecting a box adds every bot (discovery, derived-key adoption with backups + undo, never re-key `default`, not-connected section, sample bots removed; manager skill 1.0.2) | merged (74b0270, 889 green x2; 849 x3 on a quiet Mac) | shipped in 0.5.0; live: Settings → Add all bots from this box |
| P36 Agents report bugs/feature requests to SwarmHub | shipped in 0.5.1 (app 847e1e5; backend live since 2026-10-15 00:58, install keys; release self-test `--check-reports` from the notarized build: install ok, sent, listed) | Konrad: first real report from a bot; Claude triages with `swarmhub-reports` on the server |
| SwarmHub sign-in not configured in production | `/v1/auth/*` answer 503: SMTP, Google OAuth and Composio credentials were never set (found 2026-10-15) | Konrad runs `sudo python3 /home/ubuntu/swarmhub-backend/scripts/configure-composio-service.py` and types them at hidden prompts (optional; reports work without it) |
| P37 Reviewer bots for specific things or for all bots (routing lines per bot + global, review-after cards, rails unchanged) | shipped in 0.5.1 (merge 18a5bcb; 941 green x2; release 2374146 notarized, live e2e 9/9, feed + zip verified 2026-10-15) | gap: group-chat replies don't trigger reviews yet |
| P31 Coding agents (Claude Code via `claude -p`, Codex CLI), logins, sub-agent model, box capacity | A+B shipped in 0.5.0; C (Accounts/logins, code-job tightening, manager text on demand) shipped in 0.5.1 | D + E merged (coding model, box capacity; not released); test suite 62 s → 19–26 s merged 9b060e0; F live with Konrad for the logins |
| Test flakiness under load | 2026-10-15: with two Swift builds/tests running on the MacBook at once, `e2eFailsStepsTheServerDoesNotSupport` (timing `.fast`) and `aPlainThreadForksThenLocksToItsParentsRecordedLock` (WaitTimeout) failed once; green x3 when the Mac was quiet | make those waits load-tolerant; until then one Mac run at a time |
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
- **Commit identity (Konrad's approved attribution rewrite, 2026-10-14 10:40 UTC):** every commit in this repo is authored and
  committed as `Konrad Sierzputowski <8105013+conrader@users.noreply.github.com>` with no `Co-Authored-By` trailer. Main was
  force-rewritten to this (same trees, new hashes; backups `~/swarmhub-before-attribution-*.bundle`); branches made before it are
  replayed onto the new main, never merged across histories.
- **Ship through the updater:** a merged change reaches Konrad as a new notarized release (Developer ID, `plainsay-notary`,
  build number +1, appcast) that his installed app updates to; no hand-installs over his app once updates work.
- **Runs are short (Konrad 2026-10-15: "make sure that next runs are quicker").** In a build run: iterate with `swift test
  --filter <Suite>`, then ONE full `swift test` at the end; the verify pass's full run is the second green run (not two in
  the task plus one in verify). PNG renders only for screens the phase changes (`SWARMHUB_RENDER_TESTS=1` or the render
  flags), not the whole set. No side investigations in a run unless something is red; a brief that is decided, not open.
  One Mac test run at a time still holds. Target: a phase in ≤ 30 min, a release in ≤ 20 min.
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
| P12 | Connect OpenClaw (built on `p12`, unverified live) | `OpenClawBackend` over a shared Gateway link: WebSocket v4 handshake + Ed25519 device pairing, Settings → Servers and keys → OpenClaw, `--check-openclaw` (A); streaming chat, Stop, steer, history, reconnect resume, Add bots, editor bindings, banner, P17 model catalog (B); approvals (own runs by policy, others ask-only), threads, image attachments, Overview, docs (C) (`briefs/P12.md`, `docs/openclaw-integration.md`) | OpenClaw Gateway WS RPC |
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
