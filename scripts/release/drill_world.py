"""The local world the P8a drills run in (CORE-PHASES.md P8a; drill.py): a publisher desk using the real release
tooling (build_bundle, publish, republish, channels, keys), a loopback static host, box consumers running the real
updater (`swarmhub_update.cli`, in process, plain http to loopback only) and app consumers standing in for the
SwarmHubCore UpdateClient (same verifier order and floors, data components only). TEST keys from public fixed
seeds only; everything lives in one temporary folder. Nothing reaches the real network. Not a test module."""

import datetime
import functools
import hashlib
import http.server
import io
import json
import os
from pathlib import Path
import shutil
import stat
import sys
import threading

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(ROOT / "Resources/Updater"))

import build_bundle  # noqa: E402
import channels  # noqa: E402
import jcs  # noqa: E402
import keys as keytool  # noqa: E402
import publish  # noqa: E402
import republish as republish_tool  # noqa: E402
import sign  # noqa: E402
import vector_world  # noqa: E402
import ed25519_ref  # noqa: E402
from swarmhub_update import cli, fetch, state as statefile, verify  # noqa: E402

NOW = "2026-10-20T12:00:00Z"  # the consumers' clock
EXPIRES = "2026-10-27T00:00:00Z"  # index expiry (issued + 7 days, plan default)
NOT_AFTER = "2027-01-01T00:00:00Z"  # release keys
ROOT_1, ROOT_2 = "TEST-root-1", "TEST-root-2"
RELEASE_1, RELEASE_2 = "TEST-release-1", "TEST-release-2"
HERMES_FIXTURE = ROOT / "Tests/Fixtures/hermes_v0.21.7_server.py"
FEEDBACK = ROOT / "Resources/Skills/swarmhub-feedback"
APP_VERSIONS = {"app": "0.6.2", "config_schema": "2", "ui_catalog": "1.3"}
LIMITS = dict(verify.DEFAULT_LIMITS)
NOTES_MD = """---
name: drill-notes
description: "Notes skill for the P8a channel drills. Installed by SwarmHub, v{{{{VERSION}}}}."
version: {version}
author: SwarmHub
---

# Drill notes

{text}
"""


class DrillError(AssertionError):
    pass


def check(condition, message):
    if not condition:
        raise DrillError(message)


def public_hex(key_id):
    return ed25519_ref.public_key(vector_world.seed(key_id)).hex()


# Content ---------------------------------------------------------------------------------------------------------

