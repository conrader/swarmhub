# AgentApp template-import fix1 (Claude review PASS-WITH-ISSUES)

HEAD is 9617dcf with uncommitted template-import work. Read docs/REVIEW-template-import.md. Work only in this repo and against fixtures / throwaway Hermes on this Mac (never Konrad's servers). Never push, never git add/commit (.git read-only for you; Ermes commits), never install outside this repo.

Fix must-fix before MacBook install, then the cheap should-fixes in the same pass:

## Must-fix
1. **H1** Sources/AgentApp/TemplateImport/TemplateImport.swift — extend secret value patterns and key names: JWT eyJ…, snake_case *_token=/*_secret:, github_pat_, AKIA, AIza, xapp-/Slack webhook hooks.slack.com/services/, PGP PRIVATE KEY BLOCK, Basic auth, URL userinfo; keys auth/bearer/jwt/passphrase/pwd/accessKey/aws_access_key_id/sessionKey/webhookUrl/dsn/connectionString. Replace leading \b in pattern 4 with (?<![A-Za-z0-9]). Add one test per secret type.
2. **M1** — when a value is rejected, emit a per-item report row (or redact only the matched span). Never report "Persona — mapped" when persona was dropped or defaulted. Same for Name/Title/Description defaults and silently dropped skills/memories.
3. **M2** — memory report row: converted — saved with the bot in AgentApp; not yet given to the agent.

## Should-fix same pass
4. **M3** — rename Persona/SOUL row to Persona; add Hermes profile converted row saying it runs on default profile; one README sentence.
5. **M4** — parameterised secret tests in persona/skill/routine/memory; assert encoded store.bots has no marker; Password: prose persona case; legacy Bot decode fixture.
6. **L4** — imported skills saved disabled if that is still missing.
7. **L7** — double-import guard if cheap.

Leave other LOWs listed in README Known issues. Do not invent new features.

Then ./scripts/build.sh, try swift test (docs/template-import-fix1-*.log; if _XPCTypeBool say so), try scripts/test-hermes-integration.sh (EPERM OK), package dist/ without installing. Print per-item done/not done/unverified, dist path and SHA-256.
