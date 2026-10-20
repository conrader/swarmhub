# Box updater command line (P2b, P3a)

Status: phases P2b and P3a of plan B (`CORE-PLAN.md` §3.2, §3.4, §6, decision 2; `CORE-PHASES.md`). Code:
`Resources/Updater/bin/swarmhub-update` and `Resources/Updater/swarmhub_update/{cli,state,pins,bundle,policy,runner}.py`
on top of the P2a engine (`APPLY.md`); pull adds `{fetch,channel,compat}.py` and the timer templates in
`Resources/Updater/units/`. Tests: `Tests/Updater/test_cli.py`, `test_floors.py`, `test_pull.py`, `test_fetch.py`.
Bundles arrive by `pull` or as a staged folder (the Mac transport, P4b). Pull has run only against local `http.server`
fixtures; nothing here has run on a real box or against a real update host. All keys in the tests are TEST keys.

## Commands

| Command | What it does | Writes |
| --- | --- | --- |
| `status` | prints `status.json` | nothing |
| `verify [--staged DIR]` | verifies a staged folder, or re-verifies the stored bundle, and says what would apply now and what would wait | nothing |
| `apply --staged DIR` | verifies the folder, raises floors, stores the bundle, applies data, parks code in `pending_confirm` | state, `skills/swarmhub/` |
| `apply [--version N]` | the local confirm: re-verifies the stored bundle and applies its waiting code and data together. With `--version`, it refuses if the stored bundle is another version | same |
| `check` | re-verifies the stored bundle and applies what is due, such as a run deferred by a busy box. It never confirms | same |
| `pull [--origin URL ...]` | fetches the key manifest, the channel index, then the selected bundle manifest and the blobs it does not hold, over HTTPS, and continues as `apply --staged` | same as `apply --staged` |
| `pin previous\|current\|clear` | `previous` reverts each profile's last transaction and holds; `current` holds; `clear` releases the hold and runs `check` | same |

Channel promotion, rollout edits, the app-side pin and the drills that exercise `pull` and `pin`: `CHANNELS.md` (P8a).

Options: `--state-dir` (default `$XDG_STATE_HOME/swarmhub-update`, else `~/.local/state/swarmhub-update`),
`--hermes-home` (default `~/.hermes`), `--max-wait SECONDS` (idle wait bound, default 600). Output is one JSON object.
Exit codes: 0 done (also `pending_confirm`, `pinned`, `held`, `no_update`), 64 usage, 65 refused, 70 an apply failed or
awaits recovery, 75 deferred (busy box or another run holds `cli.lock`) or no origin reachable, 78 pin file unusable.

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
  blob hashes. Its index `seq` must meet max(checkpoint, state); a newer signed index that withdraws the bundle
  therefore prevents an older stored index from authorizing its pending code. A newer
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
- A confirm applies the waiting code and data in one run. Failed, held or dropped components block dependent data
  before installation, including through transitive dependencies. Data counts as applied only if the code it needs
  applied too.
- Re-applying the identical archive the box already applied, for example after `pin previous` is cleared, is not new
  code.

What applies how:

- Skills go through the P2a engine per profile: render, checks, idle wait, atomic swap, `previous`.
- The rendered SKILL.md description advertises the component version (`SwarmHub, v<version>`). A skill that does not
  advertise it is refused.
- `manager-prompts` supplies the manager text. When it changes, the manager skill is rendered again; if the new
  prompts cannot install, every skill using `{{MANAGER_TEXT}}` uses the previously applied prompts (or cannot install
  if there are none).
- `tool`, `config` and `ui` components are recorded and kept in the state's blob store. Nothing on the box reads them
  yet; P1a ships no tool components.

Without `profiles.json`, only skills already installed in a profile are updated. A skill that renders a coding order
is held there (state `held`), because the box does not record which order it was installed with.
If a skill is held for an unknown coding order in any target profile, it is skipped in all profiles for that run
to avoid partial updates that the box-wide component record cannot represent.

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

P4b adds `profiles.<name>.variants`, the coding-order variants recorded after successful rendering, bound to the
live skill tree's digest. A revert or manual edit invalidates that variant reading. See `STAGED-INSTALL.md` for the
Mac chunk transport through temporary stock Hermes sessions, fixed updater path, operator record, and staging/terminal-status read-back rules.
That transport bounds its temporary DB/WAL snapshot to 64 MiB combined and deletes it before invoking the updater;
failure paths remove the staging folder too. Its diagnostic receipt carries the updater's exact stdout and nonzero
exit back to the Mac (including lock deferral, which leaves this status file unchanged). The Mac caches the failure
reason without treating an older successful status as installation confirmation. This changes no updater CLI exits.

