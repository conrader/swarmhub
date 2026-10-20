"""P1a: sign-keys, publish and republish into a local directory, verified with the P0b library (swarmhub_update).

    python3 scripts/test_release_publish.py
"""

import copy
import hashlib
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/release"))

import build_bundle  # noqa: E402
import jcs  # noqa: E402
import keys  # noqa: E402
import publish  # noqa: E402
import republish  # noqa: E402
import sign  # noqa: E402
import vector_world  # noqa: E402
from publish import PublishError  # noqa: E402
from sign import p0b  # noqa: E402

ISSUED, EXPIRES, NOW = "2026-10-20T12:00:00Z", "2026-10-27T12:00:00Z", "2026-10-21T00:00:00Z"
BOX = {"platform": "box", "versions": {"updater": "1.0.0", "hermes": "0.21.7"}}
MAC = {"platform": "mac", "versions": {"app": "0.6.2", "ui_catalog": "1.3", "config_schema": "2"}}
IOS = {"platform": "ios", "versions": {"app": "0.6.2", "ui_catalog": "1.3", "config_schema": "2"}}
BOX_APPLY = ["swarmhub-coding", "swarmhub-feedback", "swarmhub-manager", "swarmhub-messages", "manager-prompts"]


class CountingSigner(sign.Signer):
    """Wraps a signer and records every key that was asked to sign."""

    used = []

    def __init__(self, inner):
        self.inner, self.key_id = inner, inner.key_id

    def public_key(self):
        return self.inner.public_key()

    def sign(self, message):
        CountingSigner.used.append(self.key_id)
        return self.inner.sign(message)


class Service:
    """A temp workspace: TEST key files, 1-of-2 pins, a root-signed keys.json, an empty published directory."""

    def __init__(self, test, threshold=1):
        self.dir = Path(tempfile.mkdtemp(prefix="p1a-publish-"))
        test.addCleanup(shutil.rmtree, self.dir, True)
        self.keydir = self.dir / "keys"
        self.keydir.mkdir()
        self.repo = self.dir / "repo"
        self.repo.mkdir()
        for key_id in ("TEST-root-1", "TEST-root-2", "TEST-release-1", "TEST-rogue"):
            (self.keydir / key_id).write_text(json.dumps(keys.test_key_document(key_id)), encoding="utf-8")
        roots = [(k, vector_world.public_hex(k)) for k in ("TEST-root-1", "TEST-root-2")]
        self.pins = jcs.canonical(keys.pins_document(threshold, roots))
        self.manifest_body = keys.key_manifest(1, "2026-10-01T00:00:00Z", [
            ("TEST-release-1", vector_world.public_hex("TEST-release-1"), ["bundle", "index"], "2027-01-01T00:00:00Z")])
        if threshold == 1:
            (self.repo / "keys.json").write_bytes(
                keys.sign_keys(jcs.canonical(self.manifest_body), self.pins, [self.signer("TEST-root-1")]))

    def signer(self, key_id):
        return sign.load_signer(f"file:{self.keydir / key_id}")

    def publish(self, body, blobs, signer=None, **options):
        args = dict(signer=signer or self.signer("TEST-release-1"), pins_bytes=self.pins, channel="stable",
                    issued=ISSUED, expires=EXPIRES)
        args.update(options)
        return publish.publish_body(self.repo, body, blobs, **args)

    def build_and_publish(self, version=1, previous=None, **options):
        body, blobs = build_bundle.build(version=version, label=f"2026.10.{version}", created=ISSUED,
                                         previous=previous)
        named = {c["name"]: blobs[c["sha256"]] for c in body["components"]}
        self.publish(body, named, **options)
        return body, named

    def read(self, rel):
        return (self.repo / rel).read_bytes()

    def snapshot(self):
        return {str(p.relative_to(self.repo)): p.read_bytes() for p in sorted(self.repo.rglob("*")) if p.is_file()}

    def verify(self, consumer=BOX, floors=None, channel="stable"):
        """P0b verify_release over the published directory, as a consumer would fetch it."""
        def fetch_manifest(line):
            return self.read(f"bundles/{line['bundle_version']}.json")

        def fetch_blob(component):
            return self.read(f"blobs/sha256/{component['sha256']}")
        return p0b.verify_release(self.pins, self.read("keys.json"), self.read(f"channels/{channel}.json"),
                                  fetch_manifest=fetch_manifest, fetch_blob=fetch_blob, channel=channel, now=NOW,
                                  floors=floors or {"keys_version": 1, "index_seq": 1, "bundle_version": 0},
                                  consumer=consumer, install_id="TEST-install-0001")


