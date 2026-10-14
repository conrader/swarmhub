# SwarmHub iOS specsheet

Version 0.1 · 14 October 2026 · Status: specification and screen design

SwarmHub for iPhone gives the owner access to the same agents, conversations, scheduled work, approvals, and remote computers as desktop. Agents run on the user's server. The phone manages work and presents results; it does not host the agent or a model. The feature target includes the existing desktop surface and Grok Bot-style workflows, with explicit backend work for features the current adapters cannot provide.

Android is also in development. This specification defines its eventual feature and data contract; the first native implementation is iOS.

## Product decisions

| Item | Proposed decision |
| --- | --- |
| App name | SwarmHub; retain the existing brand and original assets |
| First platform | Native iPhone app, SwiftUI, proposed minimum iOS 18; confirm the final deployment target during the Xcode scaffold |
| Other mobile platform | Native Android follows the same backend contract and feature acceptance criteria |
| Main navigation | Chats, Approvals, Settings; badges count unread conversations and actionable approval requests |
| Agent navigation | Tap the agent name in chat for Overview, Routines, Media, Computer, and group membership |
| First connection | Connect an existing Hermes server with address and key, test, then select successfully probed profiles |
| Initial backend | Hermes; OpenClaw connection remains unavailable until its authenticated transport is implemented |
| Appearance | Dark default; Light and System; existing accent choices and avatar motion preferences |
| Identity | Local display name; server/profile credentials in Keychain; no invented workspace sign-in |
| Hosting | A clearly labelled coming-soon screen; no provisioning or billing flow in this milestone |
| Sync | Server sessions and jobs are authoritative; local read/unread, reactions, groups, and appearance require a separate shared metadata service for cross-device sync |
| Mobile distribution | TestFlight during development; App Store updates replace desktop Sparkle |

The drawings use synthetic agents Atlas, Mira, Patch, and Scout. They show proposed mobile behavior, including features awaiting server support. Their controls only change the local preview.

## Feature coverage

**Adapt** means the desktop feature has an implementation to reuse or port, not that it already works on iOS. **Extend** requires additional mobile, shared, or backend implementation. **Blocked** identifies a required server contract that has not been established. Every row remains part of the target scope.

