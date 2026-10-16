# Team coordination in SwarmHub

Implemented on `codex/swarmhub-team-coordination`. This is an opt-in macOS change over the existing chat/session/run APIs. It adds no server, daemon, webhook, Hermes script, profile change or scheduler job.

## Use it

- In a bot chat, `@Peer your request` creates a task for that peer and a summary task for the current bot. It needs no installed messaging skill. Duplicate names have a stable identity suffix in the picker.
- In a group, select **Work together** before sending. One member begins, with structured help and review operations available for the listed members. Ordinary group rounds remain available.
- Existing planned workflows can use **Allow in-scope help and reviews** before running. Without this option, their previous plan-review behaviour remains.
- The team card shows tasks, delivery state, dependency results, budget and operation history. Open a task thread to read or steer work already running. Add instructions to a queued task or to the remaining team work from its card.
- **Pause new work**, **Cancel queued work**, and **Request Stop for workflow** have distinct effects. Disconnecting or closing the app never invokes Stop.
- While paused, set task/review/depth/concurrency/active-time limits, token allowance, expiry, evidence verification and notification preferences. App review scopes explicitly name a tool, connected account and reviewer. Backend permissions still apply.
- The book button opens shared project context. Facts include source, owner, kind, revision and reader identities. Corrections retain their earlier version. They are included in ordinary requests; they are never written into Hermes memory.
- Dictate into the existing composer, review the text and send. **Speak this reply** reads the actual finished reply. No separate voice conversation claims to have delegated work.

## Delivery and recovery

The existing local SQLite journal records task intent and policy before sending. Each task has its own stable session ID and reply placeholder. Operations are deduplicated locally by operation ID and canonical payload; this is not a promise of exactly-once remote execution.

A stream or protocol failure after submission is uncertain. SwarmHub checks remote history/run state before continuing; missing history does not prove a request was never received. A recovered result releases eligible dependent tasks once. Task threads cannot bypass this through the generic Retry button.

One process holds a local file lock for coordination. A saved workflow also identifies its coordinating installation. A second device cannot take over an independent copy of its ledger. Work can only be newly delegated while SwarmHub is running and connected. The server's behaviour determines whether an already submitted run survives a disconnected client.

Final results appear in the originating conversation and the coordinator's task thread. Task completions do not each produce a notification. Final-result/blocker notifications are deduplicated and respect quiet hours in the selected timezone. Quiet hours retain visible results.

## What is deliberately not claimed

- Full iOS coordination UI or cross-device failover. `Packages/SwarmHubCoordination` provides portable macOS/iOS contracts; the existing iOS client is otherwise unchanged.
- Live full-duplex voice delegation; this increment uses existing dictation and spoken real-chat replies.
- Observability of arbitrary externally launched jobs or attestation of the executing model. Those require information already exposed by the backend. A finished answer or a review verdict does not verify deployment/test acceptance checks. Enable explicit evidence verification for those tasks.
- Migration of all Grok behaviour. Coverage reports distinguish archived messages and imported candidates from current tools, permissions and external routines. Candidates are never automatic grants.
- Server exactly-once semantics, or uninterrupted work through Mac sleep. No production Hermes configuration or execution has been changed to test this branch.

Text handoffs are supported. Attachments still use the ordinary chat/document paths; team handoff does not silently forward an attachment to new readers.

## Validation

Synthetic native macOS tests exercise authorized help/review/revision/synthesis, identity changes, duplicate names, local dispatcher ownership, missing-thread recovery, uncertain delivery, remote completion without resending, failed journal commits, pause/cancel separation, parallel sessions, project reader isolation, exact app-review scopes, quiet-hour DST transitions and speech eligibility. Existing workflow/connected-app tests remain applicable. UI render fixtures are available with `--render-setup <outside-repository-directory> --only team`.

Native validation: full app suite passed (1,235 tests, with 20 pre-existing known issues); the shared contract package passed its 2 tests; `scripts/build.sh` passed. The final focused run passed 49 tests; the two changed UI screens were rendered and inspected.

Live stock-server disconnect behaviour remains a release acceptance check. No production profiles, memory, skills, configuration or jobs are changed by this implementation.