class PublishTests(unittest.TestCase):
    def test_bundle_from_resources_verifies_with_p0b_on_box_mac_and_ios(self):
        service = Service(self)
        body, blobs = service.build_and_publish()
        box = service.verify(BOX)
        self.assertEqual((box["verdict"], box["reason"], box["bundle_version"]), ("accept", "ok", 1))
        self.assertEqual(box["apply"], BOX_APPLY)
        self.assertEqual(box["skipped"], [])
        self.assertEqual(box["blobs"], {name: blobs[name] for name in BOX_APPLY})
        self.assertEqual(service.verify(MAC)["apply"], ["manager-prompts", "policy"])
        self.assertEqual(service.verify(IOS)["apply"], ["policy"])
        self.assertTrue(box["manifest"]["code_bearing"])

    def test_publishing_needs_only_the_release_key(self):
        service = Service(self)
        for root in ("TEST-root-1", "TEST-root-2"):
            (service.keydir / root).unlink()  # no root material anywhere while publishing
        CountingSigner.used = []
        service.build_and_publish(signer=CountingSigner(service.signer("TEST-release-1")))
        self.assertEqual(set(CountingSigner.used), {"TEST-release-1"})
        self.assertEqual(service.verify()["verdict"], "accept")

    def test_root_unknown_or_mismatched_signers_are_refused_and_nothing_is_written(self):
        service = Service(self)
        body, blobs = build_bundle.build(version=1, label="x", created=ISSUED, previous=None)
        named = {c["name"]: blobs[c["sha256"]] for c in body["components"]}
        impostor = sign.FileKeySigner("TEST-release-1", vector_world.seed("TEST-rogue"))  # right id, wrong key
        cases = [(service.signer("TEST-root-1"), "root key"), (service.signer("TEST-rogue"), "not in the key manifest"),
                 (impostor, "public key differs")]
        for signer, message in cases:
            with self.assertRaisesRegex(PublishError, message):
                service.publish(body, named, signer=signer)
        self.assertEqual(sorted(service.snapshot()), ["keys.json"])
        with self.assertRaisesRegex(PublishError, "expired"):
            service.publish(body, named, issued="2027-01-01T00:00:00Z", expires="2027-01-08T00:00:00Z")

    def test_wrong_key_signature_is_rejected_by_p0b(self):
        service = Service(self)
        service.build_and_publish()
        self.assertEqual(service.verify()["verdict"], "accept")
        doc = jcs.loads(service.read("bundles/1.json"))
        forged = sign.FileKeySigner("TEST-rogue", vector_world.seed("TEST-rogue"))
        doc["signatures"] = [{"key_id": "TEST-release-1", "sig": sign.signature_entry(forged, doc["signed"])["sig"]}]
        raw = jcs.canonical(doc)
        (service.repo / "bundles/1.json").write_bytes(raw)
        index = jcs.loads(service.read("channels/stable.json"))["signed"]
        index["lines"][0]["manifest_sha256"] = hashlib.sha256(raw).hexdigest()
        (service.repo / "channels/stable.json").write_bytes(sign.envelope(index, [service.signer("TEST-release-1")]))
        verdict = service.verify()
        self.assertEqual((verdict["verdict"], verdict["stage"], verdict["reason"]), ("reject", "manifest", "bad_signature"))

    def test_tampered_blob_is_rejected_by_p0b(self):
        service = Service(self)
        body, _ = service.build_and_publish()
        self.assertEqual(service.verify()["verdict"], "accept")
        target = next(c for c in body["components"] if c["name"] == "swarmhub-messages")
        path = service.repo / "blobs/sha256" / target["sha256"]
        data = bytearray(path.read_bytes())
        data[600] ^= 0x01  # one byte inside a file body, same length
        path.write_bytes(bytes(data))
        verdict = service.verify()
        self.assertEqual((verdict["verdict"], verdict["stage"], verdict["reason"]), ("reject", "component", "blob_hash_mismatch"))

    def test_tampered_build_blob_is_refused_before_anything_is_written(self):
        service = Service(self)
        body, blobs = build_bundle.build(version=1, label="x", created=ISSUED, previous=None)
        named = {c["name"]: blobs[c["sha256"]] for c in body["components"]}
        named["policy"] = named["policy"].replace(b"claude,codex,hermes", b"hermes,codex,claude")
        with self.assertRaisesRegex(PublishError, "policy: P0b verifier refused blob_hash_mismatch"):
            service.publish(body, named)
        self.assertEqual(sorted(service.snapshot()), ["keys.json"])

    def test_published_objects_are_immutable_and_versions_only_increase(self):
        service = Service(self)
        body, blobs = service.build_and_publish()
        before = service.snapshot()
        with self.assertRaisesRegex(PublishError, "not above the published 1"):
            service.build_and_publish(1)
        second = copy.deepcopy(body)
        second["version"] = 2
        blob_path = service.repo / "blobs/sha256" / body["components"][0]["sha256"]
        blob_path.write_bytes(b"other bytes")
        changed = service.snapshot()
        with self.assertRaisesRegex(PublishError, "never overwritten"):
            service.publish(second, blobs)
        self.assertEqual(service.snapshot(), changed)  # nothing written, index untouched
        blob_path.write_bytes(before[str(blob_path.relative_to(service.repo))])
        service.publish(second, blobs)
        self.assertEqual(service.read("bundles/1.json"), before["bundles/1.json"])

    def test_index_lines_seq_and_order(self):
        service = Service(self)
        v1, _ = service.build_and_publish()
        service.build_and_publish(2, previous=v1, line_requires={"updater": ">=2.0"})
        index = jcs.loads(service.read("channels/stable.json"))["signed"]
        self.assertEqual(index["seq"], 2)
        self.assertEqual([(l["bundle_version"], l["requires"]) for l in index["lines"]],
                         [(1, {"updater": ">=1.0"}), (2, {"updater": ">=2.0"})])
        self.assertEqual(service.verify()["bundle_version"], 1)  # updater 1.0.0 stays on its compatibility line
        with self.assertRaisesRegex(PublishError, "seq 2 must be above"):
            service.build_and_publish(3, previous=v1, seq=2)
        service.build_and_publish(3, previous=v1, replace_lines=True, rollout_percent=0)
        index = jcs.loads(service.read("channels/stable.json"))["signed"]
        self.assertEqual([(l["bundle_version"], l["rollout_percent"]) for l in index["lines"]], [(3, 0)])
        self.assertEqual(service.verify()["reason"], "not_in_rollout")

    def test_publish_is_reproducible(self):
        trees = []
        for _ in range(2):
            service = Service(self)
            service.build_and_publish()
            trees.append(service.snapshot())
        self.assertEqual(trees[0], trees[1])

    def test_production_mode_refuses_test_trust(self):
        service = Service(self)
        with self.assertRaisesRegex(PublishError, "production mode refuses TEST keys"):
            publish.load_trust(service.repo, service.pins, production=True)
        body, blobs = build_bundle.build(version=1, label="x", created=ISSUED, previous=None)
        with self.assertRaisesRegex(PublishError, "production mode refuses TEST keys"):
            service.publish(body, {c["name"]: blobs[c["sha256"]] for c in body["components"]}, production=True)


