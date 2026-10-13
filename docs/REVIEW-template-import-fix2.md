# Re-review: AgentApp Grok Bot template import, FIX2 (uncommitted on top of 9617dcf)

**Verdict: FAIL. Not installable.** H-1, L-1 and L-4 are all fixed. But moving the Basic-auth check out of the pattern list introduced a **new HIGH regression**: the most common form, `Authorization: Basic <base64 user:pass>`, now leaks the credential into the preview, `store.json` and the Hermes `system_prompt`. The previous tree redacted it. The fix is a one-line reorder (see N-1).

Counts (new findings): **HIGH 1 · MEDIUM 0 · LOW 4**

**Not built or run here.** This is a Linux box, so Swift could not be built, type-checked or tested. I also couldn't run a regex check: writing a scratch Python script and running `python3` were both refused by this session's permissions. Everything below comes from reading the code and hand-tracing the patterns under ICU (`NSRegularExpression`) semantics, plus Codex's logs.

---

## Status of the items under review

| ID | Status | Evidence |
|---|---|---|
| **H-1** whole PEM/PGP private-key block | **FIXED** | `TemplateImport.swift:84`: `(?s)-----BEGIN ([A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?)-----.*?(?:-----END \1-----[^\r\n]*(?:\r?\n\|\z)\|\z)`. Details below. |
| **L-1** Basic auth vs prose | **FIXED** (with regression N-1) | `:139-149`: `\bBasic\s+(<base64>)`, redacted only if it base64-decodes to UTF-8 containing `:`. "basic troubleshooting" survives (15 chars, not valid base64). A bare `Basic c3ludGhl…` (user:pass) is redacted. But it now runs **after** the `authorization:` pattern (N-1). |
| **L-4** preview heading + Hermes row | **FIXED** (as scoped) | `TemplateImportView.swift:65`: "Instructions". `TemplateImport.swift:227-229`: the `Hermes profile` row is appended only when `hermesConfigured`, which is passed from `AppStore.hasHermesConfiguration` (`TemplateImportView.swift:95`). Residual nits are in N-4. |

### H-1 trace (ICU)

- **Flags:** inline `(?s)` makes `.` match `\n` and `\r`. `\1` is a valid ICU backreference inside a Swift raw string. `\z` means end of input.
- **Header:** greedy `[A-Z0-9 ]*` backtracks to put `PRIVATE KEY` at the right place.
  - `PGP PRIVATE KEY BLOCK`: group 1 is the full label, because `(?: BLOCK)?` has to match for the following `-----` to match.
  - The other key types match too: RSA, EC, DSA, OPENSSH, ENCRYPTED, and PKCS#8 (empty prefix, `-----BEGIN PRIVATE KEY-----`). Digits are now allowed in the label.
- **Body:** lazy `.*?` stops at the first `-----END <same label>-----`. `[^\r\n]*(?:\r?\n|\z)` then consumes the rest of that line and its LF or CRLF.
- **Two keys with text between:** the first match stops at its own END. The text between them is kept. The `while` loop (`:133-138`) then removes the second block.
- **CRLF:** body `\r\n` is covered by dotall, and the END line's `\r\n` by `\r?\n`.
- **Unterminated block:** the lazy match runs to `\z`, so everything to end of text is removed. A mismatched END label does the same. Both fail toward over-redaction.
- **Ordering:** this is the first pattern, so no other pattern can split the body before it matches.
- **Sinks:** sanitizing runs once on the raw tree, before any field is read (`:101-103`). Preview (`plan.manifest.instructions`), `store.json` and Hermes all get the same cleaned string. Hermes receives it as `bot.persona`, sent as `systemPrompt` at `AppStore.swift:195,225,229`. Memories, skills and routines go through the same recursive `sanitize`.
- **Tests:**
  - `AgentAppTests.swift:192-221` uses a real 3-line base64 body. It asserts each body line is absent from `plan.manifest.instructions` (preview), from `bot.persona` (the Hermes `systemPrompt` source) and from the raw `store.json` text, and that "Before"/"After" survive.
  - `:223-232` covers an unterminated RSA block, with an exact expectation of `"Keep this.\n[removed]"`. Both trace as passing.
  - Not exercised: the actual `HermesBackend` request body. That's acceptable, since it is the same string.

## New findings

### HIGH

**N-1. Regression: `Authorization: Basic <credential>` now leaks.** `Sources/AgentApp/TemplateImport/TemplateImport.swift:94, 133-149`

Fix2 moved Basic detection out of `secretValuePatterns` into a separate pass that runs **after** every pattern, including the generic `(authorization)\s*[:=]\s*\S+` (`:94`). Hand trace for `curl -H 'Authorization: Basic c3ludGhldGljVXNlcjpzeW50aGV0aWNQYXNz' https://x`:

1. Patterns 0-9 don't match. Bearer needs "bearer". `://user:pass@` doesn't apply.
2. Pattern `:94` matches `Authorization: Basic`, because `\S+` stops at the space. The result is `'[removed] c3ludGhldGljVXNlcjpzeW50aGV0aWNQYXNz'`.
3. The Basic pass at `:139` looks for `\bBasic\s+`. That word is gone, so nothing matches and **the base64 `user:pass` survives**.

`Proxy-Authorization: Basic …` and `authorization=Basic …` behave the same way. In the previous tree the Basic pattern sat *before* `:94` in the list, so this form was fully redacted. That makes it a regression introduced by fix2.