def write_source(folder, *, notes="Report drills plainly.", notes_version="1.0.0", order="claude,codex,hermes",
                 policy_version="1.0.0"):
    """A source tree and its layout: the real swarmhub-feedback skill (code: it has a script), a data skill
    `drill-notes` and a `policy` config for the apps. Returns the layout path (root = folder)."""
    folder = Path(folder)
    shutil.copytree(FEEDBACK, folder / "Skills/swarmhub-feedback",
                    ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
    (folder / "Skills/drill-notes").mkdir(parents=True)
    (folder / "Skills/drill-notes/SKILL.md").write_text(NOTES_MD.format(version=notes_version, text=notes))
    policy = {"schema": "swarmhub/policy-defaults/1", "codingOrder": order}
    (folder / "policy.json").write_text(json.dumps(policy, indent=2, sort_keys=True) + "\n")
    layout = {"schema": "swarmhub/bundle-layout/1", "requires": {"updater": ">=1.0"}, "components": [
        {"kind": "skill", "name": "swarmhub-feedback", "targets": ["box"],
         "sources": [{"from": "Skills/swarmhub-feedback"}]},
        {"kind": "skill", "name": "drill-notes", "targets": ["box"], "sources": [{"from": "Skills/drill-notes"}]},
        {"kind": "config", "name": "policy", "version": policy_version, "targets": ["mac", "ios"],
         "sources": [{"from": "policy.json"}]}]}
    path = folder / "layout.json"
    path.write_text(json.dumps(layout, indent=2))
    return path


# Publisher -------------------------------------------------------------------------------------------------------

class Desk:
    """The publisher's side: a published directory (`repo`), TEST key files and the pin file."""

    def __init__(self, tmp):
        self.tmp = Path(tmp)
        self.repo = self.tmp / "service"
        self.repo.mkdir(parents=True)
        self.keydir = self.tmp / "keys"
        self.keydir.mkdir()
        for key_id in (ROOT_1, ROOT_2, RELEASE_1, RELEASE_2):
            (self.keydir / (key_id + ".key.json")).write_text(json.dumps(keytool.test_key_document(key_id)))
        self.pins_bytes = jcs.canonical(keytool.pins_document(1, [(r, public_hex(r)) for r in (ROOT_1, ROOT_2)]))
        self.pins_path = self.tmp / "pins.json"
        self.pins_path.write_bytes(self.pins_bytes)
        self.keys_version, self.steps, self.sources = 0, 0, 0

    def signer(self, key_id):
        return sign.load_signer("file:" + str(self.keydir / (key_id + ".key.json")))

    def issued(self):
        """A fresh, increasing timestamp for each publishing step (all before the consumers' NOW)."""
        self.steps += 1
        start = datetime.datetime(2026, 10, 20, 0, 0, tzinfo=datetime.timezone.utc)
        return (start + datetime.timedelta(minutes=self.steps)).strftime("%Y-%m-%dT%H:%M:%SZ")

    def publish_keys(self, release_ids, roots=(ROOT_1,)):
        """Sign a new key manifest listing `release_ids` with the roots and put it on the service."""
        self.keys_version += 1
        body = keytool.key_manifest(self.keys_version, self.issued(),
                                    [(k, public_hex(k), ["bundle", "index"], NOT_AFTER) for k in release_ids])
        path = self.repo / "keys.json"
        previous = path.read_bytes() if path.exists() else None
        raw = keytool.sign_keys(jcs.canonical(body), self.pins_bytes, [self.signer(r) for r in roots],
                                previous_bytes=previous)
        publish.write_replace(path, raw)
        return raw

    def source(self, **kwargs):
        self.sources += 1
        folder = self.tmp / ("source-%d" % self.sources)
        return folder, write_source(folder, **kwargs)

    def publish(self, version, channel="canary", signer=RELEASE_1, rollout=100, **content):
        folder, layout = self.source(**content)
        issued = self.issued()
        body, blobs = build_bundle.build(version=version, label="drill.%d" % version, created=issued,
                                         previous=build_bundle.latest_published(self.repo), layout_path=layout,
                                         root=folder)
        return publish.publish_body(self.repo, body, {c["name"]: blobs[c["sha256"]] for c in body["components"]},
                                    signer=self.signer(signer), pins_bytes=self.pins_bytes, channel=channel,
                                    issued=issued, expires=EXPIRES, rollout_percent=rollout)

    def republish(self, old, new, channel="canary", signer=RELEASE_1):
        issued = self.issued()
        return republish_tool.republish(self.repo, old, new, signer=self.signer(signer), pins_bytes=self.pins_bytes,
                                        created=issued, channel=channel, issued=issued, expires=EXPIRES)

    def promote(self, source, target, signer=RELEASE_1, **kwargs):
        return channels.promote(self.repo, source, target, signer=self.signer(signer), pins_bytes=self.pins_bytes,
                                issued=self.issued(), expires=EXPIRES, **kwargs)

    def rollout(self, channel, version, percent, signer=RELEASE_1):
        return channels.rollout(self.repo, channel, version, percent, signer=self.signer(signer),
                                pins_bytes=self.pins_bytes, issued=self.issued(), expires=EXPIRES)

    def signed(self, rel):
        return jcs.loads((self.repo / rel).read_bytes())["signed"]

    def forge_index(self, folder, channel, lines, seq, signer):
        """An index signed by `signer` whatever the key manifest says (what a holder of a rotated-out key can
        make). Written into `folder`, never into the service."""
        body = {"schema": "swarmhub/index/1", "channel": channel, "seq": seq, "issued": self.issued(),
                "expires": EXPIRES, "lines": lines}
        path = Path(folder) / "channels" / (channel + ".json")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(sign.envelope(body, [self.signer(signer)]))


def tree(root, skip=()):
    """{relative path: (type, mode, sha256 or link)} under root, without paths under any `skip` prefix."""
    entries = {}
    for directory, folders, names in os.walk(root):
        for name in folders + names:
            full = os.path.join(directory, name)
            rel = os.path.relpath(full, root)
            if any(rel == s or rel.startswith(s + os.sep) for s in skip):
                continue
            info = os.lstat(full)
            value = (hashlib.sha256(Path(full).read_bytes()).hexdigest() if stat.S_ISREG(info.st_mode)
                     else os.readlink(full) if stat.S_ISLNK(info.st_mode) else None)
            entries[rel] = (stat.S_IFMT(info.st_mode), stat.S_IMODE(info.st_mode), value, info.st_ino)
    return entries


# Static host -----------------------------------------------------------------------------------------------------

class _Handler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):  # noqa: N802 - http.server API
        self.server.log.append(self.path)
        super().do_GET()

    def log_message(self, *args):
        pass


