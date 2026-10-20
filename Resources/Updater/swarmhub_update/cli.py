"""`swarmhub-update` (CORE-PLAN.md §3.2, §3.4, decision 2; phase P2b). No network code: bundles arrive as a staged
folder (pull is P3a, the Mac transport P4b).

    swarmhub-update status                     print the status file (read-only; `swarmctl update-status` too)
    swarmhub-update verify [--staged DIR]      verify a staged folder, or re-verify the stored bundle (read-only)
    swarmhub-update apply --staged DIR         verify, persist floors, store, apply data, park code (pending_confirm)
    swarmhub-update apply [--version N]        the local confirm: apply the stored bundle's waiting code and data
    swarmhub-update check                      re-verify the stored bundle and apply what is due (no confirm)
    swarmhub-update pin previous|current|clear revert to previous and hold / hold at current / release the hold

Common options: --state-dir (default `$XDG_STATE_HOME/swarmhub-update`), --hermes-home (default ~/.hermes),
--max-wait SECONDS (idle wait bound). The pin file path is not an option: `main(argv, pins_path)` gets it from the
installed launcher (`<prefix>/pins.json`, admin-owned).

Floors: each stage that verifies raises its persisted floor (keys version, index seq), and the bundle floor rises when
a bundle verifies and its apply starts; checks use max(checkpoint, state) and the pin file's revoked key IDs.
A local pin holds updates and never lowers a floor. Output is one JSON object on stdout. Exit codes: 0 done
(including pending_confirm, pinned, no_update), 64 usage, 65 refused (verification or a confirm for another
version), 70 an apply failed or awaits recovery, 75 deferred (busy box or another run), 78 pin file unusable.
"""

import argparse
import contextlib
import fcntl
import json
import os
import sys

from . import apply, bundle, pins as pinfile, policy, runner, stage, state as statefile, verify

EX_OK, EX_USAGE, EX_REFUSED, EX_FAILED, EX_TEMPFAIL, EX_CONFIG = 0, 64, 65, 70, 75, 78
EXIT = {"current": EX_OK, "pending_confirm": EX_OK, "pinned": EX_OK, "held": EX_OK, "deferred": EX_TEMPFAIL,
        "failed": EX_FAILED, "recovery_pending": EX_FAILED}


class Usage(Exception):
    pass


class _Parser(argparse.ArgumentParser):
    def error(self, message):
        raise Usage(message)


def parser():
    top = _Parser(prog="swarmhub-update", description="Swarm Hub box updater (no network in this version).")
    top.add_argument("--state-dir", default=None)
    top.add_argument("--hermes-home", default=None)
    top.add_argument("--max-wait", type=float, default=None)
    commands = top.add_subparsers(dest="command", parser_class=_Parser)
    commands.add_parser("status")
    commands.add_parser("verify").add_argument("--staged", default=None)
    confirm = commands.add_parser("apply")
    confirm.add_argument("--staged", default=None)
    confirm.add_argument("--version", type=int, default=None)
    commands.add_parser("check")
    commands.add_parser("pin").add_argument("mode", choices=("previous", "current", "clear"))
    return top


