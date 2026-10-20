# Box updater bootstrap: operator runbook (P2d)

Status: phase P2d of plan B (`CORE-PLAN.md` §3.2, §3.5; `CORE-PHASES.md`). Code: `Resources/Updater/install-bootstrap.sh`.
Test: `Tests/Scripts/updater-bootstrap-test.sh` (Docker with a separate `bot` account; falls back to unprivileged
checks without Docker). The package comes from P2c (`BASELINE.md`). Tested with TEST keys only. **No real box has been
installed.** Installing on a real box is Konrad's step (below).

The installer is a plain POSIX sh script. It uses no model and no network. It writes only under the prefix (default
`/opt/swarmhub-updater`, the same on Linux and macOS). It never writes in Hermes paths, never touches the bot's home and
restarts nothing. Bootstrap trust comes from an operator running it at the console or over authenticated SSH. A model
turn cannot establish it.

## What gets installed

```
/opt/swarmhub-updater/                       root-owned, 0755; nothing in it is writable by the bot account
  bin/swarmhub-update -> ../current/bin/swarmhub-update   the fixed path the bot and the Mac transport call
  current, previous -> releases/<UTC time>-<sha12>         switched by rename (atomic)
  releases/<id>/bin/swarmhub-update          the package launcher; line 1 rewritten to "#!<python> -IBS"
  releases/<id>/swarmhub_update/*.py         the package's updater, byte-identical (see files.sha256)
  releases/<id>/pins.json                    roots, threshold, floor checkpoint, revoked key IDs
  releases/<id>/files.sha256, INSTALL.txt    what was installed and from which package digest
  bootstrap.log                              one line per install / maintenance / rollback
```

The launcher names a vetted interpreter by absolute path, so there is no `PATH` lookup. It runs that interpreter with
`-I` (ignores `PYTHON*` variables, the script folder, the cwd and the user site), `-S` (no site-packages or `.pth`
files) and `-B` (no bytecode). The installer accepts an interpreter only when it, every folder above it and every
`sys.path` entry it uses are root-owned and not writable by group or others. On macOS it also checks for ACLs that
grant writing. It picks `/usr/bin/python3` or `/usr/local/bin/python3` on Linux. On macOS it picks the Command Line
Tools python (`xcrun -f python3`), never the `/usr/bin/python3` shim, which `DEVELOPER_DIR` can redirect. Use
`--python PATH` to name another one. Always call the updater by its absolute path. Running `python3 <launcher>` skips
these protections.

## Install (and upgrade)

1. On the Mac, open Settings → Advanced → About → "Box updater package". Export `swarmhub-updater-<v>.tar` and its
   `.sha256`, and keep the window open: **the SHA-256 shown there is the trust root.** The `.sha256` file travels with
   the package, so on its own it proves nothing.
2. Copy both files and `install-bootstrap.sh` to the box (for example `scp`), then on the box run:
   ```
   sha256sum swarmhub-updater-<v>.tar          # macOS: shasum -a 256 swarmhub-updater-<v>.tar
   sudo sh install-bootstrap.sh install --package swarmhub-updater-<v>.tar --sha256 <value read off the Mac>
   ```
   The installer copies the package into a root-private folder and hashes that copy before extracting or running
   anything. It stops, with nothing written, if the copy's hash differs from `--sha256` or the `.sha256` file beside
   the package disagrees. It also stops if the package has unexpected members, links or special files, or if its pins
   name a `TEST-` root, since debug builds use public seeds (`--allow-test-keys` exists for test machines only). Then
   it checks the pin file loads and the updater starts, and only after that switches `current`.
3. Installing again with a newer app's package is an upgrade. The new pins keep the **higher** of the installed and
   packaged checkpoints, plus every revoked key ID. The old release stays as `previous`.
4. As the bot account, run `/opt/swarmhub-updater/bin/swarmhub-update status`. After the first apply, `pins.protected`
   in the status is `true`.

P2c ships no separate signature for the package. The digest shown by the signed app is the check. The installer
script itself is not inside the package, so take it from the same trusted checkout or release as the app.

