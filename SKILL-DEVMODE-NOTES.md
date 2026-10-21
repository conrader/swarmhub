# Skill dev mode — notes (feat/skill-dev-mode, 2026-10-21)

Per-bot toggle (Mac only) so a bot such as Jarvis can edit its installed SwarmHub skills on its Hermes box and test
them live, without the installer or updater overwriting the edits.

## How skill overwrites worked before (main 0258bb2)

Every path overwrote unconditionally; none looked at what was on the box first.

1. **Install / Update, legacy (unbootstrapped connection).** `AppStore.installSkills(for:)` →
   `skillInstallCommands` sends the connection's manager one turn whose shell commands, per skill, are `mkdir -p`,
   one `cat > <folder>/<file> <<'SWARMHUB_EOF'` heredoc per file (SKILL.md rendered for the bot, then the extra files),
   `chmod 755` for `scripts/`, and for swarmhub-messages the peer-runtime install/enable/start. `cat >` truncates and
   rewrites whatever is there. The app records versions from the manager's `skills_installed` block. The all-bots
   install (`installSkillsOnAllBots` → `allBotsSkillInstructions`) uses the same commands per profile.
2. **What gets sent.** `skillsToInstall` filters the bundled skills to those whose recorded version/variant differs
   from the bundled one (`SkillLibrary.state`), so a current skill is not re-sent, but a sent one is always rewritten.
3. **Install backoff (0.6.0/0.6.1).** `finishSkillInstallChecks` compares the turn's block with what was asked
   for; anything unconfirmed becomes a `SkillInstallFailure` for that version/variant (15 min doubling to a day). A
   skill backing off is neither offered nor sent. It changes *when* an overwrite is sent, not whether it overwrites.
4. **Staged / signed updater (bootstrapped connection, `box-transport.json`).** `stagedSkillInstructions` verifies
   the signed bundle locally (`StagedInstall.prepare`, pinned roots, floors), ships the bytes and a `profiles.json`
   selection (name, coding_order, skills) through carrier sessions, and the box script merges that selection with the
   saved one and runs `swarmhub-update apply --staged`. The updater re-verifies, renders each profile's skills and, in
   `apply.apply_profile`, swaps in every skill whose live tree digest differs from the rendered one (atomic exchange,
   old tree kept in `.archive/swarmhub-update/previous/`). A live edit is just a differing digest: it is replaced. The
   app sends nothing while any skill on the connection backs off at the bundle's version, because the box re-applies
   all saved selections together. Signatures cover the bundle (keys, index, manifest, blobs), not `profiles.json`.

## What dev mode changes

One rule on both paths, decided on the box. With dev mode on for a profile, a skill is **kept** when
`~/.hermes/swarmhub/dev-overrides/<profile>/<skill>/` exists, or when its live folder is neither the bundled copy
about to be installed nor provably SwarmHub's last install: the baseline digest in
`~/.hermes/swarmhub/dev-baseline/<profile>/<skill>.sha256` (written after every dev-mode install) or, on the updater
path, the tree the updater bound in its profile record. The digest covers regular files (path, owner-exec bit,
SHA-256 of the bytes) and skips `__pycache__`, so umask and caches never read as edits.

- **Legacy:** each skill's commands are wrapped in a `swarmhub_dev check …; case $? in 0) <writes>; swarmhub_dev
  record …;; 3) echo KEPT marker;; *) echo FAILED marker;; esac`. The app reads the markers from the terminal
  result (`noteSkillDevTool`), skips recording kept skills and never counts them as failures.
- **Staged:** the profile row gains `dev_mode: true` (persisted in the box's profiles.json, so later runs honour it).
  Every staged request also carries the toggle of every bot the app knows on that connection (`dev_modes`, a
  profile → bool map in the stage command). The box merge (`StagedInstall.profileMerge`) sets or clears `dev_mode` on
  each saved row it names, so a signed install for bot B never drops bot A's dev mode, even when A turned it on after
  its own last request (cross-review 2026-10-21, HIGH). Rows the app does not know stay as saved.
  `devmode.run` wraps `apply_profile` with a `keep` predicate; kept skills keep their recorded version, the run stays
  applied/unchanged (so `current`), the bound tree is not moved onto the edit, and `status` lists them in the
  profile's `modified`. The app treats a listed skill as kept, not failed, so it never defers the connection.
- **Reset to bundled:** one request for one skill (`reset` in the row, or on the legacy path `swarmhub_dev clear`,
  the unguarded writes, then `swarmhub_dev reset`): installs exactly the bundled copy, deletes that skill's override
  folder (never through a link) and records the bundled digest as the baseline. On the legacy path `clear` first moves
  the live folder to `~/.hermes/swarmhub/dev-reset/<profile>/<skill>` (replacing the previous reset's copy), so files
  the bot added do not survive; `reset` records the digest only when the live folder equals the bundled copy, else
  the skill is reported failed with no baseline. The updater swaps whole trees, so its reset was already exact, and it
  strips `reset` before persisting profiles.json; a persisted one is ignored.
- **Off:** legacy commands and instructions and the profiles.json rows sent are byte-identical to before; no marker is
  read; the updater neither reads nor writes anything under `~/.hermes/swarmhub/dev-*`. The staged command text does
  change: it always carries the `dev_modes` map (all `False` when off), which leaves the merged profiles.json as before.

Hermes itself is not touched; new box state lives under `~/.hermes/swarmhub/`.

## Known limits

- **Skill with no stored hash (decided 2026-10-21: keep).** A skill installed before dev mode was turned on, and never
  applied by the updater, has no baseline. With dev mode on, if its live folder differs from the bundled copy (also
  normal for an older, untouched version) it is **kept**, not overwritten, and shown as "Modified locally" until Reset
  to bundled. Dev mode never guesses in favour of overwriting: the alternative would lose edits the bot made before the
  first dev-mode install. An untouched skill that happens to equal the bundled copy is written and gets its baseline,
  and on the signed path the updater's own record (bound trees) usually proves the skill is SwarmHub's.
- Turning dev mode off in the app reaches a bootstrapped box with the next staged request for any bot on that box;
  until then the box's saved profiles.json still has `dev_mode` (box timers are disabled today).
- Legacy streams without tool results cannot report kept skills: the box still keeps them, but the app then believes
  the manager's block. Session-chat streaming carries results.
- The legacy guard needs `python3` on the box (as the messages skill already does); without it nothing is written and
  the skill is reported failed.

## Verification

- Linux: `python3 -B -m unittest discover -s Tests/Updater -p 'test_*.py'` includes `test_devmode.py` (engine + CLI)
  and `test_devmode_guard.py` (runs the guard script and templates taken verbatim from `SkillDevMode.swift` under
  sh/dash/bash, and through the Hermes hardline-rule port), and `test_devmode_merge.py` (runs `profileMerge` taken
  verbatim from `StagedInstall.swift`, then the real `apply --staged`: a signed install for bot B keeps bot A's dev
  mode and A's edited skill; without the map it would be overwritten).
- Mac (not run here, no Swift toolchain): `SkillDevModeTests`, `SkillDevModeStagedTests`, and the extended
  `noShippedSkillTextTripsHermesHardlineGuard`. The digest vector `643ff4d5…` is pinned on both sides.