## Pull (P3a)

`swarmhub-update pull` is what the timer runs. It never confirms: code components still stop at `pending_confirm`.

- **Origins** come from `config.json` `origins` (primary first, then mirrors), or `--origin`. Each is a base URL with
  the service layout (`SCHEMAS.md` §1). None configured → verdict `none`, nothing changes. They are not a trust anchor:
  everything fetched is verified against the admin-owned pins, floors and checkpoint. `allow_hosts` lists extra https
  hosts a redirect may reach (a mirror's download host).
- **Transport** (`fetch.py`, the only module that opens a connection): HTTPS only, certificate and host name verified
  against the system trust store, TLS 1.2+. Every request sends `Cache-Control: no-store` and `Pragma: no-cache`, no
  credentials or cookies. Redirects are followed only to an allowlisted origin, at most 3 hops; otherwise
  `redirect_refused` and nothing is fetched from the target. The `Location` is normalised before that check: control
  characters (tab, CR and LF included) are refused in the raw value, before anything is stripped; bytes outside
  RFC 3986's unreserved and reserved sets (and a `%` that starts no escape) are percent-encoded, a relative value is
  resolved against the current URL, and the result must be https without userinfo.
  Signed files are capped at `max_signed_bytes`, a blob at
  its declared size (+1 byte, so a longer body is `blob_size_mismatch`); a larger `Content-Length` is refused before
  reading. Redirect bodies are closed without reading, so they spend none of that byte budget. The response stream
  never reads ahead (`peek` and unbounded reads are refused). One 300 s deadline per file covers every step of every
  hop: DNS lookup, TCP connect (each address), proxy `CONNECT`, TLS handshake, response headers and body reads
  (including chunk framing). Each step times out after at most 30 s or what is left of the deadline, so a file ends
  within the deadline plus 1 s (`DEADLINE_SLACK`, scheduling slack); then it is `timeout` and the next origin is tried.
- **Order:** `keys.json`, `channels/<channel>.json`, then only the selected line's `bundles/<version>.json` and the blobs
  of components targeted at the box and compatible with it. What the box already holds verified is not fetched again
  (the stored manifest for a refresh; blobs in the state's blob store, hash-checked when read).
- **Line selection and rollout** are `verify.select_line` and `verify.rollout_bucket`, the implementation the signed
  vectors pin (`SCHEMAS.md` §6): `bucket = uint64_be(SHA-256(install_id + "\n" + bundle_version)[0:8]) mod 100`,
  included when `bucket < rollout_percent`. `install_id` is the random local one in `config.json`, so a box decides the
  same way on every run. The verdict's `lines` shows each line's `bucket`, `in_rollout`, `compatible` and unmet axes.
- **Failures keep the runtime:** host down, a refused redirect or an oversize answer is `stage: fetch` (exit 75, retried
  on the next run); a bad signature, an old index (`index_rollback`), a tampered blob and the rest of `SCHEMAS.md` §10
  are refused as with `apply --staged` (exit 65). An origin that fails is reported in `attempts` and the next one is
  tried; floors only rise, so a mirror replaying an old index is refused. A verified `no_update` ends the pull. An
  expired index sets `stale: true` (exit 65) and changes nothing else; the next current index sets it back to false.
- **Hermes version** (`compat.py`, read-only): Hermes' own source of truth is `hermes_cli.__version__` (its `/health`
  returns it). The updater reads `<install>/hermes_cli/__init__.py` as text (at most 256 KiB) and takes the single
  `__version__ = "<version>"` literal; it never imports Hermes, runs it or calls it. Install folders, in order:
  `config.json` `hermes_install_dir`, `$HERMES_INSTALL_DIR`, `<hermes home>/hermes-agent`,
  `/usr/local/lib/hermes-agent` (the Hermes installer's layouts). Then `config.json` `hermes_version` (operator-set).
  Otherwise Hermes is unknown: a line or component that declares a `hermes` range is unsatisfied. A skipped component
  reads `{"name", "reason": "incompatible", "axes": ["hermes"], "detail": "incompatible: hermes"}`; the rest apply.
  `status.json` `hermes` records `{version, source}` of the last run.
- **Timers** (`Resources/Updater/units/`), both disabled by default and templates (`@PREFIX@` is the admin-owned install
  prefix, filled by the operator bootstrap, P2d): `swarmhub-update.service` + `swarmhub-update.timer` (systemd `--user`,
  every 6 h with up to 30 min random delay, 15 min after boot) and `com.konrad.swarmhub.update.plist` (launchd agent,
  `Disabled` true, every 6 h, not at load). Copying them in place does not start anything; enabling them is P3b.