| Feature | iOS behavior | Work required | Drawings |
| --- | --- | --- | --- |
| Connect and discover | Address, secure key, explicit Test, choose verified profiles; add additional profile keys in Advanced | Adapt; preserve profile-isolation checks; key-only setup may discover only the default profile | S01–S03, S21 |
| Managed setup | Explain hosted setup availability and return to existing-server setup | Blocked: hosting service deferred | S36 |
| Agent roster | Avatar, two-line preview, unread, muted/hidden state, running/waiting state | Adapt | S04 |
| Search and quick switching | Find agents/groups, then cached messages, files, and routines; clearly label local results | Extend: local full-text index; server search only if advertised | S35 |
| Roster organization | Pin agents and arrange sections; hidden agents restored without stopping routines | Extend: local metadata first, shared metadata sync later | S04, S10 |
| Agent editing | Name, mark, description, instructions, notification toggle, Advanced settings | Adapt; editing local instructions never silently writes server SOUL | S09–S10 |
| Agent management | Ask the designated manager to create agents, show/change server instructions, change marks or retire an agent; review changes in chat | Adapt stock-Hermes management turns and result parsing; attach guidance only on demand; derive/probe new profile keys before adding | S10, S37 |
| Duplicate and share | Duplicate configuration without history/memory/credentials; export a sanitized template via share sheet | Extend; copied routines disabled; no public template-hosting promise | S10, S26–S27 |
| Streaming chat | User bubbles, plain assistant text, Markdown, code/copy, tool activity, selectable text | Adapt | S05 |
| Stop and steer | Stop shows pending acknowledgment; type guidance during a run only with steer support | Adapt plus reliable run reconciliation | S05, S30 |
| Quote and threaded replies | Long press offers Reply, Reply in thread, Copy, React; back returns to parent message | Adapt; Hermes fork includes the current full transcript, not a fork at the selected message | S06 |
| Reactions | Persist tapbacks locally; distinguish a reaction from an approval decision | Adapt; cross-device reactions need metadata sync | S05–S06 |
| Interactive cards | Question options, link pills, file cards, routine results, drafts with Copy and Send | Adapt; Send instructs the agent and remains subject to policy | S05, S14, S17 |
| Attachments | Photos, camera, Files, clipboard, extraction preview, rejection reasons, attachment removal | Port desktop images/text/PDF/OCR and documents; replace AppKit readers with verified iOS equivalents | S31, S13–S14 |
| Voice memos | Record/cancel/review, playback and transcript; ask for microphone access only when recording | Extend: transcription/upload contract; no audio payload until supported | S32 |
| Audio and video files | Preview supported files; send only with a reported server media contract, otherwise explain the limit | Blocked for direct server payloads; optional on-device extraction needs a separate implementation | S31–S32 |
| Groups and mentions | Multiple named agents, @mention picker, sequential responses, per-agent Stop/approval | Adapt; do not describe current routing as autonomous parallel collaboration | S07–S08 |
| Members | Add/remove agents, rename group, keep prior sessions; owner display name | Adapt; shared human workspaces are a later service | S08 |
| Handoffs and sub-agents | Agent attribution, task status, transcript drill-down only when available | Extend: current Hermes stream does not supply a complete child-task contract | S29 |
| Agent overview | Identity, memory summary, real skills, tools, available model and approval policy | Adapt; memory is read-only unless a supported write route exists | S09 |
| Slash commands | Search advertised skills with `/`; insert or invoke only the backend's documented command form | Extend: invocation contract; do not treat an installed skill list as callable API support | S05, S09, S34 |
| Teach a workflow | Start demonstration, watch/control computer, review a saved skill, schedule it | Blocked: demonstration recording and skill-write service | S34 |
| Routine management | List, create/edit, presets, advanced cron, pause/resume, run now, delete, run history | Adapt | S11–S12 |
| Routine timing | Show timezone, next run and explicit DST behavior; execution stays on the server | Extend: validate the backend's timezone handling before enabling edits | S12 |
| Event routines | Webhook/app triggers alongside schedules, with trigger source and pause state | Blocked: event-trigger contract absent from current adapter | S12, S33 |
| Routine completion | Result card in the originating agent chat, deduplicate by job/run id, mark unread | Adapt foreground fetch; extend push delivery | S05, S11 |
| Media | Images, files and links from main chat and threads; filter, preview, jump to source, share/save | Adapt plus native previews | S13–S14 |
| Remote computer | Configured HTTPS desktop in WKWebView, connection status, keyboard, landscape, browser fallback | Adapt and verify provider touch/keyboard support | S15 |
| Take over | Explicit request and confirmed control state; stop control returns to watch mode when supported | Extend: current desktop page owns watch/control; no fake control acknowledgment | S15 |
| Computer administration | Recover/restart/reset only when the server exposes supported controls | Blocked: no current management API; never simulate success | S15 |
| Approval inbox | Pending requests across profiles, agent attribution, command/destination, detail and decision | Extend: reconnectable pending-request contract and shared decision consistency | S16–S17 |
| Approval policies | Ask me default; advanced rules and reviewer choices, fallback to manual review on ambiguity | Adapt; automatic policies must execute on the server for background parity | S18 |
| Approval audit | Decision, actor, agent, time, outcome; never display secrets from a raw command | Adapt local audit; shared server audit needed for multi-device history | S19 |
| Per-agent models | Conversation default and current chat model from the selected agent's own catalog | Adapt; model switches require advertised support and readback | S22 |
| Coding models | Coding-thread model and sub-agent model presented with capability/state labels | Blocked until coding threads and configuration APIs exist | S22, S29 |
| Connected apps | SwarmHub-managed Composio connections, per-agent access, app actions reviewed in chat, explicit connect/revoke status | Port the desktop integration being developed; add a verified mobile auth-return flow and grant enforcement; closed-app execution needs a companion executor | S33 |
| Grok import | Files-based bundle or sanitized template import, explicit preview, searchable read-only archive | Adapt parsers; iOS cannot read another desktop app's cache/Keychain | S26–S28 |
| Cross-device history | Same canonical session id on Mac and phone; replay after interruptions, merge by message/event id | Extend: shared conversation binding and stable run/event identifiers | S05, S30 |
| Offline mode | Cached histories and locally saved drafts; explicit unsent state; reconcile before retry | Extend; no automatic blind resend | S30 |
| Notifications | Reply ready, approval waiting, routine finished; deep link to originating item, per-agent mute | Extend: APNs relay plus enrollment/removal APIs; opt-in and generic lock-screen text | S24 |
| Settings | Simple connection/name/appearance/notifications/about; Advanced for servers, models, policies, usage and imports | Adapt design from proposed simple settings | S20–S25 |
| Usage | Load server-reported token/message totals by period/profile; incomplete profiles shown separately | Adapt; no invented prices or billing | S25 |
| App updates and credits | Version, TestFlight/App Store link when available, licenses and avatar credit | Extend mobile distribution; no Sparkle on iOS | S20 |
| Accessibility | Dynamic Type, VoiceOver, contrast, large hit targets, Reduce Motion, hardware keyboard | Native implementation requirement | All |
| Android parity | Same capabilities, error semantics, jobs and session identifiers; Android-specific navigation, storage, notifications and OAuth | Separate native implementation and FCM relay | Same contract |

