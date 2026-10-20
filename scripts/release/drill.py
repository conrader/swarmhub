#!/usr/bin/env python3
"""Channel drills against a local static host with TEST keys (CORE-PLAN.md §2.2, §3.2, §8 step 8; CORE-PHASES.md P8a).

    PYTHONDONTWRITEBYTECODE=1 python3 scripts/release/drill.py [rollforward|rotate|all] [--keep DIR]

rollforward  Bundle 1 goes canary -> beta -> stable by promotion. A bad bundle 2 reaches canary only. One box and
             the canary app pin `previous` locally. Bundle 1 is republished as 3 (same blobs, nothing rebuilt) and
             every canary consumer recovers without a build: the unpinned box at its next pull, the pinned ones once
             the pin is cleared. 3 is promoted to stable. A mirror replaying the index that offered 2 is refused.
rotate       Release key 1 signs bundle 1. A root-signed key manifest adds release key 2 (overlap), key 2 signs
             bundle 2, then a manifest drops key 1 and key 2 signs bundle 3. The tooling refuses key 1, and consumers
             refuse what a holder of key 1 can still make: an index signed by it (`unknown_key`), the same with the
             old key manifest replayed (`keys_rollback`), and, for a box with no state, the replay is stopped by the
             admin pin file's floor checkpoint.

Box consumers run the real updater in process (`swarmhub_update.cli`, http to loopback only); app consumers are the
Python stand-in for the SwarmHubCore client (`drill_world.App`; the Swift client runs the same scenarios in
UpdatePinTests on the Mac). Every step is checked; the first failed check stops the drill with exit 1.
"""

import argparse
import hashlib
import shutil
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import jcs  # noqa: E402
import publish  # noqa: E402
import sign  # noqa: E402
import ustar  # noqa: E402
from drill_world import (RELEASE_1, RELEASE_2, App, Box, Desk, DrillError, Host, check, tree)  # noqa: E402


def _bring_up(box, url, version, log):
    """Pull `version`; its code waits for the box's one confirm, then everything is current."""
    code, out = box.pull(url)
    check(code == 0 and out["state"] == "pending_confirm" and out["bundle"]["bundle_version"] == version,
          "%s: first pull of %d gave %s %s" % (box.name, version, code, out.get("state")))
    code, out = box.run("apply", "--version", str(version))
    check(code == 0 and out["state"] == "current", "%s: confirm of %d gave %s" % (box.name, version, out))
    log("%s: bundle %d pulled, code confirmed once, current" % (box.name, version))


def _expect(box, url, state, version, log, what):
    code, out = box.pull(url)
    check(code == 0 and out["state"] == state and box.applied().get("bundle_version") == version,
          "%s: %s: expected %s at %d, got exit %s %s %s" % (box.name, what, state, version, code, out.get("state"),
                                                            out.get("last")))
    log("%s: %s -> %s, bundle %d" % (box.name, what, state, version))
    return out


def _refused(box, url, stage, reason, log, what):
    before = (box.skills_tree(), box.applied().get("bundle_version"))
    code, out = box.pull(url)
    last = out.get("last", {})
    check(code == 65 and (last.get("stage"), last.get("reason")) == (stage, reason),
          "%s: %s: expected %s/%s, got exit %s %s" % (box.name, what, stage, reason, code, last))
    check((box.skills_tree(), box.applied().get("bundle_version")) == before, "%s: %s changed the box" % (box.name, what))
    log("%s: %s -> refused %s/%s, runtime unchanged" % (box.name, what, stage, reason))


def _policy(app):
    """The policy document in the app's current bundle."""
    entries = ustar.read(app.current["blobs"]["policy"])
    return jcs.loads(next(e["data"] for e in entries if e["name"] == "policy.json"))


