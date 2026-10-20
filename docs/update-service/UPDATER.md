# Box updater command line (P2b)

Status: phase P2b of plan B (`CORE-PLAN.md` §3.2, §3.4, decision 2; `CORE-PHASES.md`). Code:
`Resources/Updater/bin/swarmhub-update` and `Resources/Updater/swarmhub_update/{cli,state,pins,bundle,policy,runner}.py`
on top of the P2a engine (`APPLY.md`). Tests: `Tests/Updater/test_cli.py`, `test_floors.py`. There is no network code:
bundles arrive as a staged folder. Pull (P3a) and the Mac transport (P4b) will fill the same layout. Nothing here has
run on a real box. All keys in the tests are TEST keys.

## Commands

| Command | What it does | Writes |
| --- | --- | --- |
| `status` | prints `status.json` | nothing |
| `verify [--staged DIR]` | verifies a staged folder, or re-verifies the stored bundle, and says what would apply now and what would wait | nothing |
| `apply --staged DIR` | verifies the folder, raises floors, stores the bundle, applies data, parks code in `pending_confirm` | state, `skills/swarmhub/` |
| `apply [--version N]` | the local confirm: re-verifies the stored bundle and applies its waiting code and data together. With `--version`, it refuses if the stored bundle is another version | same |
| `check` | re-verifies the stored bundle and applies what is due, such as a run deferred by a busy box. It never confirms | same |
| `pin previous\|current\|clear` | `previous` reverts each profile's last transaction and holds; `current` holds; `clear` releases the hold and runs `check` | same |

Options: `--state-dir` (default `$XDG_STATE_HOME/swarmhub-update`, else `~/.local/state/swarmhub-update`),
`--hermes-home` (default `~/.hermes`), `--max-wait SECONDS` (idle wait bound, default 600). Output is one JSON object.
Exit codes: 0 done (also `pending_confirm`, `pinned`, `held`, `no_update`), 64 usage, 65 refused, 70 an apply failed or
awaits recovery, 75 deferred (busy box or another run holds `cli.lock`), 78 pin file unusable.

The pin file path is not an option. The launcher reads `<prefix>/pins.json` beside `<prefix>/bin/swarmhub-update` and
imports only `<prefix>/swarmhub_update/`. It runs `python3 -I -B` and re-executes itself that way if started otherwise.

## Staged folder

The service layout (`SCHEMAS.md` §1): `keys.json`, `channels/<channel>.json`, `bundles/<version>.json`,
`blobs/sha256/<sha256>`. Optionally there is `profiles.json`:
`{"schema":"swarmhub/profiles/1","profiles":[{"name","coding_order","skills":[...]|null}]}`, saved to the state when
the bundle verifies. When the line is the stored bundle's own version, the folder may hold only `keys.json` and the
index. That is a refresh, used to renew an expired index for a bundle whose code is still waiting.

## Floors, checkpoint, revocation

- Each stage that verifies raises its persisted floor: the key manifest `version`, then the index `seq`, even if a
  later stage fails. The bundle floor rises when a bundle verifies and its apply starts, even while its code waits.
- Every check uses max(checkpoint, state) per floor and refuses the pin file's `revoked_key_ids`. Wiping or lowering
  `floors.json` therefore never goes below the checkpoint, and a revoked key stays refused with no state at all.
- The stored bundle is re-verified on every use, because the state is bot-writable. That covers signatures, revocation,
  key `not_after` and index `expires` against the system clock, a line still listed, compatible and in rollout, and
  blob hashes. Its index `seq` is bounded by the checkpoint, because a newer index may no longer list it. A newer
  verified key manifest replaces the stored one, and a newer index replaces the stored index when it still lists the
  same manifest.
- A local pin never lowers a floor.
- `min_bundle_version` works like the persisted floor: it is the last applied bundle. A bundle at exactly that version
  is `already_applied`, unless it is the stored bundle being refreshed. `revoked_key_ids` covers release keys. A root
  is removed by installing a new pin file, not by listing it there.

Reasons beyond `SCHEMAS.md` §10: `bundle_withdrawn` (the stored bundle's line is gone from its index),
`source_unreadable` (a staged or stored file is missing, oversized or altered), `version_changed` (a confirm for
another version), `pins_unusable`.

## Decision 2

Per component (`policy.py`):

- Data applies at once, also beside code.
- Code whose archive the box has not applied waits for one confirm of this bundle version on this box. The confirm
  records the version and the manifest SHA-256. A different signed manifest with the same version is not covered.
- Data waits when a `requires_component` edge, direct or through other components, leads to waiting code at a version
  the box has not applied.
- A confirm applies the waiting code and data in one run. Data counts as applied only if the code it needs applied
  too.
- Re-applying the identical archive the box already applied, for example after `pin previous` is cleared, is not new
  code.

What applies how:

- Skills go through the P2a engine per profile: render, checks, idle wait, atomic swap, `previous`.
- The rendered SKILL.md description advertises the component version (`SwarmHub, v<version>`). A skill that does not
  advertise it is refused.
- `manager-prompts` supplies the manager text. When it changes, the manager skill is rendered again.
- `tool`, `config` and `ui` components are recorded and kept in the state's blob store. Nothing on the box reads them
  yet; P1a ships no tool components.

Without `profiles.json`, only skills already installed in a profile are updated. A skill that renders a coding order
is held there (state `held`), because the box does not record which order it was installed with.

## State and status

The state directory holds `floors.json`, `config.json` (`channel`, random `install_id`, optional `hermes_version`),
`profiles.json`, `latest.json` + `bundles/<version>/`, `blobs/sha256/`, `applied.json` (components, `bundle_version`,
`confirmed_version`, `pin`), `profiles/<name>.json` (engine records) and `status.json`.

`status.json` (`swarmhub/update-status/1`) has these members: `state` (`current`, `pending_confirm`, `deferred`,
`held`, `failed`, `recovery_pending`, `pinned`, `unknown`), `detail`, `bundle`, `applied_bundle_version`, `components`,
`pending_confirm` (`bundle_version`, `code`, `data` with `waits_for`), `skipped`, `profiles` (engine status,
`reload_pending`, the version each live SKILL.md advertises), `reload_pending`, `floors` (state, checkpoint,
effective), `pins` (path, sha256, `protected`, roots, checkpoint, revoked IDs), `pin`, `stale`, `last` (this
command's verdict) and `updater`. `swarmctl update-status` prints the same file read-only.