## Navigation and interaction

Chats is the landing tab. A prominent search field and plus menu provide agent/group creation, import and hidden agents. The list remains useful with one agent or dozens; avoid a dashboard ahead of conversations. A row opens a full-screen chat. The main tab bar is hidden while reading a conversation so the bottom remains dedicated to the composer.

The chat header shows Back, the agent or group identity, and overflow. Tapping the name opens agent details or Members. Agent details holds the former desktop inspector: Overview, Routines, Media and Computer. Deeper lists use native push navigation. Editing, attachments, model choices and approval details use sheets where a short choice can return directly to chat. Large text editors and remote computer views use full-screen destinations.

Approvals is a global inbox, and each request also appears in its chat. A badge includes only unresolved actionable requests, not display-only events. A decision has the states pending, submitting, accepted, rejected, already resolved, expired and delivery uncertain. A tap cannot immediately imply acceptance; update the card after acknowledgment or authoritative readback. Notifications open the request in context and never approve from the lock screen in the first release.

Settings opens a short page: connection, display name, appearance, notifications and About. Technical choices live under Advanced. Unavailable controls state a reason rather than inventing a successful result. The drawings include connected, running, approval waiting, read-only, offline and future-service states; native implementation must add all loading, empty, authentication and accessibility variants.

## Primary journeys

1. **Connect:** Welcome → Connect → read-only Test → Choose agents → Add → Chats. Cancel never saves the temporary key. A failed profile check cannot silently route to the default profile. OpenClaw and hosted setup remain labelled unavailable.
2. **Assign work:** Chats → Chat → attach context → preview conversion → Send → stream → completed result. Long press opens reply/reaction actions. While running, Stop is always present when the backend supports it; guidance uses steer only when advertised.
3. **Resume work:** Reopen app → reconcile canonical session/run → show completed result or still-running state. If delivery is uncertain, check the server before offering Retry. Closing the phone cannot be treated as agent completion or cancellation.
4. **Review an action:** Approval tab or push → Approval detail → inspect action/context → approve/decline → wait for acknowledgment → update inbox, chat and audit together. A request already decided on desktop becomes a resolved receipt.
5. **Schedule:** Agent details → Routines → New routine → description, schedule, timezone → validate next runs → Save paused → enable after review → completion in chat. Imported jobs always start paused.
6. **Coordinate:** New group → select agents → Chat → @mention → attributed replies → Members. Removing an agent keeps its previous messages and group session history.
7. **Use the computer:** Details → Computer → connect → watch → request control if supported → use keyboard/landscape → return to chat. A missing control API opens the provider page without asserting a separate SwarmHub control state.
8. **Import:** Files or share link → decode/sanitize → preview mapped/skipped/unsupported data → confirm → idempotent import → archive or new agent. No credentials, connector permissions or active routines are imported.
9. **Extend workflows:** Overview → Skills/Connected apps/Teach. Unsupported operations show the required server capability and cannot start a login, grant access, record a demonstration or provision a profile.

## Mobile architecture

Build the native iOS application beside the existing macOS application. First extract a Foundation-only shared Swift package instead of importing the macOS executable target, which currently depends on AppKit, desktop notifications, web windows and Sparkle. Android shares the wire contract and fixtures; it does not import Swift-only application code.