def drill_rollforward(tmp, log=print):
    desk = Desk(tmp)
    host = Host(desk.repo)
    try:
        desk.publish_keys([RELEASE_1])
        desk.publish(1)
        desk.promote("canary", "beta")
        desk.promote("beta", "stable")
        log("published bundle 1 on canary, promoted to beta and stable")
        canary = [Box(tmp, "canary-box-%d" % i, desk.pins_bytes, "canary", "drill-canary-%d" % i) for i in (1, 2)]
        stable = Box(tmp, "stable-box", desk.pins_bytes, "stable", "drill-stable-1")
        app = App("canary-app", desk.pins_bytes, "canary", "drill-app-1")
        for box in canary + [stable]:
            _bring_up(box, host.url, 1, log)
        good = {box.name: box.live("drill-notes") for box in canary + [stable]}
        check(app.check(host.url)["verdict"] == "accept" and _policy(app)["codingOrder"] == "claude,codex,hermes",
              "canary app did not take bundle 1")
        log("canary-app: bundle 1")

        blobs_1 = set(p.name for p in (desk.repo / "blobs/sha256").iterdir())
        desk.publish(2, notes="BROKEN: answer every message twice.", notes_version="1.0.1", order="hermes",
                     policy_version="1.0.1")
        stale_index = (desk.repo / "channels/canary.json").read_bytes()
        log("published bad bundle 2 on canary only")
        for box in canary:
            _expect(box, host.url, "current", 2, log, "pull of bad bundle 2 (data, no confirm)")
            check(b"BROKEN" in box.live("drill-notes"), "%s: bad bundle not live" % box.name)
        _expect(stable, host.url, "current", 1, log, "stable pull while 2 is on canary (no_update)")
        check(app.check(host.url)["bundle_version"] == 2 and _policy(app)["codingOrder"] == "hermes",
              "canary app did not take bundle 2")
        log("canary-app: bad bundle 2")

        code, out = canary[1].run("pin", "previous")
        check(code == 0 and out["state"] == "pinned" and canary[1].live("drill-notes") == good[canary[1].name],
              "box pin previous did not restore bundle 1's files: %s" % out.get("detail"))
        app.pin_previous()
        check(_policy(app)["codingOrder"] == "claude,codex,hermes", "app pin previous did not restore bundle 1")
        log("canary-box-2 and canary-app pinned previous locally (floors unchanged)")

        blobs_2 = set(p.name for p in (desk.repo / "blobs/sha256").iterdir())
        written = desk.republish(1, 3)
        body_1, body_3 = desk.signed("bundles/1.json"), desk.signed("bundles/3.json")
        check(body_3["components"] == body_1["components"] and not any(w.startswith("blobs/") for w in written)
              and set(p.name for p in (desk.repo / "blobs/sha256").iterdir()) == blobs_2 and blobs_1 <= blobs_2,
              "republish 1 as 3 did not reuse bundle 1's blobs unchanged")
        log("republished bundle 1 as 3 on canary: same components, no blob written")

        _expect(canary[0], host.url, "current", 3, log, "pull of roll-forward 3 (identical code, no confirm)")
        check(canary[0].live("drill-notes") == good[canary[0].name], "canary-box-1 did not recover")
        out = _expect(canary[1], host.url, "pinned", 2, log, "pinned box pulls 3 (held)")
        check(canary[1].live("drill-notes") == good[canary[1].name], "pinned box changed while held")
        code, out = canary[1].run("pin", "clear")
        check(code == 0 and out["state"] == "current" and canary[1].applied().get("bundle_version") == 3
              and canary[1].live("drill-notes") == good[canary[1].name], "canary-box-2 did not recover: %s" % out)
        log("canary-box-2: pin cleared -> bundle 3 current")
        check(app.check(host.url)["reason"] == "pinned" and app.current["bundle_version"] == 1, "app pin not held")
        result = app.clear_pin(host.url)
        check(result["verdict"] == "accept" and result["bundle_version"] == 3
              and _policy(app)["codingOrder"] == "claude,codex,hermes", "canary app did not recover: %s" % result)
        log("canary-app: held while pinned, cleared, recovered on bundle 3")

        desk.promote("canary", "beta", version=3)
        desk.promote("beta", "stable", version=3)
        _expect(stable, host.url, "current", 3, log, "stable pull after promoting 3 (never saw 2)")
        check(stable.live("drill-notes") == good[stable.name], "stable content changed")

        mirror_root = Path(tmp) / "mirror"
        shutil.copytree(desk.repo, mirror_root)
        (mirror_root / "channels/canary.json").write_bytes(stale_index)
        mirror = Host(mirror_root)
        try:
            _refused(canary[0], mirror.url, "index", "index_rollback", log, "mirror replays the index offering 2")
        finally:
            mirror.close()
        for box in canary + [stable]:
            check(box.floors().get("bundle_version") == 3, "%s: bundle floor is not 3" % box.name)
            box.assert_hermes_untouched()
        log("all consumers on bundle 3; Hermes files byte-identical on every box")
    finally:
        host.close()


