# Review: AgentApp Grok Bot template import (uncommitted on top of 9617dcf)

**Verdict: PASS-WITH-ISSUES.** Don't install on the MacBook until the must-fix items below are done.

The overall design holds up. Sanitizing happens before any mapping. The pipeline is pure up to the moment the user confirms (parse → manifest → plan → `AppStore.importTemplate`). Nothing gets logged. Error messages are fixed strings and never repeat the rejected input. Cron routines and the getting-started skill are forced to disabled. Connector IDs are stored strings that nothing reads, so D5 holds. The fixture is synthetic and isn't bundled into the app. Old stores still load.

The secret filter is where the problems are:
- It misses several secret types the brief names explicitly (JWT, snake_case `access_token=`, `github_pat_`, and others).
- When it does match, it throws away the whole text. One `Password: …` line wipes the imported persona, the app silently falls back to the default persona, and the report still says "mapped".
- The report also overstates memories. It says they are "stored in the bot's local agent memory", but the agent never receives them.

**Not built or run here.** This is a Linux box, so Swift could not be built or tested. Everything below comes from reading and tracing the code plus Codex's logs. The regex findings come from reading the patterns by hand: I couldn't run a probe script here (writes outside this file weren't permitted), and I didn't test ICU's regex engine directly.

Counts: **HIGH 1 · MEDIUM 4 · LOW 8**

---

## Claims table

| Codex claim | Status | Evidence / caveat |
|---|---|---|
| Tolerant exported-JSON parser (metadata, persona, memories, Markdown skills, routines, connectors, avatar, getting-started skill) | **Verified (partly)** | `TemplateImport.swift:83-171`. Keys are matched case- and punctuation-insensitively, and the parser unwraps `template`/`bot`/`agent` wrappers. Unknown fields are ignored and missing fields fall back to defaults; nothing force-unwraps or crashes. Some malformed shapes are dropped silently and never reported (L2). |
| Direct JSON share-link loading; HTML/share-page scraping rejected | **Verified** | `TemplateImport.swift:221-229`: the response must be 2xx, have a MIME type containing `json`, and have a body that parses as a JSON object. Nothing parses HTML. Caveats in L1: plain http is allowed, the size limit is checked only after download, redirects are followed, and there's no explicit timeout. |
| Secret fields/values stripped before mapping/reporting/persistence | **Partly** | The plumbing is right: `sanitize` runs on the raw tree before any field is read (`:87`), no logging, no echo. Coverage is incomplete (H1), and stripping loses data while the report says the item was mapped (M1). |
| Confirmation-gated preview with mapped/converted/skipped/unsupported reasons | **Verified (gate) / partly (reasons)** | The plan lives only in view `@State`. `store.importTemplate` is called only from the "Import agent" button (`TemplateImportView.swift:28`). Cancel, Back or dismiss leave no state behind; an in-flight link load can't touch the store. Reasons: Name/Title/Description/Persona always show "mapped", even when a default was used; dropped items aren't listed; the memory reason overstates (M1, M2). |
| Local persistence of metadata, system prompt, memories, skills, connector requests, routines | **Verified by reading** | `Models.swift` Bot `CodingKeys`, encode and decode. A round-trip test exists (`AgentAppTests.swift:137`). |
| Cron routines and getting-started skill stay disabled | **Verified** | The mapper sets `isEnabled: false` (`:194`). The parser marks the getting-started skill disabled (`:101`). `importTemplate` forces both false again (`AppStore.swift:204-205`). The user can later toggle a routine on, but that does nothing (L5). |
| Event triggers and unknown connectors reported unsupported | **Verified** | `TemplateImport.swift:196-207`, plus a test at `AgentAppTests.swift:112`. |
| Synthetic fixture + tests | **Verified (fixture) / partly (tests)** | The fixture is clearly synthetic. `Package.swift` excludes `Tests`, so it isn't bundled. The tests are mostly happy-path (M4). |
| README | **Verified** | The README is honest that skill/cron/profile installation isn't available on Hermes and that the data is inert. |
| build / package / signing passed | **Partly** | `template-import-test-typecheck.log`: "Direct compiler test-target type-check: PASS". `template-import-build.log` is one line ("xcrun is unavailable; using the Xcode 16.2 compiler directly") with no success marker. The package log shows "replacing existing signature" and the zip path, but not the signing identity. The SHA-256 in the log matches GIT-STATUS (`2cbe543e…`). There's no zip here to hash. |
| Not done: server-side Hermes skill/cron install | **Verified not done** | Correctly reported for skills and routines in the preview and README. **Not** reported for memories (M2), and the preview doesn't say the bot runs on the shared `default` profile (M3). |
| Unverified: swift test (`_XPCTypeBool`) | **Confirmed blocked** | `template-import-swift-test.log`: `Symbol not found: _XPCTypeBool`. No test run exists at all, only the typecheck. |
| Unverified: Hermes fixture bind EPERM | **Confirmed blocked** | `template-import-hermes-integration.log`: `PermissionError … bind … 127.0.0.1:18643 … operation not permitted`. Nothing has exercised Hermes end to end against this change. |

---

## Findings

### HIGH

**H1. The secret filter misses secret types the brief names explicitly.** `Sources/AgentApp/TemplateImport/TemplateImport.swift:75-81`

These values pass `secretValuePatterns` untouched (traced by hand against the four regexes):
- **JWTs** like `eyJhbGciOi….eyJzdWIi….sig`. They're caught only after the word `Bearer `, and the brief asks for JWT by name.
- **snake_case key=value in free text**: `?access_token=…`, `client_secret: …`, `auth_token=…`, `x_api_key=…`. Pattern 4 anchors on `\b`, and `_` counts as a word character, so `_token` and `_secret` never match.
- **`github_pat_…`** (fine-grained GitHub PAT). Only `gh[pousr]_` is covered.
- **AWS** `AKIA…`, **Google** `AIza…`, **Slack** `xapp-…` and `https://hooks.slack.com/services/…` webhook URLs.
- **`-----BEGIN PGP PRIVATE KEY BLOCK-----`**. The PEM pattern requires `PRIVATE KEY-----` immediately, so ` BLOCK` breaks the match.
- **`Authorization: Basic …`** as a value, and URL userinfo like `https://user:pass@host`.

Key names that aren't caught, because `normalize(key).contains(…)` only covers the 11 listed words: `auth`, `bearer`, `jwt`, `passphrase`, `pwd`, `accessKey`, `aws_access_key_id`, `sessionKey`, `webhookUrl`, `dsn`, `connectionString`.

Impact: an export containing any of these keeps the value in the preview. It is then written in plaintext to `store.json` (memories, skill Markdown, routine prompts). If it sits in the persona, it is also sent to the Hermes server as the session `system_prompt` (`AppStore.swift:225,229`).

Fix:
- Add value patterns: JWT `eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}`, `github_pat_`, `AKIA[0-9A-Z]{16}`, `AIza[0-9A-Za-z_-]{35}`, `xapp-`, `hooks.slack.com/services/`, `PRIVATE KEY( BLOCK)?-----`, `Basic\s+[A-Za-z0-9+/=]{12,}`, `://[^/\s:@]+:[^/\s@]+@`.
- Replace the leading `\b` in pattern 4 with `(?<![A-Za-z0-9])` and add `auth[_-]?token|access[_-]?token|client[_-]?secret|authorization`.
- Extend `secretKeys` to cover the key names above.
- Add one test per secret type (see M4).

### MEDIUM

**M1. One sensitive-looking line drops the whole text, and the report says "mapped".** `TemplateImport.swift:80, 107-111, 94, 136, 179-182`

`sanitize` returns `nil` for the **entire string** whenever any pattern matches anywhere in it. Pattern 4 matches ordinary prose such as `Password: never ask the user for it.` or `token: be concise`. What happens next:
- **Persona:** `string(object, keys: ["instructions","persona",…])` comes back nil, so the manifest keeps the app default `"You are a thoughtful, capable assistant."`. The report still adds the fixed row **"Persona / SOUL — mapped — Used as the Hermes session system prompt."** The user imports a bot that has silently lost its instructions.
- **Skill or getting-started Markdown:** `parseSkill` returns nil and the skill disappears from both the preview and the report.
- **Memory:** it disappears the same way. The only trace is an aggregate line, "N sensitive fields or values were rejected", which doesn't say which item was lost.

Name, Title and Description are likewise always reported "mapped", even when absent and defaulted (`:179-181`).

Fix:
- Record the *location* of each drop (category plus item name, never the value) and emit one row per item: "Skill 'X' — skipped — content contained a value that looks like a credential."
- Better still, redact only the matched span (`[removed]`) so the rest of a long Markdown document survives.
- Report missing metadata or persona as "skipped — not provided; default used".

**M2. The report overstates where memories go.** `TemplateImport.swift:189`

Memories get the row "**mapped** — Stored in the bot's local agent memory". In reality `importTemplate` writes them to `memorySummary` and `importedMemories` (`AppStore.swift:192-198`). `memorySummary` is only displayed (`InfoPanel.swift:36`), and the send path passes only `bot.persona` (`AppStore.swift:225,229`). The agent never sees the memories.

This directly fails check #8: an unfinished mapping is presented as if it were done. The README sentence ("persisted as inert bot configuration") is accurate; the preview isn't.

Fix: change the row to `.converted` with a reason like "Saved with the bot in AgentApp; not yet given to the agent or Hermes memory."

**M3. The imported bot quietly runs on the shared Hermes `default` profile.** `AppStore.swift:195, 200`

When Hermes is configured, the bot gets `backend: .hermes, hermesProfile: "default"`. It therefore inherits that profile's SOUL.md, memory, skills, tools and credentials, and anything it learns lands in the default profile's memory. The persona is only a per-session system prompt.

The preview row is labelled "Persona / SOUL", which suggests the SOUL is replaced. It isn't, and neither the preview nor the README mentions the shared profile.

There's also a gap against the spec (not the brief): the spec says "Stage a disabled bot … before activation", but the bot can chat as soon as the user confirms.

Fix:
- Rename the row to "Persona" and add a row like "Hermes profile — converted — Runs on your default Hermes profile; its tools, memory and skills apply."
- Add one README sentence saying the same.

**M4. The tests mostly check happy paths and don't really test the security or confirmation boundaries.** `Tests/AgentAppTests/AgentAppTests.swift:100-150`

- **Secret test (`:123`):** covers three cases: the `api_key` key, `Bearer` inside a memory value, and a nested `password` key. It never tests the `sk-`/`ghp_`/`xox*`/PEM value patterns, never tests values inside skill Markdown, routine prompts, the persona or arrays, and never asserts the **persisted** `Bot` or `store.json` is free of the marker. Only the encoded report is checked.
- **Confirmation-boundary test (`:137`):** shows only that `makePlan` doesn't touch the store. That is true by construction, since `makePlan` never receives a store. The real gate is the button in `TemplateImportView`, and nothing tests it.
- **No legacy-store test:** nothing decodes an old `store.json` written without `importedMemories`/`importedSkills`/`requestedConnectorIDs`/`gettingStartedSkill`/`routines`. The code uses `decodeIfPresent`, so I expect this to work, but no test proves it.
- **Nothing has run:** none of these tests has actually executed (`_XPCTypeBool`); only the typecheck passed.

Fix:
- Add a parameterised secret test with one value per type from H1, placed in each of persona, skill, routine prompt, memory and a nested array.
- Assert that `String(data: JSONEncoder().encode(store.bots))` doesn't contain the marker.
- Add the "Password: …" persona case to cover M1.
- Add a fixture-JSON test that decodes a legacy Bot.

### LOW

**L1. Share-link loader hardening.** `TemplateImport.swift:221-229`, `TemplateImportView.swift:78-86`
- `http` is accepted; https-only would stop on-path tampering with a persona.
- `session.data(for:)` buffers the whole body before the 5 MB check. There's no `Content-Length` precheck and no streaming cap, so a huge response could exhaust the app's memory.
- There's no explicit timeout (`URLSession.shared` defaults to 60 s idle and 7 days total) and no way to cancel. Closing the sheet leaves the task running; it's harmless because it never touches the store.
- Redirects are followed to any host.
- ATS config isn't in this tree, so I can't tell whether plain http is blocked anyway.

Fix: require https, use an ephemeral session with `timeoutIntervalForResource` ≈ 20 s, use `bytes(for:)` with a running cap, and either reject cross-origin redirects or re-validate them.

**L2. Some malformed items vanish without a report row.** `TemplateImport.swift:122-157, 193-200`
- Skills without Markdown, memories without text, routines given as plain strings, and connectors given as a `{id: {...}}` map are dropped silently.
- A routine with both a schedule and a trigger keeps the schedule and silently loses the trigger.

The brief wants every item listed with a reason.

**L3. Schedules aren't validated.** `TemplateImport.swift:144, 194`. Any string, e.g. "every Monday", becomes an `importKind: .cron` routine labelled "Stored as a disabled cron routine". Validate the 5-field cron syntax, or report non-cron schedules as "converted — free-text schedule".

**L4. Imported regular skills are saved as enabled.** `TemplateImport.swift:26` (default `isEnabled: true`), used by `parseSkill :135-137`. They're inert today. But a later provisioning step (or "import all") that respects `isEnabled` would turn on unreviewed skills. The spec wants a staged, disabled bot, so default imported skills to `false`.

**L5. Activation is promised but has no UI.**
- Imported routines can be toggled on in `InfoPanel` `RoutineRow` (`InfoPanel.swift:59, 76`), but nothing schedules them, and the only hint is the editor's "TODO: backend scheduling is mocked locally".
- The getting-started skill and `requestedConnectorIDs` have no UI after import, yet the report says "disabled until the owner reviews and activates it".
- Imported skill names appear under "Skills" (`InfoPanel.swift:37`) exactly like configured skills.

Fix: label these as "imported — not active" or similar.

**L6. Nested types fail to decode if fields are added later.** `Models.swift:196-199` (`BotRoutine`), `TemplateImport.swift:19-30` (`ImportedTemplateSkill`). Both use synthesized `Decodable` with non-optional fields. If either struct gains a field in a later version, decoding the existing data throws. That sends the **whole store** down the corrupt path (`AppStore.swift:64`: file moved to `store.json.corrupt-*`, saving disabled). Write `decodeIfPresent` initializers now, while no data in this shape exists yet.

**L7. Double-clicking "Import agent" can create two bots.** `TemplateImportView.swift:28` calls `importTemplate` and then `dismiss()`, with no guard against a second click. Add an `isImporting` flag.

**L8. Small modularity and hygiene items.**
- `value(_:keys:)` (`TemplateImport.swift:162`) picks whichever alias the dictionary yields first when two aliases are both present (e.g. `system_prompt` and `systemPrompt`), so the choice isn't deterministic.
- The sanitizer is `private` inside `GrokTemplateParser`. "Import all" (transcripts) needs it as a standalone `TemplateSanitizer`.
- `AgentAppTests.swift` is now 604 lines, against the ≤500 rule. It was already 552 before this change.

---

## Check-by-check notes

1. **Security.** Plumbing is good; coverage isn't (H1, M1). Nothing is logged: the import code has no `print`/`Logger` calls. Errors map to fixed strings (`TemplateImportView.swift:92`), so rejected values aren't echoed. Imported data stays inert:
   - Markdown is shown as plain `Text`.
   - The avatar URL is never fetched; only an exact `BotAvatarName` raw value is used.
   - Nothing is executed.
   - The persona is sent to Hermes as a system prompt, which is the intended mapping.
2. **Preview before import.** Verified by tracing. Cancel, Back and dismiss leave no state.
3. **Mapping.** Present for every field. Unknown fields are tolerated and missing ones default without crashing. Reason quality: M1, M2, L2.
4. **Disabled / unsupported items.** Verified. Connector requests grant nothing: `requestedConnectorIDs` isn't read anywhere, and AgentApp has no connector subsystem.
5. **No Grok content.** Verified. The only "Grok" strings are UI labels and wrapper key names. The default persona is AgentApp's existing default. The fixture is synthetic and excluded from the app target.
6. **Persistence.** New fields use `encode`/`decodeIfPresent`, so old stores load (by reading; untested, M4). Routines moved from in-memory `AppStore.routines` to the persisted `Bot.routines`, and `RoutineEditor`/`RoutineRow` now call `store.save()`. User routines now survive a relaunch, which is a behaviour change and an improvement. Demo routines are created only in snapshot `demoMode` (`AppStore.swift:38`, persist=false), so they don't leak into a real store. The tests don't really cover the boundaries (M4).
7. **Modularity for "import all my bots".** The seam is reasonable: a pure parser → manifest → pure mapper → plan, plus one store entry point. Before batch import:
   - extract the sanitizer (L8);
   - move `Bot` construction out of `AppStore.importTemplate` into the mapper (e.g. `plan.makeBot(hermesConfigured:)`);
   - add a `[TemplateImportPlan]` batch preview;
   - add a transcript → `ChatMessage` mapper that goes through the same sanitizer.
8. **Server-side gaps reported?** Yes for skills and cron (preview reasons and README). **No for memories** (M2) and for the shared `default` profile (M3).
9. **Regressions.**
   - **Hermes backend:** `HermesBackend.swift` is unchanged. The imported bot uses the existing `createSession` / `send` path. `refreshHermesAgents` (`AppStore.swift:89`) treats the imported bot as covering the `default` profile, so if the user had deleted the original "Hermes" bot, no new default bot is re-added; that's harmless.
   - **Approvals (fix4):** untouched. Imported bots get `.ask` plus `ApprovalRule.sensibleDefaults` and no reviewer, so there's no loosening.
   - **Stop and history:** untouched.
   - **Packaging:** the fixture isn't bundled.
   - Nothing in this change has been exercised end to end against Hermes (EPERM), and no test has run (`_XPCTypeBool`).

---

## Must-fix before MacBook install

1. **H1:** extend the secret value patterns and key names (JWT, snake_case `*_token=`/`*_secret:`, `github_pat_`, AKIA, AIza, xapp/Slack webhook, PGP private key block, Basic auth, URL userinfo; `auth`/`bearer`/`jwt`/`passphrase`/`pwd`/`accessKey` keys), with a test for each type.
2. **M1:** when a value is rejected, add a per-item report row (or redact just the matched span). Never report "Persona — mapped" when the persona was dropped or defaulted.
3. **M2:** change the memory row to "converted — saved with the bot in AgentApp; not yet given to the agent".

Should-fix in the same pass (cheap): M3 (state the shared `default` profile in the preview and README), M4 (persisted-store secret assertion plus a legacy-decode test), L4 (imported skills saved disabled), L7 (double-import guard).

## Not verified here

- Swift was **not built, type-checked or tested** on this Linux box; this review comes entirely from reading the code.
- `swift test` has never run for this change (Codex's log: `_XPCTypeBool`).
- The Hermes integration fixture failed to bind (EPERM), so nothing has been exercised end to end against Hermes.
- I couldn't hash the package zip here; the SHA comes only from Codex's log and `GIT-STATUS.txt`.
- I didn't run the regexes under ICU (`NSString.range(of:options:.regularExpression)`); the H1 and M1 conclusions come from reading the patterns.