| Component | Responsibility |
| --- | --- |
| `SwarmHubCore` proposed package | Domain types, capability catalog, backend-neutral interfaces, event parsing, group routing, import sanitizing, model resolution and routine parsing |
| `SwarmHubIOS` proposed Xcode target | SwiftUI navigation, scenes, system sheets, image/file/camera selection, accessibility, lifecycle, notification handling |
| Hermes adapter | Authenticated URLSession sessions/SSE, canonical transcript readback, model/jobs/approval routes; preserve compatibility fallback |
| OpenClaw adapter | Authenticated WebSocket RPC behind the existing adapter boundary, enabled only after transport tests pass |
| Repository actor | SQLite records and full-text index, stable identifiers, paged histories and transactions; attachment files stored separately |
| Credential store | iOS Keychain, server/profile scoped; injectable in-memory store for previews; never synchronize keys through general metadata |
| Sync coordinator | Foreground reconnect, replay/cursor handling, conflict-aware merges and pending-delivery reconciliation |
| Notification relay required | Server receives job/run/approval events and dispatches APNs; authenticated device enrollment and revoke; FCM equivalent for Android |
| Metadata service required | Cross-device agent/group bindings, preferences, unread markers, reactions and organization; revision/conflict policy |
| Connected-app adapter | Port SwarmHub's Composio boundary; system authentication session/provider return, scoped per-agent grants, token storage at the broker, execution approval and revoke |

Existing `AgentBackend`, Hermes transport, model/jobs clients, domain types, bot-management parser/key derivation and import pipeline are candidates for extraction. Audit imports and AppKit-bound image/clipboard/Keychain/document helpers before moving them. Keep the macOS build working throughout; mobile features must not silently change existing stores or key-service names.

Keep Hermes stock: no patches, custom routes or mandatory skills installed on the agent server. Notification delivery and shared metadata are separate SwarmHub companion-service contracts rather than assumed Hermes APIs. An optional relay can observe supported stock history/run/job endpoints; its event source and hosting must be designed explicitly. Connected-app authentication and provider tokens stay with the integration broker, while the Composio project credential stays in the client Keychain and out of agent prompts. Core foreground chat and manual management must work without companion services. Agent management reuses the existing on-demand manager conversation instead of requiring a new profile-write API.

### Contract and synchronization requirements

- Authenticate each profile separately and cache capabilities by normalized server/profile. Validate both advertised support and route behavior. Never select features by server version alone.
- Bind each agent's conversation to a shared canonical session. Current install-local main/group/thread identifiers are insufficient for transparent Mac/phone continuity; establish a server-side binding or import an explicit session reference before claiming sync.
- Identify messages, events, jobs, job runs, approvals and child sessions with stable server IDs. If an API lacks one, define the adapter's deduplication behavior and test replay; do not match messages only by text.
- Persist the outgoing draft, delivery state and server run identifier before rendering a turn as accepted. Use idempotency keys only when the server honors them; otherwise read back before a retry and expose unresolved ambiguity.
- Server history wins for assistant outputs and run completion. Keep edits, quoted parents, thread relationships and attachments when merging; do not overwrite a canonical transcript with a local snapshot.
- Foreground streams use reconnect with bounded backoff. Persist a supported cursor or replay and deduplicate; explicitly fetch the transcript/run status if stream resumption is not supported.
- Treat each group member's run separately. Keep the desktop's sequential routing initially. Inter-agent autonomous handoff/parallel work requires a server orchestrator, not a live iPhone connection.
- Store unread/read watermarks and reaction changes as metadata revisions; conflict resolution follows explicit per-field rules. Local-only data must be labelled as such until the metadata service exists.
- The approval authority must decide once across devices. A stale request cannot be approved; on timeout read the authoritative state before retry. Background reviewer/rule execution belongs on the server because a suspended phone cannot reliably review requests.
- Routines execute on the server. Validate cron, server timezone and daylight-saving behavior; display the next three server-derived run times before enabling a new schedule. Event triggers remain gated until documented.
- Computer watch/control semantics come from its provider. Use a verified origin, explicit control ownership/lease when available, and release control on exit; fall back to the provider's UI when a SwarmHub-specific lease does not exist.

### Background behavior

Agent execution and scheduled jobs continue on the server. iOS may suspend the client; a long-lived SSE connection or timer is not a delivery strategy while the app is closed. On foreground, reconcile server history and active runs. APNs is a notification channel, not the source of truth, and background pushes may be delayed or absent. The initial foreground-only milestone must explicitly say notifications while closed are unavailable until the relay ships. These lifecycle choices follow Apple's [background strategies](https://developer.apple.com/documentation/backgroundtasks/choosing-background-strategies-for-your-app) and [background push guidance](https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app).