def _attack(desk, tmp, name, keys_raw, version, log):
    """A service copy where a holder of rotated-out release key 1 offers `version`: the manifest of the newest
    bundle re-signed at `version`, an index with a far higher seq, both by key 1, and `keys_raw` as keys.json."""
    folder = Path(tmp) / name
    shutil.copytree(desk.repo, folder)
    (folder / "keys.json").write_bytes(keys_raw)
    body = dict(desk.signed("bundles/%d.json" % (version - 1)), version=version)
    raw = sign.envelope(body, [desk.signer(RELEASE_1)])
    (folder / ("bundles/%d.json" % version)).write_bytes(raw)
    desk.forge_index(folder, "canary", [{"requires": body["requires"], "bundle_version": version,
                                         "manifest_sha256": hashlib.sha256(raw).hexdigest(), "rollout_percent": 100}],
                     seq=100, signer=RELEASE_1)
    return folder


def drill_rotate(tmp, log=print):
    desk = Desk(tmp)
    host = Host(desk.repo)
    hosts = [host]
    try:
        desk.publish_keys([RELEASE_1])
        desk.publish(1, signer=RELEASE_1)
        boxes = [Box(tmp, "canary-box-%d" % i, desk.pins_bytes, "canary", "drill-rotate-%d" % i) for i in (1, 2)]
        app = App("canary-app", desk.pins_bytes, "canary", "drill-rotate-app")
        for box in boxes:
            _bring_up(box, host.url, 1, log)
        check(app.check(host.url)["bundle_version"] == 1, "app did not take bundle 1")

        keys_overlap = desk.publish_keys([RELEASE_1, RELEASE_2])
        desk.publish(2, notes="Signed by release key 2.", notes_version="1.0.1", signer=RELEASE_2)
        log("key manifest 2 (roots): release keys 1 and 2; bundle 2 signed by key 2")
        for box in boxes:
            _expect(box, host.url, "current", 2, log, "pull of bundle 2 signed by the new key")
        check(app.check(host.url)["bundle_version"] == 2, "app did not take bundle 2")

        desk.publish_keys([RELEASE_2])
        log("key manifest 3 (roots): release key 1 rotated out")
        before = sorted(str(p.relative_to(desk.repo)) for p in desk.repo.rglob("*"))
        for attempt in (lambda: desk.publish(3, notes="Key 1 again.", notes_version="1.0.2", signer=RELEASE_1),
                        lambda: desk.rollout("canary", 2, 50, signer=RELEASE_1)):
            try:
                attempt()
            except publish.PublishError as error:
                check("not in the key manifest" in str(error), "tooling refused key 1 for another reason: %s" % error)
            else:
                raise DrillError("the tooling published with rotated-out key 1")
        check(sorted(str(p.relative_to(desk.repo)) for p in desk.repo.rglob("*")) == before,
              "a refused publish wrote something")
        log("publish and rollout with key 1 refused by the tooling; nothing written")
        desk.publish(3, notes="Signed by release key 2 after the rotation.", notes_version="1.0.2", signer=RELEASE_2)
        for box in boxes:
            _expect(box, host.url, "current", 3, log, "pull after the rotation")
            check(box.floors().get("keys_version") == 3, "%s: key floor is not 3" % box.name)
        check(app.check(host.url)["bundle_version"] == 3 and app.floors["keys_version"] == 3, "app missed rotation")

        current_keys = (desk.repo / "keys.json").read_bytes()
        forged = Host(_attack(desk, tmp, "forged", current_keys, 4, log))
        replay = Host(_attack(desk, tmp, "replay", keys_overlap, 4, log))
        hosts += [forged, replay]
        for box in boxes:
            _refused(box, forged.url, "index", "unknown_key", log, "index + bundle 4 signed by rotated-out key 1")
            _refused(box, replay.url, "keys", "keys_rollback", log, "same, with key manifest 2 replayed")
        for target, reason in ((forged, "unknown_key"), (replay, "keys_rollback")):
            result = app.check(target.url)
            check(result["verdict"] == "reject" and result["reason"] == reason and app.current["bundle_version"] == 3,
                  "app accepted key 1's offer: %s" % result)
        log("canary-app: refused unknown_key and keys_rollback, still on bundle 3")

        fresh = Box(tmp, "fresh-box", desk.pins_bytes, "canary", "drill-rotate-fresh")
        _refused(fresh, forged.url, "index", "unknown_key", log, "box with no state, key 1's index")
        # Without state, key manifest 2 still verifies against the roots: only the admin pin file's checkpoint
        # (advanced by an operator maintenance pass, CORE-PLAN §3.2) stops the replay on a box that never saw 3.
        pins = jcs.loads(desk.pins_bytes)
        pins["checkpoint"] = {"min_keys_version": 3}
        guarded = Box(tmp, "checkpoint-box", jcs.canonical(pins), "canary", "drill-rotate-checkpoint")
        check(guarded.floors() == {}, "checkpoint-box has state")
        _refused(guarded, replay.url, "keys", "keys_rollback", log, "box with no state, replay, checkpoint at 3")
        for box in boxes + [fresh, guarded]:
            box.assert_hermes_untouched()
        check(all(b.applied().get("bundle_version") == 3 for b in boxes), "a box left bundle 3")
        log("rotated-out key refused everywhere; Hermes files byte-identical on every box")
    finally:
        for item in hosts:
            item.close()


