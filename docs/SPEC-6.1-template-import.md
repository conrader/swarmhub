### 6.1 Grok Bot template import

**Konrad's idea (Oct 10, 2026):** import user-created Grok Bot templates as starting bots. The publicly known shape from Grok Bot's export feature, supplied for this spec, contains a name, short description, selected memories (job and convention facts), named skills (Markdown job instructions), routines (saved prompt plus schedule or trigger), marketplace plugin/connector ids without tokens, and an optional “getting started” skill for the first conversation with the new owner. Treat this as input requirements, not a verified schema; validate against a permitted sample export.

**Ermes import mapper:**

- Name and description become bot metadata; selected memories go to agent memory through the adapter.
- Skills become Hermes/OpenClaw skills; both use Markdown skill files **[Assumption: verify runtime schemas before implementation]**. Preserve instructions and names, reporting required metadata conversions.
- Routines become Ermes routines, preserving prompts and supported schedules/triggers; unsupported triggers stay disabled.
- Plugin ids map to Ermes connectors through an explicit mapping table; unknown or unavailable plugins are flagged as unsupported. The user authorizes connectors separately.
- The optional getting-started skill is offered for the first owner conversation only after review and activation.

**Import report and activation:** preview every mapped, converted, skipped or unsupported item, with reasons and missing capabilities. Stage a disabled bot; the user must review the report, memories, instructions, routines and requested connector grants before activation. Never import secrets: reject credentials, tokens, passwords and private keys; keep rejected values out of reports and logs. Importing grants never authorizes access or bypasses D5.

**Legal boundary:** import only templates users export or are allowed to share. Never copy Grok Bot's proprietary system instructions or built-in tool definitions.

**Ermes open template format:** publish a versioned, documented JSON manifest with Markdown skill files: a superset of the fields above, adding runtime/capability requirements, Ermes grants and approval policies, provenance and extension fields. Exclude credentials and live authorizations. Support import/export across runtimes and Cloud/BYO, plus Grok Bot-compatible export where its format permits; report lossy conversions rather than promise full round trips. Templates remain inert data until reviewed; no embedded executable plugins.
