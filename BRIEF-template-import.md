New feature for AgentApp: Grok Bot template import. Spec excerpt is in docs/SPEC-6.1-template-import.md (treat its field list as input requirements, not a verified schema). HEAD is 9617dcf. Work only in this repo and against fixtures or the throwaway Hermes on this Mac (never Konrad's servers). Never push, never run git add/commit (.git is read-only for you; Ermes commits), never install anything outside this repo.

Goal: the user imports one Grok Bot template they own (pasted share link or an exported share JSON file) into a new AgentApp bot.
1. Parser for the exported JSON (name, title, description, avatar, instructions/persona, selected memories, skills as Markdown, routines with schedule or trigger, plugin/connector ids, optional getting-started skill). Be tolerant of unknown/missing fields. Share link: fetch only if it resolves to the export JSON; otherwise tell the user to export the file, no scraping.
2. Map onto the bot and its Hermes profile where possible: persona/instructions to system prompt/SOUL, skills to Hermes skills, cron schedules to Hermes cron (disabled until activated), memories to agent memory. Event triggers and unknown plugin ids are reported as not carried over.
3. Preview sheet before import listing every item as mapped / converted / skipped / unsupported with a reason; the bot is created only after the user confirms, and routines start disabled.
4. Strip and reject secrets (tokens, keys, passwords, credentials) and keep them out of the report and logs. Do not bundle any Grok Bot content in the app; fixtures must be synthetic.
5. Keep the importer modular so a later "import all my bots" (setups, routines, skills, chat transcripts) can reuse it.
6. Add synthetic fixtures and tests (parsing, mapping, secret stripping, unsupported-item report), update README.

Then ./scripts/build.sh, try swift test (save docs/template-import-*.log; if blocked by _XPCTypeBool, say so), run scripts/test-hermes-integration.sh (EPERM in sandbox is acceptable; report honestly), package into dist/ without installing. Print a per-item summary (done / not done / unverified), the dist path and its SHA-256.
