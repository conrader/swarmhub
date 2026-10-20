"""P8a channel tooling: promotion copies the signed index line and never rebuilds or re-signs a bundle or blob;
percent rollout edits; refusals leave the service as it was. TEST keys, loopback host only.

    PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts -p "test_release_channels.py"
"""

import contextlib
import hashlib
import io
import os
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest import mock

os.environ["PYTHONDONTWRITEBYTECODE"] = "1"
sys.path.insert(0, str(Path(__file__).resolve().parent / "release"))

import build_bundle  # noqa: E402
import channels  # noqa: E402
from drill_world import EXPIRES, RELEASE_1, ROOT_1, Box, Desk, Host  # noqa: E402
import jcs  # noqa: E402
import keys as keytool  # noqa: E402
import publish  # noqa: E402
import republish  # noqa: E402
import sign  # noqa: E402
from swarmhub_update import verify  # noqa: E402


def snapshot(repo, *parts):
    """Bytes, inode and mtime of every file under the given parts of the service."""
    result = {}
    for part in parts:
        base = Path(repo) / part
        for path in ([base] if base.is_file() else sorted(base.rglob("*"))):
            info = os.lstat(path)
            result[str(path.relative_to(repo))] = (hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file()
                                                   else None, info.st_ino, info.st_mtime_ns)
    return result