## Verify

```
sudo sh install-bootstrap.sh verify
```

This checks that nothing under the prefix is owned by, or writable for, another account, that the launcher link is
right, that the installed files match `files.sha256`, that the interpreter still passes the checks above, and that
`pins.json` loads. It prints the checkpoint. Record bootstrap as complete only from this output, never from a bot's
message.

## Maintenance pass (advance the checkpoint)

```
sudo sh install-bootstrap.sh maintenance --min-bundle-version N --min-index-seq N --min-keys-version N --revoke KEY_ID
```

Any subset of the options works, and with none it just prints the current checkpoint. Values only go up: a value below
the installed one is refused with nothing changed. A revoked key ID is never removed. The new `pins.json` is written
beside the old one, loaded with the updater's own pin reader, then renamed into place. Take the numbers from the
published index and bundle (or from `swarmhub-update status` → `floors.effective` after a verified apply). Remember
the bot can raise its own state floors, so a number read from the box is a hint only. The updater enforces
max(checkpoint, state) and refuses checkpoint-revoked keys, even after the bot wipes its state.

## Roll back, uninstall

- `sudo sh install-bootstrap.sh rollback` makes `previous` current again. The code goes back, the checkpoint does not:
  the current checkpoint and revocations are merged into the restored `pins.json` first.
- `sudo sh install-bootstrap.sh uninstall` removes the prefix only. The bot's update state
  (`~/.local/state/swarmhub-update`) and installed skills stay as they are. Without the updater, the box is back to
  today's model-mediated install, which has no integrity guarantee.

## What Konrad must do for a real box

1. Build a release app with real keys (P1b, then the P2c release build). The installer refuses a package that pins
   `TEST-` roots.
2. Make sure Hermes runs as an account that cannot become root. On a Mac where Hermes runs under an admin account,
   that account can `sudo` and replace anything here, so the protection then only holds against the model, not the
   account. Use a standard (non-admin) account for Hermes if the guarantee matters.
3. On each box, at the console or over his own SSH session: run steps 1–2 of the install, then `verify`, and keep the
   output (package digest, checkpoint) with the box's records. On a Mac, install the Command Line Tools first
   (`xcode-select --install`) unless he names another root-owned python with `--python`.
4. Decide the maintenance cadence (for example after each key manifest or index he publishes) and run the pass as above.

## Tests

```
sh Tests/Scripts/updater-bootstrap-test.sh                          # Docker if usable, else fallback
BOOTSTRAP_TEST_MODE=fallback BOOTSTRAP_SH=/bin/dash sh Tests/Scripts/updater-bootstrap-test.sh
```

Docker (`python:3.12-slim`, `--network none`, root plus a `bot` account) covers these cases:

- an altered or tampered package is refused before anything is extracted or run (with a positive control showing the
  planted code does run when its own digest is given);
- a disagreeing `.sha256` file, a non-root run, bot-writable prefixes and interpreters, and TEST roots are refused;
- 15 write attempts by the bot against the updater, pins and links all fail;
- with hostile `PYTHONPATH`, `PYTHONHOME`, `PYTHONSTARTUP`, cwd modules, user-site `usercustomize`/`.pth` and a fake
  `python3`/`env` first on `PATH`, no planted code runs (controls show each plant fires without the protections);
- the bot applies the TEST baseline through the installed updater;
- maintenance raise, refusal to lower, and revocation work, and the bot is refused even after wiping its state;
- an upgrade and a rollback keep the checkpoint;
- `verify` catches a changed file;
- there is no bytecode, the bot's home is unchanged by the installer, Hermes fixture files are byte-identical, and
  uninstall removes only the prefix.

The fallback runs the same cases as the invoking user (`--unprivileged-test`, prefix under `$HOME`) and skips the one
that needs a second account.

macOS has not been run here. On the MacBook, run `sh Tests/Scripts/updater-bootstrap-test.sh` (fallback, without
Docker). It exercises the Darwin paths: `xcrun` interpreter choice, `shasum`, BSD `tar`/`find`/`ls` and ACL parsing.
