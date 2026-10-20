# DOCSITE1 report: README + Features page (draft)

Worktree `/home/ubuntu/work/swarmhub/wt-docsite1`, branch `swarmhub/docsite1` at `843024b`. Markdown only. Nothing was committed, pushed, deployed or published.

## Files changed

| File | Change |
|---|---|
| `docs/FEATURES.md` | New file (about 118 lines). The full feature list, with every item labelled **Released** (0.5.6) or **In development** (this branch only). |
| `README.md` | `## Features`: the 13 long bullets were replaced with 5 short ones, one "In development" line and a link to `docs/FEATURES.md`. The rest of the README is unchanged. |
| `DOCSITE1-REPORT.md` | This report (new). |

All relative links and `#anchors` in both files were checked with a script: none missing.

## Site and deploy mechanism

**There is no project website**, so I created `docs/FEATURES.md` as the brief specifies for this case.

- **In the repo:** no `site/`, `web/`, `www/` or `pages/` folder. No static-site config: `_config.yml`, mkdocs, docusaurus, astro, hugo, `netlify.toml`, `vercel.json`, `CNAME` and `package.json` are all absent. There is no `.github/` directory, so no deploy workflow. The only `.html` files are design prototypes (`docs/ios/screens.html`, `docs/ios/screenshots/contact-sheet.html`).
- **Branches:** no `gh-pages` branch, locally, in `pr.bundle`, or on GitHub. GitHub has `main`, `codex/swarmhub-team-coordination`, `swarmhub/macfix11` and `swarmhub/peer-delivery`.
- **GitHub (read-only API):** `conrader/swarmhub` has `has_pages: false` and `homepage: null`, and `/pages` returns 404.
- **What the project uses instead:** the README and `docs/*.md` rendered on GitHub, plus GitHub Releases. Sparkle updates use `scripts/generate-appcast.sh`, which builds an update feed, not a site.

## Base used for "released" vs "in development"

- `843024b` branches from `main` at `ed9c70a` ("PLAN: 0.5.6 published"). It is 70 commits ahead of `main` and 72 behind (GitHub compare). `Resources/Info.plist` here still says 0.5.6.
- **Released** means present at `ed9c70a` (0.5.6): in its README, in `docs/reference.md`, in PLAN.md "shipped in" rows, or in its code.
- **In development** means added in `ed9c70a..843024b`. None of that is merged or released.
- The latest public release is **0.5.9** (2026-10-16, from `main`). Its changes since 0.5.6 are **not on this branch**, and the page does not describe them; it says so and links to the release notes. Examples from main's commit titles: requests from the app are never ignored, accounts are named, voice errors are explained, the heartbeat state is shown. Merging this draft into `main` would need a pass to add them.

## Evidence used

- **Code:** `Sources/AgentApp/...` and `Resources/Skills/...` at HEAD and at `ed9c70a`.
- **Reports:** REMOTE-APPROVALS-REPORT, FIXES9/10, GAPS/GAPS3/GAPS4, PATTERNS/REVIEW-PATTERNS, LIVE-REPORT-9, REVIEW-CLAUDE-XREV, MACSMOKE1-REPORT and MACFIX11.
- **Docs and plan:** `sim/QA-MODE.md`, `docs/openclaw-integration.md`, `docs/hermes-versions.md`, `docs/reference.md`, PLAN.md.

Four read-only research agents gathered this. I re-read the key facts myself in the code: Draft Send is FAKE, the secret sheet text and its `~/.hermes/swarmhub/secrets` path, the remote-approvals status sentence, the heartbeat pane at `ed9c70a`, and the coding-skill sandbox text. A separate verifier then checked the draft against the code and reports.

## Claims marked uncertain or in development, with reasons

- **Managed approvals, local and remote:** marked in development.
  - The remote side needs a box-side `swarmctl control serve` service and an nginx route. REMOTE-APPROVALS-REPORT says "No commit, Hermes modification, live deployment or real outbound action was performed" and "That deployment-level TLS/Keychain check remains unrun".
  - Only the Python service tests ran (Linux, 11/11). The Swift `ManagedRemoteControl` tests and the cards have never been built on a Mac.
  - REVIEW-CLAUDE-XREV leaves "fixed in code, unproven end to end" items open.
  - The page says: not deployed, TLS/Keychain path untested, app side not built on a Mac.