class RepublishTests(unittest.TestCase):
    def setUp(self):
        self.service = Service(self)
        self.v1, self.blobs1 = self.service.build_and_publish(1)
        self.v1_raw = self.service.read("bundles/1.json")
        changed = copy.deepcopy(self.v1)
        changed.update(version=2, label="2026.10.2 (bad)")
        self.bad_policy = build_bundle.archive({"policy.json": (b'{"codingOrder":"hermes"}\n', 0o644)})
        for component in changed["components"]:  # bundle 2 ships a different policy blob
            if component["name"] == "policy":
                component.update(version="1.0.1", sha256=hashlib.sha256(self.bad_policy).hexdigest(),
                                 size=len(self.bad_policy))
        self.service.publish(changed, dict(self.blobs1, policy=self.bad_policy))
        self.blob_stats = {p.name: (p.stat().st_ino, p.stat().st_mtime_ns)
                           for p in (self.service.repo / "blobs/sha256").iterdir()}

    def republish(self, old=1, new=3, **options):
        args = dict(signer=self.service.signer("TEST-release-1"), pins_bytes=self.service.pins, channel="stable",
                    issued="2026-10-20T13:00:00Z", expires=EXPIRES, created="2026-10-20T13:00:00Z")
        args.update(options)
        return republish.republish(self.service.repo, old, new, **args)

    def test_republish_old_as_new_carries_its_blobs_byte_for_byte(self):
        written = self.republish()
        self.assertEqual(written, ["bundles/3.json", "channels/stable.json"])  # no blob written
        body = jcs.loads(self.service.read("bundles/3.json"))["signed"]
        self.assertEqual(body["components"], self.v1["components"])
        self.assertEqual((body["version"], body["code_bearing"], body["requires"]),
                         (3, self.v1["code_bearing"], self.v1["requires"]))
        self.assertEqual(self.service.read("bundles/1.json"), self.v1_raw)
        self.assertEqual({p.name: (p.stat().st_ino, p.stat().st_mtime_ns)
                          for p in (self.service.repo / "blobs/sha256").iterdir()}, self.blob_stats)
        verdict = self.service.verify(floors={"keys_version": 1, "index_seq": 2, "bundle_version": 2})
        self.assertEqual((verdict["verdict"], verdict["bundle_version"]), ("accept", 3))
        self.assertEqual(verdict["blobs"], {name: self.blobs1[name] for name in BOX_APPLY})
        mac = self.service.verify(MAC, floors={"keys_version": 1, "index_seq": 2, "bundle_version": 2})
        self.assertEqual(mac["blobs"]["policy"], self.blobs1["policy"])
        self.assertNotEqual(mac["blobs"]["policy"], self.bad_policy)

    def test_new_version_must_be_above_every_published_one(self):
        for new in (2, 1):
            with self.assertRaisesRegex(PublishError, "must be above every published version"):
                self.republish(new=new)
        with self.assertRaisesRegex(PublishError, "not published"):
            self.republish(old=7, new=8)

    def test_tampered_old_blob_or_manifest_is_refused(self):
        name = self.v1["components"][0]["sha256"]
        path = self.service.repo / "blobs/sha256" / name
        good = path.read_bytes()
        path.write_bytes(good[:-1] + b"\x01")
        before = self.service.snapshot()
        with self.assertRaisesRegex(PublishError, "blob_hash_mismatch"):
            self.republish()
        self.assertEqual(self.service.snapshot(), before)
        path.write_bytes(good)
        doc = jcs.loads(self.v1_raw)
        doc["signed"]["label"] = "edited"
        (self.service.repo / "bundles/1.json").write_bytes(jcs.canonical(doc))
        with self.assertRaisesRegex(PublishError, "not signed by a bundle key"):
            self.republish()

    def test_cli(self):
        args = ["1", "as", "3", "--repo", str(self.service.repo), "--pins", str(self.service.dir / "pins.json"),
                "--signer", f"file:{self.service.keydir / 'TEST-release-1'}", "--channel", "stable",
                "--issued", "2026-10-20T13:00:00Z", "--expires", EXPIRES, "--created", "2026-10-20T13:00:00Z"]
        (self.service.dir / "pins.json").write_bytes(self.service.pins)
        self.assertEqual(republish.main(args + ["--production"]), 1)
        self.assertEqual(republish.main(args), 0)
        self.assertEqual(jcs.loads(self.service.read("bundles/3.json"))["signed"]["label"], "2026.10.1 (republish of 1)")