The impact is the same three sinks as H-1:
- shown in the preview, despite the promise at `TemplateImportView.swift:57`;
- written to `store.json`;
- sent to Hermes as `system_prompt` when it's in the persona.

A curl or header example in a skill or persona is the canonical place a Basic credential would appear. The test at `AgentAppTests.swift:146` plants only the bare `Basic …` form, so it doesn't catch this. Bearer isn't affected, because its pattern (`:85`) runs before `:94`.

Fix (pick one):
- run the Basic pass **before** the `for pattern in secretValuePatterns` loop. The private-key pattern doesn't interact with it, so the order change is safe;
- or change `:94`'s value part to `(?:(?:basic|bearer)\s+)?\S+`.

Add a test case `"Authorization: Basic c3ludGhldGljVXNlcjpzeW50aGV0aWNQYXNz"` that asserts the base64 marker is absent.

### MEDIUM

None.

### LOW

**N-2. The private-key match over-redacts in a few edge layouts.** `TemplateImport.swift:84`
- If text follows the END armor on the same line (`-----END RSA PRIVATE KEY----- then do X`), `[^\r\n]*` removes the rest of that line.
- A lone-CR line ending after END (classic Mac) or a mismatched END label (`BEGIN RSA…` / `END PRIVATE KEY`) makes the block redact to end of text, which drops any later instructions.
- With an LF after END, the following line is joined to the marker: `"Before\n[removed]After"`.

All of these fail safe and are visible in the preview. They're cosmetic or data-loss only, not leaks. Optional: use `\r?\n?` and leave the rest of the END line alone.

**N-3. Remaining Basic and PEM coverage gaps.** `TemplateImport.swift:84, 139-145`
- `Data(base64Encoded:)` rejects unpadded base64 and non-UTF-8 `user:pass`, so those Basic credentials pass.
- Lowercase armor and non-PEM key formats aren't matched: the SSH2/Tectia `---- BEGIN SSH2 ENCRYPTED PRIVATE KEY ----` and PuTTY `.ppk`.
- Removing the standalone `PRIVATE KEY-----` backstop means an orphan END line is no longer redacted. That line isn't secret by itself.

All of these are rare, and none is a fix2 regression apart from the backstop removal, which is harmless.

**N-4. L-4 residuals.**
- The Persona report reason is still unconditional: "Used as the Hermes session system prompt." (`TemplateImport.swift:225`), even when the bot will be `.mock`.
- `makePlan(…, hermesConfigured: Bool = true)` defaults to "configured", so any future caller fails toward the Hermes wording.
- Hermes configuration is read at preview time (`TemplateImportView.swift:95`) and again at import time (`AppStore.swift:195`). A configuration change between the two would make the report disagree with the bot. This is a tiny window.

**N-5. Test hygiene (carried over from L-7, now worse).**
- `AgentAppTests.swift` is 720 lines, against the ≤500-line rule. Split the template-import tests into their own file.
- The new store test mutates the global `UserDefaults.standard["hermesBaseURL"]` (`:193-199`). It's `@MainActor`, so it's serialized against the other test that does this (`:710`). Non-main-actor tests that read `hasHermesConfiguration` could still race with it under Swift Testing's default parallelism.

## Regression re-checks (fix2 scope)

- **Other secret patterns:** unchanged apart from the PEM line and the Basic move. Bearer, the `sk-`/`xox`/`gh*` prefixes, `github_pat_`, JWT, AKIA, AIza, `xapp-`, the Slack webhook, URL userinfo and `key=value` behave as in the previous tree. The only lost coverage is N-1.
- **M1 content preservation:** span redaction is unchanged. The Password-prose and Before/After tests keep the surrounding text.
- **Honest report:** the Security count increments once per block or Basic match. Rows are unchanged except that the Hermes row is now conditional.
- **Preview before import:** unchanged. The plan lives in view state, and the store is written only from the guarded Import button.
- **No bundled Grok content:** fix2 touches no fixtures, `Package.swift` or resources.
- **Build evidence (Codex logs):**
  - `template-import-fix2-build.log` reports `exit_status=0` (direct Xcode 16.2 compiler fallback).
  - `template-import-fix2-test-typecheck.log` reports `Direct compiler test-target type-check: PASS`.
  - `swift build` and `swift test` both exit 72 (the `xcodebuild -find swift` abort, i.e. the host toolchain loader issue). **No test has executed.**
  - The package SHA-256 in `template-import-fix2-sha256.log` (`8df7df09…7a7e`) matches GIT-STATUS.txt. I couldn't hash the zip, since it isn't here.

## Must-fix before MacBook install

1. **N-1:** run the Basic-credential pass before the generic `authorization:` pattern (or have that pattern consume `Basic|Bearer <token>`), and add an `Authorization: Basic <base64>` test case that asserts the base64 marker is absent from the preview manifest and `store.json`.

Loop note: this was designated the final re-review. A new HIGH means **stop for Konrad's decision**: either allow one more one-line fix plus one test, or accept the risk. LOWs N-2 to N-5 don't block.

## Not verified here

- Swift was **not built, type-checked or tested** on this Linux box. On the Mac, `swift test` has never run for this change.
- I traced the regexes by hand under ICU semantics. No engine run was possible, because the scratch script and the Python probe were refused. N-1 doesn't depend on engine subtleties: it follows from pattern order and `\S+` stopping at whitespace.
- Nothing was exercised end to end against Hermes.