class Host:
    """A loopback static host serving `root` (the service layout), as a CDN would."""

    def __init__(self, root):
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0),
                                                      functools.partial(_Handler, directory=str(root)))
        self.server.daemon_threads = True
        self.server.log = []
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    @property
    def url(self):
        return "http://127.0.0.1:%d/" % self.server.server_address[1]

    @property
    def log(self):
        return self.server.log

    def close(self):
        self.server.shutdown()
        self.server.server_close()


def loopback_fetcher(origins, hosts=()):
    return fetch.Fetcher(origins, hosts, allow_loopback_http=True, proxies={}, timeout=5)


# Consumers -------------------------------------------------------------------------------------------------------

class Box:
    """A box: HOME with a Hermes stand-in, the admin pin file and the updater state, driven through cli.main."""

    CATEGORY = os.path.join("skills", "swarmhub")

    def __init__(self, tmp, name, pins_bytes, channel, install_id, skills=("swarmhub-feedback", "drill-notes")):
        self.name = name
        self.home = Path(tmp) / name
        self.hermes = self.home / ".hermes"
        self.state = self.home / ".local/state/swarmhub-update"
        agent = self.hermes / "hermes-agent/gateway/platforms"
        agent.mkdir(parents=True)
        shutil.copyfile(HERMES_FIXTURE, agent / "api_server.py")
        (self.hermes / "config.yaml").write_text("model: test\n")
        (self.hermes / ".env").write_text("API_SERVER_KEY=not-a-real-key\n")
        (self.hermes / "skills/other-category/keep").mkdir(parents=True)
        (self.hermes / "skills/other-category/keep/SKILL.md").write_text("---\nname: keep\n---\n")
        self.pins_path = self.home / "updater/pins.json"
        self.pins_path.parent.mkdir(parents=True)
        self.pins_path.write_bytes(pins_bytes)
        st = statefile.State(str(self.state))
        st.write_json({"channel": channel, "install_id": install_id}, "config.json")
        st.write_json({"schema": "swarmhub/profiles/1", "profiles": [
            {"name": "default", "coding_order": "claude,codex,hermes", "skills": list(skills)}]}, "profiles.json")
        self.hermes_before = tree(self.hermes, skip=(self.CATEGORY,))

    def run(self, *argv):
        out = io.StringIO()
        code = cli.main(["--state-dir", str(self.state), "--hermes-home", str(self.hermes), "--max-wait", "0"]
                        + list(argv), str(self.pins_path), now=NOW, out=out, fetcher=loopback_fetcher)
        return code, json.loads(out.getvalue())

    def pull(self, url):
        return self.run("pull", "--origin", url)

    def live(self, skill):
        """The installed SKILL.md bytes, or None."""
        path = self.hermes / self.CATEGORY / skill / "SKILL.md"
        return path.read_bytes() if path.exists() else None

    def applied(self):
        return statefile.State(str(self.state)).applied()

    def floors(self):
        return statefile.State(str(self.state)).floors()

    def skills_tree(self):
        return tree(self.hermes / self.CATEGORY)

    def assert_hermes_untouched(self):
        """Every Hermes file outside skills/swarmhub is byte-identical (CORE-PHASES.md, rules for every phase)."""
        now = tree(self.hermes, skip=(self.CATEGORY,))
        diff = sorted(p for p in set(now) | set(self.hermes_before) if now.get(p) != self.hermes_before.get(p))
        check(not diff, "%s: Hermes files changed: %s" % (self.name, diff))