class SignKeysTests(unittest.TestCase):
    def test_either_root_alone_signs_a_manifest_p0b_accepts(self):
        service = Service(self)
        for root in ("TEST-root-1", "TEST-root-2"):
            out = keys.sign_keys(jcs.canonical(service.manifest_body), service.pins, [service.signer(root)])
            release = p0b.verify_keys(out, p0b.verify_pins(service.pins, p0b.DEFAULT_LIMITS),
                                      publish.ZERO_FLOORS, p0b.DEFAULT_LIMITS)
            self.assertEqual(list(release), ["TEST-release-1"])
            self.assertEqual([s["key_id"] for s in jcs.loads(out)["signatures"]], [root])

    def test_only_pinned_roots_may_sign(self):
        service = Service(self)
        for key_id in ("TEST-release-1", "TEST-rogue"):
            with self.assertRaisesRegex(keys.KeysError, "not a pinned root"):
                keys.sign_keys(jcs.canonical(service.manifest_body), service.pins, [service.signer(key_id)])
        impostor = sign.FileKeySigner("TEST-root-1", vector_world.seed("TEST-rogue"))
        with self.assertRaisesRegex(keys.KeysError, "not a pinned root"):
            keys.sign_keys(jcs.canonical(service.manifest_body), service.pins, [impostor])

    def test_threshold_two_needs_both_roots_signing_apart(self):
        service = Service(self, threshold=2)
        source = jcs.canonical(service.manifest_body)
        with self.assertRaisesRegex(keys.KeysError, "pins need 2"):
            keys.sign_keys(source, service.pins, [service.signer("TEST-root-1")])
        partial = keys.sign_keys(source, service.pins, [service.signer("TEST-root-1")], partial=True)
        full = keys.sign_keys(partial, service.pins, [service.signer("TEST-root-2")])
        pins = p0b.verify_pins(service.pins, p0b.DEFAULT_LIMITS)
        self.assertIn("TEST-release-1", p0b.verify_keys(full, pins, publish.ZERO_FLOORS, p0b.DEFAULT_LIMITS))
        with self.assertRaises(p0b.Reject):
            p0b.verify_keys(partial, pins, publish.ZERO_FLOORS, p0b.DEFAULT_LIMITS)

    def test_version_must_increase_and_production_refuses_test_keys(self):
        service = Service(self)
        previous = service.read("keys.json")
        with self.assertRaisesRegex(keys.KeysError, "must be above the previous 1"):
            keys.sign_keys(jcs.canonical(service.manifest_body), service.pins, [service.signer("TEST-root-1")],
                           previous_bytes=previous)
        bumped = dict(service.manifest_body, version=2)
        keys.sign_keys(jcs.canonical(bumped), service.pins, [service.signer("TEST-root-1")], previous_bytes=previous)
        with self.assertRaisesRegex(keys.KeysError, "production mode refuses TEST keys"):
            keys.sign_keys(jcs.canonical(bumped), service.pins, [service.signer("TEST-root-1")], production=True)

    def test_cli_end_to_end(self):
        service = Service(self)
        d = service.dir
        pub = {k: vector_world.public_hex(k) for k in ("TEST-root-1", "TEST-root-2", "TEST-release-1")}
        steps = [["test-key", "TEST-release-1", "--out", str(d / "rel.key")],
                 ["pins", "--threshold", "1", "--root", f"TEST-root-1,{pub['TEST-root-1']}",
                  "--root", f"TEST-root-2,{pub['TEST-root-2']}", "--out", str(d / "pins.json")],
                 ["new", "--version", "2", "--issued", "2026-10-02T00:00:00Z", "--key",
                  f"TEST-release-1,{pub['TEST-release-1']},bundle+index,2027-01-01T00:00:00Z", "--out", str(d / "k.json")],
                 ["sign-keys", "--in", str(d / "k.json"), "--pins", str(d / "pins.json"),
                  "--signer", f"file:{service.keydir / 'TEST-root-2'}", "--out", str(d / "keys.json")]]
        for step in steps:
            self.assertEqual(keys.main(step), 0, step)
        self.assertEqual(d.joinpath("pins.json").read_bytes(), service.pins)
        self.assertEqual(keys.main(steps[3][:-2] + ["--out", str(d / "x.json"), "--production"]), 1)
        self.assertEqual(keys.main(["test-key", "release-1", "--out", str(d / "y")]), 1)
        os.replace(d / "keys.json", service.repo / "keys.json")
        body, blobs = build_bundle.build(version=1, label="x", created=ISSUED, previous=None)
        build = d / "build"
        build_bundle.write_build(build, body, blobs)
        args = ["--repo", str(service.repo), "--pins", str(d / "pins.json"), "--build", str(build), "--version", "1",
                "--signer", f"file:{d / 'rel.key'}", "--channel", "beta", "--issued", ISSUED, "--expires", EXPIRES]
        self.assertEqual(publish.main(args + ["--signer", f"file:{service.keydir / 'TEST-root-1'}"]), 1)
        self.assertEqual(publish.main(args), 0)
        self.assertEqual(service.verify(MAC, channel="beta", floors={"keys_version": 2, "index_seq": 1,
                                                                     "bundle_version": 0})["verdict"], "accept")


if __name__ == "__main__":
    unittest.main()
