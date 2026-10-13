Narrow one-line fix pass after Claude re-review FAIL (docs/REVIEW-template-import-fix2.md). Loop rule allows one more fix + one re-review for the new HIGH.

Must-fix N-1 only (HIGH regression from fix2):
In Sources/AgentApp/TemplateImport/TemplateImport.swift, the Basic-auth pass currently runs AFTER the secretValuePatterns loop. Pattern (authorization)\s*[:=]\s*\S+ matches "Authorization: Basic" and leaves the base64 user:pass behind, so the later Basic check never sees the word Basic. Result: Authorization: Basic <base64> leaks into preview, store.json, and Hermes system_prompt. The previous tree redacted it.

Fix (pick the safer of):
1. Run the Basic pass BEFORE the for pattern in secretValuePatterns loop (preferred; private-key pattern does not interact), OR
2. Change the authorization value part to also consume optional (?:(?:basic|bearer)\s+)?\S+.

Add a test with text containing "Authorization: Basic c3ludGhldGljVXNlcjpzeW50aGV0aWNQYXNz" (or any valid base64 of user:pass) asserting the base64 marker is absent from preview instructions, saved bot persona, and store.json. Keep the existing bare "Basic <base64>" test.

Do NOT chase LOWs N-2..N-5 unless trivial one-liners. Keep the change minimal.
Build/package as before (scripts/build.sh or equivalent path used in fix2). Write FIX3-NOTES.md with what changed and package SHA-256. Do not commit or install.