class App:
    """Stand-in for the SwarmHubCore UpdateClient (P4a) on `mac`: the verified key manifest raises its floor first,
    then the chain is verified from the pins; an accept stores the data components as `current` (the old one
    becomes `previous`) and raises every floor; `no_update` raises the key and index floors. A local pin holds:
    checks still verify and raise key/index floors, but no bundle is applied (UpdateClient.pin, CORE-PLAN §2.2)."""

    def __init__(self, name, pins_bytes, channel, install_id, platform="mac"):
        self.name, self.pins, self.channel, self.install_id = name, pins_bytes, channel, install_id
        self.consumer = {"platform": platform, "versions": dict(APP_VERSIONS)}
        self.floors = {"keys_version": 0, "index_seq": 0, "bundle_version": 0}
        self.current = self.previous = self.pin = None

    def _raise(self, **values):
        for key, value in values.items():
            self.floors[key] = max(self.floors[key], value)

    def check(self, url):
        fetcher = loopback_fetcher([url])
        limit = LIMITS["max_signed_bytes"]
        try:
            keys = fetcher.get(url + "keys.json", limit)
            try:
                verify.verify_keys(keys, verify.verify_pins(self.pins, LIMITS), self.floors, LIMITS)
                self._raise(keys_version=jcs.loads(keys)["signed"]["version"])
            except verify.Reject:
                pass  # the full verification below reports it
            index = fetcher.get(url + "channels/%s.json" % self.channel, limit)
            result = verify.verify_release(
                self.pins, keys, index, channel=self.channel, now=NOW, floors=dict(self.floors),
                consumer=self.consumer, install_id=self.install_id, limits=LIMITS,
                fetch_manifest=lambda line: fetcher.get(url + "bundles/%d.json" % line["bundle_version"], limit),
                fetch_blob=lambda c: fetcher.get(url + "blobs/sha256/" + c["sha256"], c["size"]))
        except fetch.FetchError as error:
            return {"verdict": "reject", "stage": "fetch", "reason": error.reason}
        seq = jcs.loads(index)["signed"]["seq"] if result["verdict"] != "reject" else 0
        if result["verdict"] == "accept" and self.pin is None:
            self._raise(index_seq=seq, bundle_version=result["bundle_version"])
            self.previous = self.current
            self.current = {"bundle_version": result["bundle_version"], "blobs": result["blobs"]}
        elif result["verdict"] in ("accept", "no_update"):
            self._raise(index_seq=seq)
            if result["verdict"] == "accept":
                result = {"verdict": "no_update", "stage": "pin", "reason": "pinned"}
        return {k: v for k, v in result.items() if k not in ("manifest", "blobs")}

    def pin_previous(self):
        if self.pin == "previous":
            return  # already swapped (UpdateClient.pin)
        check(self.previous is not None, "%s: nothing to pin back to" % self.name)
        self.current, self.previous = self.previous, self.current
        self.pin = "previous"

    def clear_pin(self, url):
        """Release the hold and check (UpdateClient.clearPin). Without a newer accepted bundle, after `pin previous`,
        the bundle at the floor (the one pinned away from) is current again."""
        was, self.pin = self.pin, None
        result = self.check(url)
        if result["verdict"] != "accept" and was == "previous" and self.previous \
                and self.previous["bundle_version"] == self.floors["bundle_version"]:
            self.current, self.previous = self.previous, self.current
        return result