- **Secure key sheet:** marked in development, not tested on a Mac (GAPS3-REPORT: "native approval-card/secret-sheet interaction remain untested").
  - I described what the code does: a 0600 file under `~/.hermes/swarmhub/secrets/`, the agent receives only the path, and the sheet opens only when an agent asks.
  - I added that the agent can still read the file, because it runs as the same account. Otherwise "never the value" could be read as a stronger promise than it is.
  - **Code note, not fixed (docs-only task):** the comments at `SecretEntrySheet.swift:3` and `ManagedActions.swift:148` say "Application Support", but the code writes to `~/.hermes/swarmhub/secrets`.
- **Draft Send:** marked in development, and **does not send anything**.
  - The code builds a managed outbound record with `fake: true` ("journaled and never sent", `ManagedActions.swift`). `AppStore+CardActions.swift` says "Outbound stays FAKE". It works for Hermes agents only.
  - In 0.5.6, Send posted "Send it" to the agent. The page describes both behaviours.
  - Not checked: the card may still look "sent" after Send, because its metadata records `draftSent`. I did not check the UI label.
- **OpenClaw:** listed as released, but "not yet checked against a real Gateway". `docs/openclaw-integration.md` says it was tested against a scripted fake Gateway only. The README's existing sentence was kept in meaning.
- **Goals and loops (in 0.5.6):** present in the code at `ed9c70a` (P45/P46 comments in `ChatAutomation.swift`), but never described in the docs and not found in PLAN.md's "shipped" rows. The page says this. The new evidence modes are marked in development, with a note that classifying from wording is heuristic (FIXES13-17 concerns).
- **Coding sandbox:** the `swarmhub-coding` 1.3.12 verification sandbox is marked in development.
  - The Linux suite is not green on the test host (MACSMOKE1-REPORT: 8 failures out of 426).
  - macOS acceptance is not recorded at or near HEAD. Earlier Mac runs were on older commits, and a later full run failed on a HOME/Library artifact.
- **Reviewer bots:** listed as released, with PLAN.md's open gap "group-chat replies don't trigger reviews yet".
- **Bot-to-bot messages:** released in 0.5.0 (PLAN P34).
  - Marked in development: held/priority delivery (`--held`/`--priority` and the "Held for" note are absent from `bot-msg` and `Sources` at `ed9c70a`; commit `d233afb` is after the base), completion wakes, and `NO_REPLY` as a quiet reply.
  - `[SILENT]` hiding is listed as released: `SilentReply.swift` at `ed9c70a`, P44.
  - Not traced: "survives an app restart" for completion wakes comes from the "durable completion wakes" commit title, not from tracing the code.
- **Verifier pass:** the separate verifier said held/priority delivery was already in 0.5.6. I re-checked: the 0.5.6 `bot-msg` has no `--held`/`--priority`, so the "In development" label stays. Its point about quiet replies was partly right, and I changed the page to match: `[SILENT]` is released, `NO_REPLY` is new. The two report-based caveats it could not trace check out: MACSMOKE1-REPORT's "Full discovery is **not green**" (around line 396) and PLAN.md P37's "gap: group-chat replies don't trigger reviews yet".

## Left out, with reasons

- **QA mode** (`sim/QA-MODE.md`, `Sources/AgentApp/QA/`): left out. It is developer-only: `#if DEBUG`, off by default, enabled with `SWARMHUB_QA_MODE=1` through `scripts/run-qa.sh`. Its live operation is also still blocked without a real Hermes QA gateway.
- **Sim/peer-review harness, verify-sandbox internals, MACSMOKE/DARWINKILL/FIXES test work:** left out. This is tooling and QA, not product. It appears only as the one coding-sandbox line.
- **Connected apps (Composio) and voice:** left out. Their status is unclear from this branch. PLAN.md says connected apps need the backend sign-in and Composio configured in production, and that voice has "not yet [been] tried live". Releases 0.5.7–0.5.9 on `main` changed both, and those changes are not on this branch. Better described from `main`.
- **Agents reporting bugs to SwarmHub (P36):** left out. It depends on a server backend whose production state I did not check.
- **Team coordination:** not added to the Features page. The README's existing section says it lives on `codex/swarmhub-team-coordination`, and I left that section unchanged.
- **Sample agents' "working draft and choice cards"** detail: shortened. I did not re-check it at HEAD.

## Not verified

- The Swift app was not built or run. Every "In development" app-side behaviour is described from source and reports, not from the running app.
- Statements labelled released were checked against code, docs and PLAN at `ed9c70a`, not against the notarized 0.5.6 build.
- How the pages render on GitHub was not previewed. Only the links and anchors were checked, with a script.