Use a proposed `swarmhub://` deep-link router for agent/session/thread/job/approval IDs, validating all identifiers against configured profiles. Universal links require a later owned-domain association. Push payloads carry identifiers and generic display text, with chat content fetched after authentication. Do not put server keys, approval commands or message bodies in notification payloads by default.

### Storage and privacy

Keys live in Keychain and are saved only after confirmed setup. Require HTTPS for remote servers; an iPhone's localhost is the phone, not the user's Mac. A local-network connection needs an explicit supported networking policy and permission, not a global App Transport Security exception. Preview only trusted desktop origins and never persist token-bearing URLs in the normal settings store.

Use file protection for the cache and extracted attachments, redact secrets from logs/errors/import previews, and expose removal of local downloaded data separately from deleting a server session or agent. Disconnect revokes notification enrollment when reachable and clears the local key even when offline. A failed remote revoke remains visible for later retry.

Images initially follow the desktop envelope: longest edge at most 2048 px and encoded image data URL at most 5 MB. Port the desktop's text-part splitting so no outgoing part crosses its verified transport limit; never silently truncate. Port PDFKit text extraction, Vision OCR and visible document limits from the shipped desktop document reader, replacing AppKit-dependent RTF/DOC/DOCX readers with verified iOS equivalents. Preserve explicit truncation notices when a document limit is reached. Audio/video support needs a deliberate extraction or server media contract; a native preview alone does not establish agent ingestion.

## Screen inventory

The [screen map](screen-map.md) gives full descriptions and links. Stable screen identifiers match the interactive drawing registry.

| Group | Screens |
| --- | --- |
| Setup | S01 Welcome, S02 Connect, S03 Choose agents, S36 Hosted setup |
| Conversations | S04 Chats, S05 Agent chat, S06 Thread, S07 Group chat, S08 Members, S30 Recovery, S31 Attachments, S32 Voice memo, S35 Search |
| Agent | S09 Overview, S10 Edit agent, S29 Delegated work, S33 Connected apps, S34 Teach workflow, S37 Manage agents |
| Work | S11 Routines, S12 Routine editor, S13 Media, S14 File preview, S15 Computer |
| Review | S16 Approval inbox, S17 Approval detail, S18 Policies, S19 Audit |
| Settings | S20 Simple settings, S21 Servers, S22 Models, S23 Appearance, S24 Notifications, S25 Usage |
| Import | S26 Import source, S27 Import preview, S28 Read-only archive |

## Design system

Use the system font and SF Symbols in the native app. Drawings use original vector symbols and geometric marks; never extract Grok Bot assets, strings, fonts or prompts. Native bot avatars can reuse the pinned MIT BotAvatarsKit after testing iOS compatibility and retaining its license credit.

| Element | Direction |
| --- | --- |
| Canvas | Dark chat `#141416`, panel `#19191C`, raised `#232327`; light counterparts follow existing `AppColor` |
| Primary action | Neutral graphite; agent colors identify agents rather than coloring every control |
| Typography | System text styles; approximately 34 pt large titles, 17 pt body, 15 pt secondary, 13 pt captions at the default size |
| Spacing | 4 pt rhythm, 20 pt horizontal content inset, at least 44 pt interactive targets |
| Conversation | Plain assistant paragraphs, restrained user bubbles, timestamps secondary, composer above keyboard/safe area |
| Rows | Marks about 40 pt, compact name/preview, quiet separators and unread indicators |
| Sheets | Opaque grouped surfaces, clear Cancel/Done, expand to full screen for large text and accessibility sizes |
| Motion | Native navigation plus existing avatar states; pause when inactive, honor Reduce Motion and avatar Off |
| Accessibility | Dynamic Type reflow, VoiceOver names/statuses, visible focus, labelled icon controls; color always paired with text |
| iPad | Later adaptive split navigation, retaining the iPhone flows; avoid assuming three desktop columns on a phone |

## Implementation milestones