class ChannelCase(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="p8a-channels-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.desk = Desk(self.tmp)
        self.desk.publish_keys([RELEASE_1])
        self.desk.publish(1)
        self.repo = self.desk.repo

    def index(self, channel):
        return self.desk.signed("channels/%s.json" % channel)

    def assert_refused(self, call, text):
        before = snapshot(self.repo, ".")
        with self.assertRaises(publish.PublishError) as caught:
            call()
        self.assertIn(text, str(caught.exception))
        self.assertEqual(snapshot(self.repo, "."), before, "a refused command wrote to the service")


class PromotionTests(ChannelCase):
    def test_promotion_copies_the_line_and_never_rebuilds_or_resigns(self):
        frozen = snapshot(self.repo, "bundles", "blobs", "keys.json", "channels/canary.json")
        signed = []
        real_envelope = sign.envelope

        def recording(body, signers):
            signed.append(body.get("schema"))
            return real_envelope(body, signers)

        def forbidden(*args, **kwargs):
            raise AssertionError("promotion must not build, sign or write a bundle or blob")

        with contextlib.ExitStack() as stack:
            for target, name in ((build_bundle, "build"), (build_bundle, "build_component"), (build_bundle, "archive"),
                                 (build_bundle, "write_build"), (publish, "publish_body"), (publish, "write_immutable"),
                                 (republish, "republish"), (keytool, "sign_keys"), (sign, "add_signatures")):
                stack.enter_context(mock.patch.object(target, name, forbidden))
            stack.enter_context(mock.patch.object(sign, "envelope", recording))
            written = self.desk.promote("canary", "beta")
            written += self.desk.promote("beta", "stable")
        self.assertEqual(written, ["channels/beta.json", "channels/stable.json"])
        self.assertEqual(signed, ["swarmhub/index/1", "swarmhub/index/1"], "only channel indexes are signed")
        self.assertEqual(snapshot(self.repo, "bundles", "blobs", "keys.json", "channels/canary.json"), frozen)
        canary = self.index("canary")["lines"]
        self.assertEqual(self.index("beta")["lines"], canary)
        self.assertEqual(self.index("stable")["lines"], canary)
        raw = (self.repo / "bundles/1.json").read_bytes()
        self.assertEqual(canary[0]["manifest_sha256"], hashlib.sha256(raw).hexdigest())

    def test_stable_consumer_verifies_the_same_bytes_canary_tested(self):
        host = Host(self.repo)
        self.addCleanup(host.close)
        self.desk.promote("canary", "beta")
        self.desk.promote("beta", "stable")
        boxes = [Box(self.tmp, name, self.desk.pins_bytes, name, "p8a-" + name) for name in ("canary", "stable")]
        for box in boxes:
            code, out = box.pull(host.url)
            self.assertEqual((code, out["state"]), (0, "pending_confirm"), out)
            box.run("apply", "--version", "1")
        self.assertEqual(boxes[0].applied()["components"], boxes[1].applied()["components"])
        self.assertEqual(boxes[0].live("drill-notes"), boxes[1].live("drill-notes"))
        self.assertEqual([p for p in host.log if p.startswith("/bundles/")], ["/bundles/1.json"] * 2)

    def test_promote_takes_the_newest_line_or_the_named_version(self):
        self.desk.publish(2, notes="Second.", notes_version="1.0.1")
        self.assert_refused(lambda: self.desk.promote("canary", "beta", version=1), "no line for bundle 1")
        self.desk.promote("canary", "beta", version=2)
        self.assertEqual([l["bundle_version"] for l in self.index("beta")["lines"]], [2])
        self.desk.publish(3, notes="Third.", notes_version="1.0.2")
        self.desk.promote("canary", "beta")
        self.assertEqual([l["bundle_version"] for l in self.index("beta")["lines"]], [3])
        self.assertEqual(self.index("beta")["seq"], 2)

    def test_rollout_override_changes_only_the_percent(self):
        self.desk.promote("canary", "beta", rollout_percent=10)
        line = dict(self.index("canary")["lines"][0], rollout_percent=10)
        self.assertEqual(self.index("beta")["lines"], [line])

    def test_promotion_refusals_write_nothing(self):
        d = self.desk
        self.assert_refused(lambda: d.promote("canary", "stable"), "one step along")
        self.assert_refused(lambda: d.promote("beta", "canary"), "one step along")
        self.assert_refused(lambda: d.promote("beta", "stable"), "has no index")
        self.assert_refused(lambda: d.promote("canary", "beta", version=7), "no line for bundle 7")
        self.assert_refused(lambda: d.promote("canary", "beta", rollout_percent=101), "0-100")
        self.assert_refused(lambda: d.promote("canary", "beta", signer=ROOT_1), "root key")
        self.assert_refused(lambda: channels.promote(self.repo, "canary", "beta", signer=d.signer(RELEASE_1),
                                                     pins_bytes=d.pins_bytes, issued=d.issued(), expires=EXPIRES,
                                                     production=True), "production mode refuses TEST keys")
        self.assert_refused(lambda: channels.promote(self.repo, "canary", "beta", signer=d.signer(RELEASE_1),
                                                     pins_bytes=d.pins_bytes, issued=EXPIRES, expires="2026-11-30T00:00:00Z"),
                            "expired")

    def test_a_tampered_blob_or_manifest_is_never_promoted(self):
        blob = next((self.repo / "blobs/sha256").iterdir())
        original = blob.read_bytes()
        blob.write_bytes(original[:-1] + b"\1")
        self.assert_refused(lambda: self.desk.promote("canary", "beta"), "refused blob_hash_mismatch")
        blob.write_bytes(original)
        manifest = self.repo / "bundles/1.json"
        manifest.write_bytes(manifest.read_bytes() + b"\n")
        self.assert_refused(lambda: self.desk.promote("canary", "beta"), "manifest_sha256")

    def test_target_never_goes_back(self):
        line_1 = self.index("canary")["lines"][0]
        self.desk.publish(2, notes="Second.", notes_version="1.0.1")
        self.desk.promote("canary", "beta")
        # A canary index that still offers 1 (say, restored from a backup) cannot push beta back to 1.
        self.desk.forge_index(self.repo, "canary", [line_1], seq=50, signer=RELEASE_1)
        self.assert_refused(lambda: self.desk.promote("canary", "beta"), "going back is `republish`")


class RolloutTests(ChannelCase):
    def test_rollout_edits_the_percent_and_raises_seq(self):
        self.desk.publish(2, notes="Second.", notes_version="1.0.1", rollout=5)
        before = self.index("canary")
        self.assertEqual(self.desk.rollout("canary", 2, 40), ["channels/canary.json"])
        after = self.index("canary")
        self.assertEqual(after["seq"], before["seq"] + 1)
        self.assertEqual(after["lines"], [dict(before["lines"][0], rollout_percent=40)])
        self.assert_refused(lambda: self.desk.rollout("canary", 9, 50), "no line for bundle 9")
        for bad in (-1, 101, True):
            self.assert_refused(lambda bad=bad: self.desk.rollout("canary", 2, bad), "0-100")

    def test_percent_rollout_reaches_installs_by_their_bucket(self):
        host = Host(self.repo)
        self.addCleanup(host.close)
        ids = ["p8a-roll-%d" % i for i in range(40)]
        buckets = {i: verify.rollout_bucket(i, 2) for i in ids}
        low = min(ids, key=buckets.get)
        high = next(i for i in ids if buckets[i] > buckets[low])
        boxes = {i: Box(self.tmp, i, self.desk.pins_bytes, "canary", i) for i in (low, high)}
        for box in boxes.values():
            box.pull(host.url)
            box.run("apply", "--version", "1")
        self.desk.publish(2, notes="Second.", notes_version="1.0.1", rollout=0)
        for box in boxes.values():
            code, out = box.pull(host.url)
            self.assertEqual((code, out["last"]["reason"]), (0, "not_in_rollout"))
        self.desk.rollout("canary", 2, buckets[high])  # includes `low`, not `high`
        for _ in range(2):  # deterministic: the same answer on every run
            self.assertEqual(boxes[high].pull(host.url)[1]["last"]["reason"], "not_in_rollout")
        code, out = boxes[low].pull(host.url)
        self.assertEqual((code, out["state"], out["bundle"]["bundle_version"]), (0, "current", 2), out)
        self.desk.rollout("canary", 2, 100)
        code, out = boxes[high].pull(host.url)
        self.assertEqual((code, out["state"], out["bundle"]["bundle_version"]), (0, "current", 2), out)


class CommandLineTests(ChannelCase):
    def run_main(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = channels.main(list(argv))
        return code, out.getvalue(), err.getvalue()

    def common(self):
        return ["--repo", str(self.repo), "--pins", str(self.desk.pins_path), "--signer",
                "file:" + str(self.desk.keydir / (RELEASE_1 + ".key.json")), "--issued", self.desk.issued(),
                "--expires", EXPIRES]

    def test_promote_and_rollout_from_the_command_line(self):
        code, out, err = self.run_main("promote", "canary", "beta", *self.common())
        self.assertEqual((code, err), (0, ""))
        self.assertIn("wrote channels/beta.json", out)
        code, out, err = self.run_main("rollout", "beta", "--version", "1", "--percent", "25", *self.common())
        self.assertEqual((code, err), (0, ""))
        self.assertEqual(self.index("beta")["lines"][0]["rollout_percent"], 25)
        code, out, err = self.run_main("promote", "canary", "stable", *self.common())
        self.assertEqual(code, 1)
        self.assertIn("one step along", err)


if __name__ == "__main__":
    unittest.main()
