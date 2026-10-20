# Box updater bootstrap: operator runbook (P2d)

Status: phase P2d of plan B (`CORE-PLAN.md` §3.2, §3.5; `CORE-PHASES.md`). Code: `Resources/Updater/install-bootstrap.sh` and its sibling `bootstrap-preflight.sh`.
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
files) and `-B` (no bytecode). Python reads its library (for example `encodings`) while starting, before any code
it is given, so the installer checks the interpreter on disk **before running it at all**: the binary, every folder
above it, its prefix, the `lib`/`lib64` folders, `libpython` and `pythonNN.zip`, and the whole
`lib*/python3.N` library trees must be root-owned and not writable by group or others. Every path is resolved one
name at a time from `/`: each folder it enters and each link it passes (every hop of every link, also links met inside a
link's target) must pass that check, so a protected link cannot lead through a link or folder the bot controls. A link
loop, more than 40 hops or anything unreadable is refused. Link targets are read without stripping bytes; any
control character (including a newline) in a path component or target is refused. Links inside the library trees are followed and their
targets checked the same way; a link to a folder outside the tree is refused. Start-up overrides that `-I -S` do not
turn off are refused: a `pyvenv.cfg`, a `._pth` file, `pybuilddir.txt` or a `Modules` folder (build tree) in the bin
folder, the prefix or a framework's `Resources/Python.app/Contents/MacOS` (where a framework's `bin/python3.N` really
starts Python; that whole `Resources` tree must be trusted too), a `lib` folder beside the binary, and any
`lib*/python3NN.zip` in a folder above the prefix (Python searches upward for it), or a `lib*/python3.N/lib-dynload`
above the prefix when the prefix has none. Python 3.14+ built with a shared `libpython` also reads `<libpython>._pth`
and looks around the `libpython` folder, so a `._pth` or a `lib`/`lib64` folder beside any `libpython` in the
prefix's `lib*/` or `lib*/*/` is refused. The actual shared library is also located **before Python runs**: on Linux,
`readelf` (binutils) reads the ELF headers and a trusted glibc loader's `--list` resolves the dependencies without
executing the binary or library constructors; on macOS, `otool -L` and its `LC_RPATH` commands resolve dylibs and
frameworks, including the framework app-bundle binary. Its library and folder pass the same trust walk and startup
override checks. Unknown, ambiguous, unsupported or unresolved linkage, a library outside the resolved interpreter
prefix, and shadow `lib`/`lib64` folders between its folder and the prefix are refused. A framework's normal
prefix-level `lib` remains allowed and checked. Static Python builds with no shared libpython remain supported. Linux
needs binutils installed; missing inspection tools fail closed. Explicit ELF and dyld search folders, including
absent earlier candidates, must also be protected so another account cannot plant a replacement library there. The binary's own standard
library must sit beside the resolved binary
(`lib/python3.N/os.py` for the N in its name `python3.N`, or the only one there), else Python would look elsewhere. Only then is the interpreter run (empty environment, cwd `/`, `-I -S -B`), and every
`sys.path` entry it reports is checked again. On macOS it also checks for ACLs that grant writing. It picks `/usr/bin/python3` or `/usr/local/bin/python3` on Linux. On macOS it picks the Command Line
Tools python (`xcrun -f python3`), never the `/usr/bin/python3` shim, which `DEVELOPER_DIR` can redirect. Use
`--python PATH` to name another one. Always call the updater by its absolute path. Running `python3 <launcher>` skips
these protections.

## Install (and upgrade)

1. On the Mac, open Settings → Advanced → About → "Box updater package". Export `swarmhub-updater-<v>.tar` and its
   `.sha256`, and keep the window open: **the SHA-256 shown there is the trust root.** The `.sha256` file travels with
   the package, so on its own it proves nothing.
2. Copy both files, `install-bootstrap.sh` and `bootstrap-preflight.sh` (keep the two scripts together) to the box (for example `scp`), then on the box run:
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
scripts are not inside the package, so take both from the same trusted checkout or release as the app.

