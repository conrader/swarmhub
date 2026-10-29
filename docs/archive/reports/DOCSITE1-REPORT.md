# DOCSITE1 report: README + Features page (draft)

Original docsite1 pass: worktree `/home/ubuntu/work/swarmhub/wt-docsite1`, branch `swarmhub/docsite1` at `843024b`. Markdown only; that pass made no commit, push, deployment or publication. The lead subsequently committed the draft as `5b4573d`. Corrections below and the appended [docsite2 section](#docsite2) describe the docs-only follow-up.

## Files changed

| File | Change |
|---|---|
| `docs/FEATURES.md` | New feature page in docsite1; docsite2 extends **Released** coverage through 0.5.9 and corrects Mac validation wording. |
| `README.md` | Docsite1 shortened the feature list to 5 bullets and linked to `docs/FEATURES.md`; docsite2 uses 6 short bullets, adds release versions and clarifies Mac validation and branch scope. The rest of the README is unchanged. |
| `DOCSITE1-REPORT.md` | This report (new). |

All relative links and `#anchors` in both files were checked with a script: none missing.

## Site and deploy mechanism

**There is no project website**, so I created `docs/FEATURES.md` as the brief specifies for this case.

- **In the repo:** no `site/`, `web/`, `www/` or `pages/` folder. No static-site config: `_config.yml`, mkdocs, docusaurus, astro, hugo, `netlify.toml`, `vercel.json`, `CNAME` and `package.json` are all absent. There is no `.github/` directory, so no deploy workflow. The only `.html` files are design prototypes (`docs/ios/screens.html`, `docs/ios/screenshots/contact-sheet.html`).
- **Branches:** no `gh-pages` branch, locally, in `pr.bundle`, or on GitHub. GitHub has `main`, `codex/swarmhub-team-coordination`, `swarmhub/macfix11` and `swarmhub/peer-delivery`.
- **GitHub (read-only API):** `conrader/swarmhub` has `has_pages: false` and `homepage: null`, and `/pages` returns 404.
- **What the project uses instead:** the README and `docs/*.md` rendered on GitHub, plus GitHub Releases. Sparkle updates use `scripts/generate-appcast.sh`, which builds an update feed, not a site.

## Base used for "released" vs "in development"

- `843024b` branches from `main` at `ed9c70a` ("PLAN: 0.5.6 published"). At docsite2, `HEAD` (`5b4573d`) is 71 commits ahead of fetched `gh/main` (`5dba61a`) and 72 behind. `Resources/Info.plist` here still says 0.5.6.
- **Released** without a version means present in 0.5.6. Docsite2 also checks `v0.5.6..v0.5.9` and labels later additions with the version that shipped them.
- **In development** describes the branch additions in `ed9c70a..843024b` that are absent from the checked releases and fetched `main`.
- **0.5.9** (2026-10-16) is the latest release in the fetched refs. The page now covers 0.5.7–0.5.9, using their tagged code and PLAN entries. Those release changes are still absent from this branch's code; the page states that distinction. `v0.5.9..gh/main` changes only PLAN.md.

## Evidence used

- **Code:** `Sources/AgentApp/...` and `Resources/Skills/...` at HEAD and at `ed9c70a`.
- **Reports:** REMOTE-APPROVALS-REPORT, FIXES9/10, GAPS/GAPS3/GAPS4, PATTERNS/REVIEW-PATTERNS, LIVE-REPORT-9, REVIEW-CLAUDE-XREV, MACSMOKE1-REPORT and MACFIX11.
- **Docs and plan:** `sim/QA-MODE.md`, `docs/openclaw-integration.md`, `docs/hermes-versions.md`, `docs/reference.md`, PLAN.md.

Four read-only research agents gathered this. I re-read the key facts myself in the code: Draft Send is FAKE, the secret sheet text and its `~/.hermes/swarmhub/secrets` path, the remote-approvals status sentence, the heartbeat pane at `ed9c70a`, and the coding-skill sandbox text. A separate verifier then checked the draft against the code and reports.

## Claims marked uncertain or in development, with reasons

- **Managed approvals, local and remote:** marked in development.
  - The remote side needs a box-side `swarmctl control serve` service and an nginx route. REMOTE-APPROVALS-REPORT says "No commit, Hermes modification, live deployment or real outbound action was performed" and "That deployment-level TLS/Keychain check remains unrun".
  - The Python service tests ran on Linux (11/11 in REMOTE-APPROVALS-REPORT). The Swift app also builds and its automated tests pass on a Mac: REVIEW-CLAUDE-XREV3 records a green MacBook run at `78e73df`, and the docsite2 brief reports later full Swift runs on this branch line (about 1,362 tests in 30 suites, including `ManagedRemoteControlTests`). Native card interactions have not yet been hand-tested.
  - REVIEW-CLAUDE-XREV leaves "fixed in code, unproven end to end" items open.
  - The page says: Swift builds and automated tests pass on a Mac; native local and remote approval cards are not yet hand-tested; the remote service is not deployed and the real TLS/Keychain path remains untested.
- **Secure key sheet:** marked in development. Swift builds and automated tests pass on a Mac; native key-sheet interaction has not yet been hand-tested (GAPS3-REPORT's interaction caveat still applies).
  - I described what the code does: a 0600 file under `~/.hermes/swarmhub/secrets/`, the agent receives only the path, and the sheet opens only when an agent asks.
  - I added that the agent can still read the file, because it runs as the same account. Otherwise "never the value" could be read as a stronger promise than it is.
  - **Code note, not fixed (docs-only task):** the comments at `SecretEntrySheet.swift:3` and `ManagedActions.swift:148` say "Application Support", but the code writes to `~/.hermes/swarmhub/secrets`.
- **Draft Send:** marked in development, and **does not send anything**.
  - The code builds a managed outbound record with `fake: true` ("journaled and never sent", `ManagedActions.swift`). `AppStore+CardActions.swift` says "Outbound stays FAKE". It works for Hermes agents only.
  - Releases 0.5.6 through 0.5.9 post "Send it" to the agent. The page describes both behaviours. Swift builds and automated tests pass on a Mac; native Draft Send interaction has not yet been hand-tested.
  - Not checked: the card may still look "sent" after Send, because its metadata records `draftSent`. I did not check the UI label.
- **OpenClaw:** listed as released, but "not yet checked against a real Gateway". `docs/openclaw-integration.md` says it was tested against a scripted fake Gateway only. The README's existing sentence was kept in meaning.
- **Goals and loops (in 0.5.6):** present in the code at `ed9c70a` (P45/P46 comments in `ChatAutomation.swift`), but never described in the docs and not found in PLAN.md's "shipped" rows. The page says this. The new evidence modes are marked in development, with a note that classifying from wording is heuristic (FIXES13-17 concerns).
- **Coding sandbox:** the `swarmhub-coding` 1.3.12 verification sandbox is marked in development.
  - The Linux suite is not green on the test host (MACSMOKE1-REPORT: 8 failures out of 426).
  - The green Mac Swift runs do not establish acceptance of the separate native sandbox or real coding-tool smoke checks. The earlier HOME/Library artifact failure in MACSMOKE1-REPORT concerns that smoke work, not evidence that Swift has never built or passed on a Mac.
- **Reviewer bots:** listed as released, with PLAN.md's open gap "group-chat replies don't trigger reviews yet".
- **Bot-to-bot messages:** released in 0.5.0 (PLAN P34).
  - Marked in development: held/priority delivery (`--held`/`--priority` and the "Held for" note are absent from `bot-msg` and `Sources` at `ed9c70a`; commit `d233afb` is after the base), completion wakes, and `NO_REPLY` as a quiet reply.
  - `[SILENT]` hiding is listed as released: `SilentReply.swift` at `ed9c70a`, P44.
  - Not traced: "survives an app restart" for completion wakes comes from the "durable completion wakes" commit title, not from tracing the code.
- **Verifier pass:** the separate verifier said held/priority delivery was already in 0.5.6. I re-checked: the 0.5.6 `bot-msg` has no `--held`/`--priority`, so the "In development" label stays. Its point about quiet replies was partly right, and I changed the page to match: `[SILENT]` is released, `NO_REPLY` is new. The two report-based caveats it could not trace check out: MACSMOKE1-REPORT's "Full discovery is **not green**" (around line 396) and PLAN.md P37's "gap: group-chat replies don't trigger reviews yet".

## Left out, with reasons

- **QA mode** (`sim/QA-MODE.md`, `Sources/AgentApp/QA/`): left out. It is developer-only: `#if DEBUG`, off by default, enabled with `SWARMHUB_QA_MODE=1` through `scripts/run-qa.sh`. Its live operation is also still blocked without a real Hermes QA gateway.
- **Sim/peer-review harness, verify-sandbox internals, MACSMOKE/DARWINKILL/FIXES test work:** left out. This is tooling and QA, not product. It appears only as the one coding-sandbox line.
- **Connected apps (Composio) and voice:** omitted in docsite1; docsite2 adds the confirmed 0.5.8–0.5.9 improvements from tagged code and fetched main's PLAN. Service configuration is still required, and readable voice failures are not evidence of successful live-voice acceptance.
- **Agents reporting bugs to SwarmHub (P36):** left out. It depends on a server backend whose production state I did not check.
- **Team coordination:** not added to the Features page. The README's existing section says it lives on `codex/swarmhub-team-coordination`, and I left that section unchanged.
- **Sample agents' "working draft and choice cards"** detail: shortened. I did not re-check it at HEAD.

## Not verified

- Neither documentation pass built or ran the Swift app locally. Existing Mac build/test evidence is recorded above; the native approval cards, remote-approval cards, key sheet and Draft Send have not yet been hand-tested, and no real remote-approvals service has been deployed.
- Released statements were checked against source, docs and PLAN: docsite1 used `ed9c70a`; docsite2 also checked tags through `v0.5.9` and fetched `gh/main`. Neither pass exercised the notarized builds.
- How the pages render on GitHub was not previewed. Only the links and anchors were checked, with a script.

## docsite2

Docs-only correction of `5b4573d` in the same worktree. Changed only README.md, docs/FEATURES.md and this report. No code changes, commit, push or publication.

### Corrections and evidence

| Correction | Evidence |
|---|---|
| Replaced the blanket claim that development Swift had not built or tested on a Mac. The legend, approvals, key sheet, Draft Send, README and report now separate passing automated checks from outstanding native UI checks. | [REVIEW-CLAUDE-XREV3.md](../reviews/REVIEW-CLAUDE-XREV3.md#what-i-ran-linux-python-312-git-243-binsh--dash) explicitly records a green MacBook Swift run at `78e73df`. The user's docsite2 brief supplies the later branch-line results: approximately 1,362 tests in 30 suites, including `ManagedRemoteControlTests`. No later exact SHA or raw log was supplied, so this report does not claim a new run at docsite2 HEAD. |
| Kept the remote deployment and native interaction caveats. | [REMOTE-APPROVALS-REPORT.md](REMOTE-APPROVALS-REPORT.md) records no live deployment and leaves the deployment-level TLS/Keychain check unrun. [GAPS3-REPORT.md](GAPS3-REPORT.md) distinguishes native approval-card/secret-sheet interaction from source/test work. The docsite2 brief confirms no manual native UI pass or real remote-approvals deployment. |
| Added **Released in 0.5.7**: saved chat/group/thread reading positions and Jump to latest; folded technical rows; uncertain-send recovery and stricter Retry; narrower automatic approvals. | `v0.5.7` → `3b6ce9f`; `git log/show/diff v0.5.6..v0.5.7`; main's PLAN P50/P51 publication row. Tagged implementations: `ChatScroll.swift`, `ChatScrollViews.swift`, `TechnicalRow.swift`, `FoldedRowView.swift`, `Models.swift` (`ApprovalRule`), `AppStore+Approvals.swift`, `AppStore+QueueRecovery.swift`, `AppStore+Retry.swift`; tagged `docs/reference.md` retains the residual duplicate-send caveat. |
| Added **Released in 0.5.8**: clearly read-only connected-app actions run without a card; writes, uncertain actions and potentially outbound reads still ask; app failures return to the bot so work/goals can continue. | `v0.5.8` → `1263f12`; `git log/show/diff v0.5.7..v0.5.8`; main's PLAN P52 publication row; tagged `AppToolAccess.swift`, `ConnectedAppsChat.swift`, `AppFailureShape.swift` and `AppRequestFailure.swift`. This documents the implemented classification, not a guarantee that every read is harmless. |
| Added **Released in 0.5.9**: identity-based account names, bounded stale-request recovery, visible unrun requests, readable persistent voice errors, heartbeat context and explicit handling of schedules changed on the box. | `v0.5.9` → `6409d75`; `git log/show/diff v0.5.8..v0.5.9`; main's PLAN P53–P56 and release publication rows. Tagged implementations: `AccountProfileName.swift`, `AppRequestMarker.swift`, `ConnectedAppsChat.swift`, `TechnicalApps.swift`, `LiveVoiceFailure.swift`, `VoiceChatView.swift`, `AppStore+HeartbeatContext.swift`, `SettingsHeartbeatPane.swift`, and `swarmhub-manager` 1.3.0. The PLAN still leaves a live-voice check outstanding. |
| Replaced the note saying the page omits 0.5.7–0.5.9; retained the distinction between release coverage and branch code. Kept README's overview short and linked to the full feature page. | Local refs `v0.5.6`–`v0.5.9` and `refs/remotes/gh/main` at `5dba61a`; merge base `ed9c70a`; `git diff --name-only v0.5.9..gh/main` lists only PLAN.md. |

### Branch differences to preserve when integrating with main

- **Draft Send:** `v0.5.9:Sources/AgentApp/Stores/AppStore+CardActions.swift` still sends the agent "Send it". This branch replaces that with a Hermes-only `ManagedOutbound` instruction whose record is FAKE. The feature page now describes both; the branch behavior must not be presented as released.
- **Approval and recovery behavior:** `git diff v0.5.9..HEAD` shows this branch lacks main's `reviewerMustEscalate` guard in the automatic-approve route, P52's read-only app bypass, the `submitting`/`uncertain` queue recovery states, and the stricter Retry history check. Its managed-approval additions share these areas with main's release fixes. The 0.5.7/0.5.8 descriptions apply to tagged releases, not this checkout.
- **Heartbeat and other release additions:** this branch has `swarmhub-manager` 1.2.0, while 0.5.9 ships 1.3.0 with heartbeat guidance; P50–P56's later UI/context work is also absent here. The branch's PLAN and technical reference still reflect older behavior. Only the three requested Markdown files were corrected; no merge was attempted.

### Validation

- All 44 local Markdown links, image paths, HTML `src`/`srcset` paths and heading-anchor targets in the three edited files resolve against this checkout.
- Ran `git diff --check` and confirmed the changed-file list contains only the three requested Markdown files. No Swift tests were rerun for this documentation-only change.
- External-link verification is incomplete: this host could not resolve `github.com`. A browser-tool fallback fetched the releases index, but its cached page did not expose the releases; the latest-release URL and pinned BotAvatarsKit URL returned cache misses. Those existing URLs were retained, and release claims use the fetched Git refs rather than that cached page.