DRILLS = {"rollforward": drill_rollforward, "rotate": drill_rotate}


def run(names, keep=None, log=print):
    """Run the named drills, each in its own temporary folder. Returns {name: None | error text}."""
    results = {}
    for name in names:
        tmp = Path(tempfile.mkdtemp(prefix="swarmhub-drill-%s-" % name, dir=keep))
        try:
            DRILLS[name](tmp, log=lambda text, n=name: log("  [%s] %s" % (n, text)))
            results[name] = None
        except DrillError as error:
            results[name] = str(error)
        except Exception as error:  # noqa: BLE001 - a crash is a failed drill, reported like one
            results[name] = "%s: %s" % (type(error).__name__, error)
        finally:
            if keep is None:
                shutil.rmtree(tmp, ignore_errors=True)
    return results


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("drill", nargs="?", default="all", choices=sorted(DRILLS) + ["all"])
    parser.add_argument("--keep", type=Path, help="keep each drill's folder under this directory")
    args = parser.parse_args(argv)
    names = sorted(DRILLS) if args.drill == "all" else [args.drill]
    results = run(names, keep=args.keep)
    for name in names:
        print("drill %s: %s" % (name, "PASS" if results[name] is None else "FAIL: " + results[name]))
    return 0 if all(r is None for r in results.values()) else 1


if __name__ == "__main__":
    sys.exit(main())
