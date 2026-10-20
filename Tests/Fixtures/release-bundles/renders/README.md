# Golden skill renders (P0d)

What `SkillLibrary.render` (`Sources/AgentApp/BotManager/SkillLibrary.swift`) produces from today's `Resources/` for all four bundled skills, three sample profiles (`default`, `grok-jarvis`, `coder_2`) and every coding order. The box updater's Python renderer (`Resources/Updater/swarmhub_update/render.py`) must match every file byte for byte.

Layout:

- `<skill>/<profile>/<order>/SKILL.md`, where `<order>` is the coding order with commas as dashes (`claude-codex-hermes`, `codex-claude-hermes`, `claude`, `codex`, `hermes`). A skill whose template has no `{{CODING_ORDER}}` is stored once as `any-order`; both tests check that every order renders to it.
- `<skill>/<profile>/files/references/<recipe>.md`: the manager recipes as rendered for that profile. Other extra files (scripts) ship unchanged and have no golden; both tests check that too.

Tests:

- `Tests/AgentAppTests/RenderGoldenTests.swift` (Mac, `swift test`) fails when these files drift from `SkillLibrary.render`, when one is missing or stale, or while `PROVISIONAL` exists. `SWARMHUB_WRITE_RENDERS=1 swift test --filter RenderGoldenTests` rewrites them from Swift and deletes `PROVISIONAL`.
- `Tests/Updater/test_render.py` (Linux or Mac) fails when the Python render differs from any file here or the set of files differs.

## Provisional until the Mac run

If a file named `PROVISIONAL` is in this folder, these goldens were written by the Python port (`python3 Tests/Updater/test_render.py --write-provisional`), not by Swift, because Swift cannot be built on the Linux server. They are a careful port, not proof. They become final when the Mac run rewrites them from Swift and `git diff` shows no change to any golden (only `PROVISIONAL` deleted). Any golden that changes there is a Python port bug to fix in `render.py` before committing.

After any change to `Resources/Skills/` or `Resources/BotManager/` the goldens must be rewritten on the Mac the same way; `--write-provisional` refuses to overwrite a Swift-final set.

A skill folder holding a non-UTF-8 file (typically a `__pycache__` left by a test run) is skipped by `SkillLibrary.bundled()` and by the port alike, so both tests fail until it is deleted (`find Resources -name __pycache__ -prune -exec rm -rf {} +`).

## Version-only refresh on Linux

`PYTHONDONTWRITEBYTECODE=1 python3 Tests/Updater/test_render.py --refresh-versions` regenerates version metadata
with the repository renderer. It requires the same complete Swift-final file set and accepts only a strictly
increasing frontmatter version and its matching advertised version. Every other header byte, the entire body,
and all references must still match Swift's goldens. It validates all files before writing any generated output;
body changes still require the Mac command above. This keeps the existing Swift body provenance intact.