@contextlib.contextmanager
def _locked(state_dir):
    os.makedirs(state_dir, 0o700, exist_ok=True)
    fd = os.open(os.path.join(state_dir, "cli.lock"), os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield
    finally:
        os.close(fd)


def _verdict(error):
    if isinstance(error, verify.NoUpdate):
        return {"verdict": "no_update", "stage": error.stage, "reason": error.reason}
    if isinstance(error, verify.Reject):
        return {"verdict": "reject", "stage": error.stage, "reason": error.reason}
    return {"verdict": "reject", "stage": "source", "reason": "source_unreadable", "detail": str(error)}


def _persist_progress(st, progress, stored):
    """Raise floors for the stages that verified; keep the stored bundle verifiable with a newer key manifest, and
    with a newer index that still lists it."""
    values = {"keys": "keys_version", "index": "index_seq"}
    st.raise_floors(**{values[kind]: number for kind, _, number in progress})
    if stored is None:
        return
    meta, keys, _, _ = stored
    try:
        stored_keys = bundle.signed_version(keys, "keys", "version")
    except (verify.Reject, KeyError, TypeError):
        stored_keys = 0  # unreadable stored copy: the newer verified one replaces it
    for kind, raw, number in progress:
        if kind == "keys" and number > stored_keys:
            st.refresh_bundle(meta["bundle_version"], keys=raw)
        if kind == "index":
            lines = verify.parse_signed(raw, "index", bundle.LIMITS)["signed"]["lines"]
            if any(line["bundle_version"] == meta["bundle_version"]
                   and line["manifest_sha256"] == meta["manifest_sha256"] for line in lines):
                st.refresh_bundle(meta["bundle_version"], index=raw)


def _stored_floors(box):
    floors = pinfile.effective_floors(box.pins.checkpoint, box.state.floors())
    # The stored index was checked against the floor when it was stored; only the checkpoint bounds it now.
    return dict(floors, index_seq=box.pins.checkpoint["index_seq"])


def verify_stored(box, consumer, config):
    stored = box.state.latest()
    if stored is None:
        return None
    meta, keys, index, manifest = stored
    floors = pinfile.effective_floors(box.pins.checkpoint, box.state.floors())
    if meta["bundle_version"] < floors["bundle_version"]:
        raise verify.Reject("index", "bundle_rollback")

    def blob(component):
        data = box.state.blob(component["sha256"])
        if data is None:
            raise OSError("stored blob %s missing or altered" % component["sha256"])
        return data
    return bundle.run(lambda: keys, lambda: index, lambda line: manifest, blob, pins=box.pins,
                      floors=_stored_floors(box), now=box.now, channel=config["channel"], consumer=consumer,
                      install_id=config.get("install_id", ""), stored_version=meta["bundle_version"])


def _staged_readers(box, source, stored):
    def manifest(line):
        path = os.path.join(source.folder, "bundles", "%d.json" % line["bundle_version"])
        if not os.path.lexists(path) and stored is not None and stored[0]["bundle_version"] == line["bundle_version"]:
            return stored[3]
        return source.manifest(line)

    def blob(component):
        if not os.path.lexists(os.path.join(source.folder, "blobs", "sha256", component["sha256"])):
            data = box.state.blob(component["sha256"])
            if data is not None:
                return data
        return source.blob(component)
    return manifest, blob


def cmd_verify(box, args):
    config = box.state.read_json("config.json", default={})
    config.setdefault("channel", statefile.DEFAULT_CHANNEL)
    consumer = _consumer(config)  # read-only: no install_id or config is created here
    try:
        if args.staged is None:
            verified = verify_stored(box, consumer, config)
            if verified is None:
                return {"verdict": "none", "detail": "no stored bundle"}, EX_OK
        else:
            stored = box.state.latest()
            source = bundle.Staged(args.staged, config["channel"])
            manifest, blob = _staged_readers(box, source, stored)
            verified = bundle.run(source.keys, source.index, manifest, blob, pins=box.pins,
                                  floors=pinfile.effective_floors(box.pins.checkpoint, box.state.floors()),
                                  now=box.now, channel=config["channel"], consumer=consumer,
                                  install_id=config.get("install_id", ""), stored=stored[0] if stored else None)
    except (verify.Reject, verify.NoUpdate, OSError) as error:
        verdict = _verdict(error)
        return verdict, EX_OK if verdict["verdict"] == "no_update" else EX_REFUSED
    record = box.state.applied()
    now, waiting = policy.split(verified.apply, record["components"], runner.is_confirmed(record, verified))
    return {"verdict": "accept", "bundle_version": verified.version, "refresh": verified.refresh,
            "apply": [c["name"] for c in verified.apply], "skipped": verified.skipped,
            "would_apply_now": [c["name"] for c in now],
            "pending_confirm": runner.pending_confirm(verified, waiting)}, EX_OK


def _consumer(config):
    versions = {"updater": runner.VERSION}
    if isinstance(config.get("hermes_version"), str) and verify.VERSION.fullmatch(config["hermes_version"]):
        versions["hermes"] = config["hermes_version"]
    return {"platform": "box", "versions": versions}


def _finish(box, command, verdict, run=None, verified=None, stale=None):
    status = runner.write_status(box, command, verdict, run, verified, stale)
    if run is None:
        code = EX_OK if verdict["verdict"] in ("no_update", "none") else EX_REFUSED
    else:
        code = EXIT[run["state"]]
    return status, code


def cmd_apply_staged(box, args):
    st, config = box.state, box.state.config()
    consumer, stored, progress = st.consumer(runner.VERSION), st.latest(), []
    source = bundle.Staged(args.staged, config["channel"])
    try:
        profiles = source.profiles()
        if profiles is not None:
            statefile.check_profiles(profiles)
    except (ValueError, OSError) as error:
        return _finish(box, "apply --staged", {"verdict": "reject", "stage": "profiles", "reason": "schema_invalid",
                                               "detail": str(error)})
    manifest, blob = _staged_readers(box, source, stored)
    try:
        verified = bundle.run(source.keys, source.index, manifest, blob, pins=box.pins,
                              floors=pinfile.effective_floors(box.pins.checkpoint, st.floors()), now=box.now,
                              channel=config["channel"], consumer=consumer, install_id=config["install_id"],
                              stored=stored[0] if stored else None, progress=progress)
    except (verify.Reject, verify.NoUpdate, OSError) as error:
        _persist_progress(st, progress, stored)
        verdict = _verdict(error)
        return _finish(box, "apply --staged", verdict, stale=True if verdict["reason"] == "index_expired" else None)
    _persist_progress(st, progress, stored)
    if profiles is not None:
        st.write_json(profiles, "profiles.json")
    for data in verified.blobs.values():
        st.put_blob(data)
    if verified.refresh:
        st.refresh_bundle(verified.version, keys=verified.keys, index=verified.index)
    else:
        st.store_bundle({"bundle_version": verified.version, "manifest_sha256": verified.manifest_sha256,
                         "label": verified.label, "verified_at": box.now}, verified.keys, verified.index,
                        verified.manifest_raw)
    st.raise_floors(bundle_version=verified.version)  # the apply starts now, even if code waits for the confirm
    run = runner.apply_bundle(box, verified)
    return _finish(box, "apply --staged", {"verdict": "accept", "bundle_version": verified.version,
                                           "refresh": verified.refresh}, run, verified, stale=False)


def cmd_stored(box, args, confirm):
    command = "apply" if confirm else "check"
    config = box.state.config()
    try:
        verified = verify_stored(box, box.state.consumer(runner.VERSION), config)
    except (verify.Reject, verify.NoUpdate, OSError) as error:
        verdict = _verdict(error)
        return _finish(box, command, verdict, stale=True if verdict["reason"] == "index_expired" else None)
    if verified is None:
        return _finish(box, command, {"verdict": "none", "detail": "nothing staged; this updater has no network "
                                                                   "fetch (pull arrives in P3a)"})
    if confirm and args.version is not None and args.version != verified.version:
        return _finish(box, command, {"verdict": "reject", "stage": "confirm", "reason": "version_changed",
                                      "detail": "confirm was for %d, the stored bundle is %d" %
                                                (args.version, verified.version)})
    run = runner.apply_bundle(box, verified, confirm=confirm)
    return _finish(box, command, {"verdict": "accept", "bundle_version": verified.version}, run, verified, False)


def cmd_pin(box, args):
    st = box.state
    record = st.applied()
    if args.mode == "clear":
        record.pop("pin", None)
        st.save_applied(record)
        return cmd_stored(box, args, confirm=False)
    results, reverted = {}, set()
    if args.mode == "previous":
        for entry in runner.profiles_for(box):
            previous = os.path.join(stage.work_dir(stage.category_dir(box.hermes_home, entry["name"])), "previous")
            names = {n[:-len(".absent")] if n.endswith(".absent") else n
                     for n in (os.listdir(previous) if os.path.isdir(previous) else [])}
            result = apply.revert(box.hermes_home, st.root, entry["name"], max_wait=box.max_wait, poll=box.poll)
            results[entry["name"]] = result
            if result.status == "reverted":
                reverted |= names
        for name in reverted:  # applied again when the pin is cleared (the same code needs no new confirm)
            if isinstance(record["components"].get(name), dict):
                record["components"][name]["reverted"] = True
    record["pin"] = {"mode": args.mode, "at": box.now, "bundle_version": record.get("bundle_version", 0)}
    st.save_applied(record)
    failed = [r for r in results.values() if r.status not in ("reverted", "unchanged")]
    run = {"state": "pinned", "waiting": {}, "detail": "; ".join("%s %s: %s" % (r.profile, r.status, r.detail)
                                                                 for r in failed) or "pinned (%s)" % args.mode}
    status, _ = _finish(box, "pin " + args.mode, {"verdict": "pinned", "mode": args.mode}, run)
    return status, EX_FAILED if failed else EX_OK


def main(argv, pins_path, now=None, out=None):
    """Entry point for the launcher (and tests, which pass `now` and their own pin file)."""
    out = out if out is not None else sys.stdout
    try:
        args = parser().parse_args(argv)
        if args.command is None:
            raise Usage("choose a command: status, verify, apply, check, pin")
    except Usage as error:
        print(json.dumps({"error": "usage", "detail": str(error)}), file=out)
        return EX_USAGE
    st = statefile.State(args.state_dir or statefile.default_state_dir())
    hermes = args.hermes_home or os.path.join(os.path.expanduser("~"), ".hermes")
    if args.command == "status":
        print(json.dumps(st.status() or {"schema": statefile.STATUS_SCHEMA, "state": "unknown",
                                         "detail": "no status yet"}, sort_keys=True), file=out)
        return EX_OK
    box = runner.Box(hermes, st, None, now or runner.utc_now(),
                     **({} if args.max_wait is None else {"max_wait": args.max_wait}))
    try:
        box.pins = pinfile.load(pins_path)
    except pinfile.PinError as error:
        print(json.dumps({"verdict": "reject", "stage": "pins", "reason": "pins_unusable", "detail": str(error)}),
              file=out)
        return EX_CONFIG
    try:
        result, code = _dispatch(box, args, st)
    except Exception as error:  # noqa: BLE001 - reported as JSON; the next run recovers (apply.recover)
        result, code = {"error": "internal", "detail": "%s: %s" % (type(error).__name__, error)}, EX_FAILED
    print(json.dumps(result, sort_keys=True), file=out)
    return code


def _dispatch(box, args, st):
    if args.command == "verify":
        result, code = cmd_verify(box, args)
    else:
        try:
            with _locked(st.root):
                if args.command == "apply" and args.staged is not None:
                    if args.version is not None:
                        raise Usage("--version is for the confirm (apply without --staged)")
                    result, code = cmd_apply_staged(box, args)
                elif args.command in ("apply", "check"):
                    result, code = cmd_stored(box, args, confirm=args.command == "apply")
                else:
                    result, code = cmd_pin(box, args)
        except BlockingIOError:
            result, code = {"state": "deferred", "detail": "another swarmhub-update run is active"}, EX_TEMPFAIL
        except Usage as error:
            result, code = {"error": "usage", "detail": str(error)}, EX_USAGE
    return result, code