| Milestone | Deliverable | Exit condition |
| --- | --- | --- |
| M0 Design, current | Spec, 37 editable drawings, parity map, README status | Screens and routes inspectable; future backend features clearly labelled |
| M1 Native foundation | Xcode iOS target, shared core extraction, Keychain, SQLite, setup, chat roster and read-only history | Simulator build; fake-server connection; no macOS regression; no production credentials in fixtures |
| M2 Reliable conversations | Streaming, Stop/steer, delivery reconciliation, threads, groups, attachments, cards, reactions, media and local search | Network loss/background/reopen tests preserve turns and prevent blind duplicate sends |
| M3 Manage work | Routines, models, computer view, manager-agent creation/instructions/retirement, manual approvals and audit, settings, imports | Capability tests and refusal states; actions acknowledged/read back; imported jobs paused; no manager prompt on ordinary turns |
| M4 Mobile continuity | Shared conversation/metadata contracts, APNs relay, deep links, multi-device approval authority, server-side policies | Mac + iPhone operate on the same test sessions; completed jobs and approvals survive app termination |
| M5 Extended parity | Voice, additional document formats, mobile connected apps, demonstrations, event routines, handoffs and coding threads | Required contracts and mobile auth flow pass fixture/integration tests; no placeholder reported as implemented |
| M6 Release and Android | TestFlight verification, accessibility/performance checks, App Store assets; Android native scaffold and dedicated drawings | Real-device acceptance; Android implements the same capability/error contract with FCM and secure storage |

Start M1 with extraction and a small vertical slice: connect a synthetic Hermes profile, list a known session, read its history and send one acknowledged text turn. Do not port the whole macOS `AppStore` into a phone target unchanged.

## Acceptance criteria

1. A new install can test an existing server and add only verified profiles. Cancel, bad keys and ignored profile prefixes leave no agent or persisted key behind.
2. Every feature availability state is derived from capabilities plus route results. OpenClaw, hosted setup and unsupported write operations cannot show a successful connection or completed mutation.
3. After stream loss or process termination, reopening recovers the authoritative result without fabricating completion, deleting partial text, or blindly issuing a second run.
4. Mac and phone using the same canonical session see the same messages. If metadata sync is absent, organization and reactions remain explicitly local.
5. A request decided on another device resolves in the approval inbox. Double taps, timeout and stale IDs never imply a second decision. Display-only requests cannot be approved.
6. A routine remains paused after creation/import until enabled. Schedule/timezone validation produces real next-run times; a run completed with the app closed is delivered once after reconnect.
7. Models are listed from the selected profile. Unsupported/locked/unavailable models show a reason; a rejected switch changes no saved selection. Coding controls remain read-only until supported.
8. Attachments display exactly what will reach the agent. Unsupported or oversized input gives a reason; text is never silently cut off. Saving a preview does not imply a successful upload.
9. Imports strip secret-shaped values, preserve idempotent identity, label skipped items and keep unsupported configuration inert. iOS import never tries to inspect the Grok desktop cache.
10. At accessibility text sizes, content reflows and primary actions remain reachable. VoiceOver announces agent attribution, streaming status and approval outcomes; Reduce Motion stops optional animation.
11. Notifications request permission in context. Denied permission and unavailable relay are distinct. Deep links use configured profile identifiers and cannot pass credentials through a URL.
12. Release claims distinguish specification, native prototype, backend integration and store availability. Android development status does not imply an Android build exists.
13. Manager-agent requests attach management guidance only on demand, ask before changing profiles, and apply only validated result operations. Created profiles pass isolation/credential probes before appearing; retirement preserves history. Local extra instructions remain distinct from server instructions.
14. Connected-app access is checked for the current agent and connection before every action. Revocation or a changed grant invalidates in-flight scope; provider tokens and the Composio project credential never enter the model transcript. A suspended phone cannot be described as an always-on integration executor.

## Evidence and pending engineering choices

Desktop behavior is documented in [the technical reference](../reference.md) and [phase plan](../../PLAN.md), with source boundaries in `Sources/AgentApp/Backends/AgentBackend.swift`, Hermes adapters, models, stores and import modules. The first mobile architecture pass must establish the canonical session binding, pending-approval readback, notification relay, metadata service and timezone semantics before claiming continuous cross-device operation.

The full-feature target also includes connected apps and demonstration-driven skills, informed by the official [Grok Bot overview](https://prod.cursor.com/docs/grok-bot). Those product comparisons establish scope; they do not establish a Hermes API. The deployment target, SQLite library choice, relay hosting and shared metadata schema remain proposed decisions to settle during their respective implementation milestones.