## Verify

```
sudo sh install-bootstrap.sh verify
```

This checks that nothing under the prefix is owned by, or writable for, another account, that every link in it
resolves inside the prefix, that the launcher link is right, that the installed files match `files.sha256`, that the interpreter still passes the checks above, and that
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

Native linkage fixtures need a C compiler on the test host. Docker (`python:3.12`, including binutils, `--network none`, root plus a `bot` account) covers these cases. That mode runs only in
the container the test itself starts (it passes `--inside-container` and a launch marker, and checks for root and
`/.dockerenv`); anywhere else it refuses, since it creates `bot` and uses `/opt/swarmhub-updater`. A second container
runs the suite as root without the marker and checks that it fell back, created no account and left
`/opt/swarmhub-updater` alone.

- an altered or tampered package is refused before anything is extracted or run (with a positive control showing the
  planted code does run when its own digest is given);
- a disagreeing `.sha256` file, a non-root run, bot-writable prefixes and interpreters, and TEST roots are refused;
- an interpreter whose `encodings/__init__.py` the bot can write, or which links to a file the bot can write, is
  refused before it runs (a control shows the planted code runs when the binary is started directly), and so is one
  that a protected `python3._pth`, `pybuilddir.txt` or a `python3NN.zip` above the prefix steers to encodings the bot
  can write (each with the same control); also refused: a `python3.N` binary with only another version's library
  beside it, one without `lib-dynload` that has one above its prefix, one with a `._pth` beside a `libpython` in its
  prefix, one reached through a link hop the bot controls, and a link loop. Further cases exercise a link targeting
  `python3` followed by a newline (with an execution control), and a real dynamic dependency in a custom folder with
  a startup override, shadow library, writable library, external target, missing dependency or two libpythons;
- 15 write attempts by the bot against the updater, pins and links all fail;
- with hostile `PYTHONPATH`, `PYTHONHOME`, `PYTHONSTARTUP`, cwd modules, user-site `usercustomize`/`.pth` and a fake
  `python3`/`env` first on `PATH`, no planted code runs (controls show each plant fires without the protections);
- the bot applies the TEST baseline through the installed updater;
- maintenance raise, refusal to lower, and revocation work, and the bot is refused even after wiping its state;
- an upgrade and a rollback keep the checkpoint;
- `verify` catches a changed file, and a link in the install to a bot-writable file, to a protected file outside the
  prefix, or to a folder outside it;
- there is no bytecode, the bot's home is unchanged by the installer, Hermes fixture files are byte-identical, and
  uninstall removes only the prefix.

The fallback runs the same cases as the invoking user (`--unprivileged-test`, a private prefix under `$HOME`) and skips
the one that needs a second account. Run as root, it still uses only that private prefix and creates no account (it
then also skips the non-root refusal).

The focused suite `sh Tests/Scripts/updater-bootstrap-preflight-test.sh` also tests control bytes in names, static
linkage, constructor-free library discovery and synthetic macOS dependency tables. It exempts system/ancestor nodes
from ownership checks for restricted sandboxes; fixture nodes use the shipped checks. The full suite above retains
all ownership checks.

macOS has not been run here. On the MacBook, run `PYTHONDONTWRITEBYTECODE=1 BOOTSTRAP_TEST_MODE=fallback sh Tests/Scripts/updater-bootstrap-test.sh`
and `PYTHONDONTWRITEBYTECODE=1 sh Tests/Scripts/updater-bootstrap-preflight-test.sh`. It exercises the Darwin paths: `xcrun` interpreter choice and the on-disk library check of a framework
python (it must find `lib/python3.N/os.py` beside the resolved binary), `shasum`, BSD `tar`/`find`/`ls` and ACL
parsing. The five fake-interpreter cases with a start-up control skip there if a copied framework binary does not
load the copied library. The Command Line Tools python must still be picked (its layout is root-owned and not
writable); a refusal of it names the file or folder that failed.
