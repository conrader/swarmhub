# SwarmHub iOS screen map

37 editable drawings · Design v0.1 · 14 October 2026

Open [the prototype](screens.html) to follow the screens. Every screen uses synthetic data. Backend availability below describes requirements for the native implementation.

## Setup

| Screen | Purpose | Backend boundary | Continue to |
| --- | --- | --- | --- |
| [S01 Welcome](screens.html#welcome) | Connect to the computer or server where your agents already run. Explore sample screens before entering any credentials. | Hermes first. OpenClaw and managed hosting are not available yet. | [Connect server](screens.html#connect), [Hosted setup](screens.html#hosted), [Chats](screens.html#chats) |
| [S02 Connect server](screens.html#connect) | Test a server without saving the address or key. Choose agents only after the connection and profile checks succeed. | HTTPS plus a valid per-profile key. A phone cannot reach the Mac through its own localhost. | [Choose agents](screens.html#discover), [Servers and profiles](screens.html#servers), [Welcome](screens.html#welcome) |
| [S03 Choose agents](screens.html#discover) | Show only verified profiles. Selection controls change the sample count; confirmation opens the sample roster. | Discovery requires the submitted profile keys; one key does not imply discovery of every server profile. | [Chats](screens.html#chats), [Connect server](screens.html#connect) |
| [S36 Hosted setup](screens.html#hosted) | An honest destination for a future hosted service with one clear path back to connecting an existing server. | Managed hosting is deferred. No account, provisioning request, billing or payment integration. | [Connect server](screens.html#connect), [Welcome](screens.html#welcome) |

## Conversations

| Screen | Purpose | Backend boundary | Continue to |
| --- | --- | --- | --- |
| [S04 Chats](screens.html#chats) | A quiet roster with message previews, unread state and work status. Search opens local discovery; plus opens agent creation. | Roster works from local cache. Sections, pins and unread sync require the shared metadata service. | [Agent conversation](screens.html#chat), [Group conversation](screens.html#group), [Search](screens.html#search), [Edit agent](screens.html#editor), [Import source](screens.html#import), [Approval inbox](screens.html#approvals) |
| [S05 Agent conversation](screens.html#chat) | Assistant replies stay plain; attachments and useful results become small cards. The composer supports attachments, voice, Stop and capability-gated steer. | Sessions/SSE; run_steer for guidance. Cards and voice recording here use synthetic state. | [Agent overview](screens.html#overview), [Thread](screens.html#thread), [Add context](screens.html#attachments), [Voice memo](screens.html#voice), [Interrupted connection](screens.html#recovery), [File preview](screens.html#preview) |
| [S06 Thread](screens.html#thread) | A focused conversation anchored to a result, with a clear return to the main chat. Tapbacks stay lightweight acknowledgments. | Hermes session_fork copies the whole current transcript; it is not a fork at the selected historical message. | [Agent conversation](screens.html#chat), [Agent overview](screens.html#overview) |
| [S07 Group conversation](screens.html#group) | A shared outcome with visible authors. Mentions route to a selected member; current default routing remains sequential. | Each group member has a separate session. Autonomous server handoffs are a later contract. | [Group members](screens.html#members), [Agent conversation](screens.html#chat), [Add context](screens.html#attachments) |
| [S08 Group members](screens.html#members) | Rename a group and add/remove agents while keeping earlier messages and sessions. Human workspace collaboration is a separate feature. | Local group metadata now; cross-device membership requires shared metadata. | [Group conversation](screens.html#group), [Choose agents](screens.html#discover), [Edit agent](screens.html#editor) |
| [S30 Interrupted connection](screens.html#recovery) | A truthful recovery state distinguishes a lost connection from server completion. Drafts remain local until a deliberate send. | Requires run-status/history readback and stable identifiers. Check before retry when delivery is uncertain. | [Agent conversation](screens.html#chat), [Servers and profiles](screens.html#servers), [Approval inbox](screens.html#approvals) |
| [S31 Add context](screens.html#attachments) | Native photo, camera and document choices lead to an extraction preview. The user sees what the agent will receive before sending. | Image/text envelope follows desktop; PDF extraction and other media need implementation. Unsupported files cannot be silently truncated. | [Agent conversation](screens.html#chat), [File preview](screens.html#preview), [Voice memo](screens.html#voice) |
| [S32 Voice memo](screens.html#voice) | Record, cancel, play back and review a transcript before sending. Microphone permission is requested when the feature is used. | Requires on-device/server transcription and a supported ingestion contract. This drawing creates no recording. | [Agent conversation](screens.html#chat), [Add context](screens.html#attachments) |
| [S35 Search](screens.html#search) | Find an agent, thread, file or routine. Results identify the context and only claim to cover data already cached on this phone. | Local full-text index required. Server-wide search is not assumed. | [Agent conversation](screens.html#chat), [Thread](screens.html#thread), [File preview](screens.html#preview), [Routines](screens.html#routines), [Imported archive](screens.html#archive) |

## Agents

| Screen | Purpose | Backend boundary | Continue to |
| --- | --- | --- | --- |
| [S09 Agent overview](screens.html#overview) | The desktop inspector becomes a full-screen mobile destination. Skills, tools and model source remain visible without crowding the chat. | Read APIs for skills/toolsets/model catalog. Memory summary remains read-only. | [Routines](screens.html#routines), [Media](screens.html#media), [Agent computer](screens.html#computer), [Models](screens.html#models), [Approval policies](screens.html#policies), [Connected apps](screens.html#apps), [Teach a workflow](screens.html#teach), [Delegated work](screens.html#activity), [Edit agent](screens.html#editor) |
| [S10 Edit agent](screens.html#editor) | The simple editor keeps identity, instructions and notifications upfront. Advanced holds the technical choices; copy/share keep private data out. | Local configuration is separate from server profile creation or editing SOUL. Imported/copied routines remain disabled. | [Agent overview](screens.html#overview), [Models](screens.html#models), [Approval policies](screens.html#policies), [Manage agents](screens.html#management), [Import source](screens.html#import), [Group members](screens.html#members) |
| [S29 Delegated work](screens.html#activity) | Show the owner, status and result for each delegated task. Transcript and steer actions exist only when the backend can supply them. | Current Hermes stream does not supply a complete child-task lifecycle/transcript contract. This is a planned-state drawing. | [Agent conversation](screens.html#chat), [Models](screens.html#models), [Agent overview](screens.html#overview) |
| [S33 Connected apps](screens.html#apps) | Connect accounts through SwarmHub and choose each agent’s access. App actions keep their approval context in chat. | Port the desktop Composio work with a verified mobile auth-return flow, per-agent grants and revocation. Closed-app execution requires a companion executor. | [Agent overview](screens.html#overview), [Teach a workflow](screens.html#teach), [Routine editor](screens.html#routine-editor) |
| [S34 Teach a workflow](screens.html#teach) | Demonstrate a repeatable task, then review the saved skill before scheduling. Keep the future workflow visible without inventing a recorder. | Needs server demonstration capture plus supported skill installation/write APIs. | [Agent computer](screens.html#computer), [Routines](screens.html#routines), [Agent overview](screens.html#overview), [Connected apps](screens.html#apps) |
| [S37 Manage agents](screens.html#management) | Ask the designated manager to create an agent, change server instructions or marks, list profiles, or retire an agent. A management request is reviewed in chat before execution. | Port the stock-Hermes on-demand manager instructions, result parser and key derivation. No new server route or installed skill is required. | [Agent conversation](screens.html#chat), [Edit agent](screens.html#editor), [Choose agents](screens.html#discover), [Approval detail](screens.html#approval) |

## Work

| Screen | Purpose | Backend boundary | Continue to |
| --- | --- | --- | --- |
| [S11 Routines](screens.html#routines) | Simple scheduled work, next-run information and visible pause state. Tap a routine to edit; run results return to the agent chat. | Hermes jobs routes; server executes schedules. Push when closed requires a relay. | [Routine editor](screens.html#routine-editor), [Agent conversation](screens.html#chat), [Agent overview](screens.html#overview) |
| [S12 Routine editor](screens.html#routine-editor) | Plain-language presets first, with cron under Advanced. Preview server-derived next runs and save new/imported jobs paused. | Schedules need confirmed server timezone/DST semantics. Event triggers need a new server contract. | [Routines](screens.html#routines), [Connected apps](screens.html#apps) |
| [S13 Media](screens.html#media) | Files, images and links collected from the main conversation and its threads. Preview or jump back to the originating message. | Derived from cached transcripts; downloading and sharing use native platform controls. | [File preview](screens.html#preview), [Agent conversation](screens.html#chat), [Thread](screens.html#thread), [Agent overview](screens.html#overview) |
| [S14 File preview](screens.html#preview) | A readable file preview with save/share and source-message navigation. Preview and agent ingestion are separate states. | Quick Look/PDFKit and sandboxed attachments. Original synthetic document shown here. | [Agent conversation](screens.html#chat), [Thread](screens.html#thread), [Add context](screens.html#attachments) |
| [S15 Agent computer](screens.html#computer) | Watch a configured remote desktop, use the keyboard or rotate into landscape. Control ownership must come from the provider. | Existing HTTPS web desktop; touch/keyboard compatibility needs validation. No computer-reset API is assumed. | [Agent overview](screens.html#overview), [Agent conversation](screens.html#chat), [Teach a workflow](screens.html#teach), [Servers and profiles](screens.html#servers) |

## Review

| Screen | Purpose | Backend boundary | Continue to |
| --- | --- | --- | --- |
| [S16 Approval inbox](screens.html#approvals) | One inbox for decisions across agents, with context and attribution. Resolved/display-only requests do not count as pending approvals. | Needs reconnectable pending approvals and a server authority that resolves requests once across devices. | [Approval detail](screens.html#approval), [Decision history](screens.html#audit), [Approval policies](screens.html#policies) |
| [S17 Approval detail](screens.html#approval) | Present the exact action and destination beside the relevant result. A submitting decision remains pending until acknowledged. | Only actionable requests with required raw action data can be approved. Expired/already-resolved states need readback. | [Approval inbox](screens.html#approvals), [Agent conversation](screens.html#chat), [Decision history](screens.html#audit) |
| [S18 Approval policies](screens.html#policies) | Manual decisions are the default. Rules and reviewer mode stay behind clear advanced descriptions and server availability. | Desktop policies are client-side today. Background automatic review needs a server policy executor; ambiguous actions fall back to Ask me. | [Approval detail](screens.html#approval), [Decision history](screens.html#audit), [Edit agent](screens.html#editor) |
| [S19 Decision history](screens.html#audit) | A compact audit records who decided, which agent requested it and whether the server accepted the decision. Sensitive action text is redacted. | Local audit can be ported; shared multi-device history requires server audit records. | [Approval inbox](screens.html#approvals), [Approval detail](screens.html#approval), [Agent overview](screens.html#overview) |

## Settings

| Screen | Purpose | Backend boundary | Continue to |
| --- | --- | --- | --- |
| [S20 Simple settings](screens.html#settings) | One short settings page with connection, display name, appearance, notifications and About. Technical controls live under Advanced. | No workspace account is assumed. Mobile updates use TestFlight/App Store rather than Sparkle. | [Servers and profiles](screens.html#servers), [Appearance](screens.html#appearance), [Notifications](screens.html#notifications), [Models](screens.html#models), [Usage](screens.html#usage), [Import source](screens.html#import), [Approval policies](screens.html#policies) |
| [S21 Servers and profiles](screens.html#servers) | Profiles keep separate credentials and connection results. Saving is deliberate; tests never send chat requests or create jobs. | HTTPS and profile-isolation checks; iOS Keychain scoped by server/profile. OpenClaw transport pending. | [Connect server](screens.html#connect), [Choose agents](screens.html#discover), [Models](screens.html#models), [Approval policies](screens.html#policies), [Usage](screens.html#usage), [Agent computer](screens.html#computer) |
| [S22 Models](screens.html#models) | Choose from the selected agent’s catalog. Separate its default from this chat’s lock, with unavailable coding and server-owned roles shown honestly. | model_options and session_model_lock with verified routes. Coding/sub-agent config writes are not implemented. | [Agent overview](screens.html#overview), [Edit agent](screens.html#editor), [Servers and profiles](screens.html#servers), [Delegated work](screens.html#activity) |
| [S23 Appearance](screens.html#appearance) | Dark, Light or System; existing accent choices; contextual, calm or disabled avatar motion. Device Reduce Motion always takes precedence. | Native system appearance and accessibility settings. These appearance controls change only this prototype. | [Simple settings](screens.html#settings), [Edit agent](screens.html#editor) |
| [S24 Notifications](screens.html#notifications) | Ask permission when the owner enables useful alerts. Approval, completed reply and routine notifications deep link to their original context. | APNs relay and device enrollment/removal required for delivery with the app closed; foreground-only stage must disclose this. | [Simple settings](screens.html#settings), [Approval inbox](screens.html#approvals), [Agent conversation](screens.html#chat) |
| [S25 Usage](screens.html#usage) | Load actual message and token totals from configured profiles. Missing profiles and incomplete coverage stay visible; no price estimates. | Hermes session pagination and tokens. Values here are synthetic; period semantics match session-start filtering until improved. | [Simple settings](screens.html#settings), [Servers and profiles](screens.html#servers) |

## Import

| Screen | Purpose | Backend boundary | Continue to |
| --- | --- | --- | --- |
| [S26 Import source](screens.html#import) | Import an exported bot bundle or sanitized template. Phone imports use Files or a JSON link; they cannot inspect a Mac’s app cache. | Reuse parsers and sanitizing. Link fetches require size/origin/redirect/timeout hardening. | [Import preview](screens.html#import-preview), [Imported archive](screens.html#archive), [Connect server](screens.html#connect) |
| [S27 Import preview](screens.html#import-preview) | Show every mapped/skipped/unsupported category before creating an agent. Preserve identity for re-import without activating jobs or grants. | Existing safe parser/mapping; profile installation, memory writes and connector grants need supported server APIs. | [Imported archive](screens.html#archive), [Chats](screens.html#chats), [Routines](screens.html#routines), [Connected apps](screens.html#apps) |
| [S28 Imported archive](screens.html#archive) | Read-only imported history stays separate from the live conversation, searchable and attributed to its source. | Bundle import plus local/archive session persistence. Resume live chat only through a configured profile. | [Agent conversation](screens.html#chat), [Search](screens.html#search), [Import source](screens.html#import) |

## Flows

- Setup: S01 → S02 → S03 → S04. S36 returns to S02.
- Work: S04 → S05 → S09 → S11/S13/S15. S06 returns to S05.
- Group: S04 → S07 → S08.
- Approval: S16 → S17 → S19; the request also links to S05.
- Import: S20 → S26 → S27 → S28.
- Recovery: S30 → authoritative status check → S05.
- Agent management: S10 → S37 → manager conversation → reviewed change → verified profile.
- Extended workflows: S09 → S33/S34; live actions stay gated by server support.

The drawings use local state for selection, toggles, sample messages, approval receipts and appearance. They do not implement production networking, recording, OAuth, files, notifications or server mutations.
