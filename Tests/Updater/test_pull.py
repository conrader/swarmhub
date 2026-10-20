"""P3a: `swarmhub-update pull` against a local static host (CORE-PHASES.md P3a acceptance).

host down → no change; bad signature → last good; mirror replay of an old index → rejected; expired index → stale,
runtime unchanged; redirect to another host → refused; rollout percent honoured deterministically; Hermes range
against the installed Hermes version (unknown → skipped as `incompatible: hermes`); Hermes files byte-identical.

    python3 -m unittest discover -s Tests/Updater -p "test_pull.py"
"""

import hashlib
import json
import os
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from apply_fixtures import HERMES as HERMES_FIXTURE  # noqa: E402
from cli_fixtures import (CODING, FEEDBACK, MESSAGES, PROFILES_DOC, REQUIRES, index, line, manifest,  # noqa: E402
                          statefile)
from pull_fixtures import PullCase, closed_port, resign_broken  # noqa: E402

from swarmhub_update import channel, compat, verify  # noqa: E402

FETCHED_FIRST = ["keys.json", "channels/stable.json"]


def reference_bucket(install_id, version):
    """SCHEMAS.md §6, written out independently of the updater."""
    digest = hashlib.sha256(("%s\n%d" % (install_id, version)).encode("utf-8")).digest()
    return int.from_bytes(digest[:8], "big") % 100


class Pull(PullCase):
    def test_pull_applies_data_parks_code_and_sends_no_store(self):
        v1, comps = self.release("v1")
        self.publish(11, comps)
        code, out = self.pull(self.service.url)
        self.assertEqual((code, out["state"], out["last"]["verdict"]), (0, "pending_confirm", "accept"), out)
        self.assertEqual([c["name"] for c in out["pending_confirm"]["code"]], [CODING, MESSAGES])
        self.assertEqual(self.live_version(FEEDBACK), "1.0.0")  # data applied at once
        self.assertFalse(self.live(CODING).exists())  # code waits for the local confirm
        self.assertEqual(self.service.paths()[:3], FETCHED_FIRST + ["bundles/11.json"])
        self.assertEqual(sorted(self.service.paths()[3:]), sorted("blobs/sha256/" + c["sha256"] for c, _ in comps))
        for _, headers in self.service.log:
            self.assertEqual(headers.get("cache-control"), "no-store")
            self.assertNotIn("authorization", headers)
            self.assertNotIn("cookie", headers)
        self.assertEqual(self.update("apply", "--version", "11")[1]["state"], "current")
        self.assert_live(v1)
        self.service.log.clear()
        code, out = self.pull(self.service.url)  # the same bundle again: a refresh from what the box holds
        self.assertEqual((code, out["state"], out["last"]["refresh"]), (0, "current", True))
        self.assertEqual(self.service.paths(), FETCHED_FIRST)

    def test_origins_come_from_config_and_none_configured_changes_nothing(self):
        before = self.runtime()
        code, out = self.pull()
        self.assertEqual((code, out["last"]["verdict"]), (0, "none"))
        self.assertIn("no update origin", out["last"]["detail"])
        self.assert_runtime_unchanged(before)
        self.set_config(origins=["http://updates.example.com/"])  # plain http off loopback
        code, out = self.pull()
        self.assertEqual((code, out["last"]["reason"]), (65, "origin_invalid"))
        _, comps = self.release("v1")
        self.publish(11, comps)
        self.set_config(origins=[self.service.url])
        self.assertEqual(self.pull()[1]["state"], "pending_confirm")


class Acceptance(PullCase):
    def test_host_down_changes_nothing(self):
        self.start()
        _, comps = self.release("v2", version="1.1.0", note="v2")
        self.publish(12, comps, seq=6)
        before = self.runtime()
        code, out = self.pull("http://127.0.0.1:%d/" % closed_port())
        self.assertEqual(code, 75)
        self.assertEqual((out["last"]["stage"], out["last"]["reason"]), ("fetch", "host_unreachable"))
        self.assertEqual(out["state"], "current")
        self.assert_runtime_unchanged(before)
        self.assertEqual(self.live_version(FEEDBACK), "1.0.0")

    def test_bad_signature_keeps_last_good(self):
        v1, _ = self.start()
        floors = self.floors()
        _, comps = self.release("v2", version="1.1.0", note="v2")
        for target in ("channels/stable.json", "bundles/12.json"):
            folder = self.publish(12, comps, seq=6)
            resign_broken(folder / target)
            if target.startswith("bundles"):  # the index lists the altered manifest, so its signature is reached
                raw = (folder / target).read_bytes()
                (folder / "channels/stable.json").write_bytes(index([line(raw, 12)], 6))
            before = self.runtime()
            code, out = self.pull(self.service.url)
            self.assertEqual((code, out["last"]["reason"]), (65, "bad_signature"), target)
            self.assertEqual(out["last"]["stage"], "index" if target.startswith("channels") else "manifest")
            self.assertEqual((out["state"], out["bundle"]["bundle_version"]), ("current", 11))
            self.assert_live(v1)
            if target.startswith("channels"):
                self.assert_runtime_unchanged(before)
                self.assertEqual(self.floors(), floors)

    def test_tampered_blob_keeps_last_good(self):
        v1, _ = self.start()
        _, comps = self.release("v2", version="1.1.0", note="v2")
        folder = self.publish(12, comps, seq=6)
        blob = folder / "blobs/sha256" / comps[0][0]["sha256"]
        blob.write_bytes(bytes([blob.read_bytes()[0] ^ 1]) + blob.read_bytes()[1:])
        code, out = self.pull(self.service.url)
        self.assertEqual((code, out["last"]["reason"]), (65, "blob_hash_mismatch"))
        self.assertEqual(out["bundle"]["bundle_version"], 11)
        self.assert_live(v1)

    def test_mirror_replay_of_an_old_index_is_rejected(self):
        self.start()
        old = self.publish(11, self.release("v1")[1])  # what a mirror still serves: seq 5, bundle 11
        mirror = self.serve()
        mirror.root = old
        _, comps = self.release("v2", version="1.1.0", note="v2")
        self.publish(12, comps, seq=6)
        self.assertEqual(self.pull(self.service.url)[1]["bundle"]["bundle_version"], 12)
        self.assertEqual(self.floors()["index_seq"], 6)
        before = self.runtime()
        code, out = self.pull(mirror.url)
        self.assertEqual((code, out["last"]["stage"], out["last"]["reason"]), (65, "index", "index_rollback"))
        self.assertEqual(mirror.paths(), FETCHED_FIRST)  # nothing past the refused index is fetched
        self.assert_runtime_unchanged(before)
        self.assertEqual(self.live_version(FEEDBACK), "1.1.0")
        code, out = self.pull("http://127.0.0.1:%d/" % closed_port(), mirror.url)  # primary down, mirror stale
        self.assertEqual((code, out["last"]["reason"]), (65, "index_rollback"))
        self.assertEqual([a["reason"] for a in out["last"]["attempts"]], ["host_unreachable", "index_rollback"])
        code, out = self.pull(mirror.url, self.service.url)  # an old mirror first does not hide the primary
        self.assertEqual((code, out["last"]["verdict"], out["last"]["origin"]), (0, "accept", self.service.url))
        self.assertEqual(out["last"]["attempts"][0]["reason"], "index_rollback")
        self.assertEqual((out["bundle"]["bundle_version"], out["last"]["refresh"]), (12, True))

    def test_expired_index_reports_stale_and_leaves_the_runtime(self):
        v1, _ = self.start()
        _, comps = self.release("v2", version="1.1.0", note="v2")
        self.publish(12, comps, seq=6, expires="2026-10-20T11:59:59Z")
        before = self.runtime()
        code, out = self.pull(self.service.url)
        self.assertEqual((code, out["last"]["reason"], out["stale"]), (65, "index_expired", True))
        self.assertEqual((out["state"], out["bundle"]["bundle_version"]), ("current", 11))
        self.assert_runtime_unchanged(before)
        self.assert_live(v1)
        self.assertEqual(self.service.paths()[-1], "channels/stable.json")  # no manifest or blob fetched
        self.publish(12, comps, seq=7)
        code, out = self.pull(self.service.url)
        self.assertEqual((code, out["stale"], out["bundle"]["bundle_version"]), (0, False, 12))

    def test_redirect_to_another_host_is_refused(self):
        _, comps = self.release("v1")
        folder = self.publish(11, comps)
        other = self.serve()
        other.root = folder
        before = self.runtime(floors=False)
        for target in (other.url, "http://localhost:%d/" % self.service.port, "https://example.com/"):
            self.service.redirects = {"channels/stable.json": target + "channels/stable.json"}
            code, out = self.pull(self.service.url)
            self.assertEqual((code, out["last"]["stage"], out["last"]["reason"]), (75, "fetch", "redirect_refused"))
            self.assert_runtime_unchanged(before, floors=False)
        self.assertEqual(other.log, [])
        moved = folder / "moved"
        moved.mkdir()
        (moved / "stable.json").write_bytes((folder / "channels/stable.json").read_bytes())
        self.service.redirects = {"channels/stable.json": self.service.url + "moved/stable.json"}
        code, out = self.pull(self.service.url)  # a redirect within the same origin is followed
        self.assertEqual((code, out["state"]), (0, "pending_confirm"))

    def test_rollout_percent_is_honoured_deterministically(self):
        ids = ["box-%d" % n for n in range(400)]
        self.assertEqual([channel.bucket(i, 11) for i in ids], [reference_bucket(i, 11) for i in ids])
        share = sum(channel.bucket(i, 11) < 30 for i in ids) / len(ids)
        self.assertTrue(0.2 < share < 0.4, share)
        inside = next(i for i in ids if reference_bucket(i, 11) < 30)
        outside = next(i for i in ids if reference_bucket(i, 11) >= 30)
        _, comps = self.release("v1")
        self.publish(11, comps, percent=30)
        self.set_config(install_id=outside)
        before = self.runtime(floors=False)
        for _ in range(2):  # the same box decides the same way on every run
            code, out = self.pull(self.service.url)
            self.assertEqual((code, out["last"]["verdict"], out["last"]["reason"]), (0, "no_update", "not_in_rollout"))
            self.assertEqual(out["last"]["lines"], [{"bundle_version": 11, "rollout_percent": 30, "compatible": True,
                                                     "bucket": reference_bucket(outside, 11), "in_rollout": False}])
            self.assert_runtime_unchanged(before, floors=False)
        self.assertFalse(self.live(FEEDBACK).exists())
        self.wipe_state()
        self.fresh_state(install_id=inside)
        code, out = self.pull(self.service.url)
        self.assertEqual((code, out["state"]), (0, "pending_confirm"))
        self.assertTrue(out["last"]["lines"][0]["in_rollout"])
        self.assertEqual(self.live_version(FEEDBACK), "1.0.0")

    def fresh_state(self, **config):
        statefile.State(str(self.state)).write_json(PROFILES_DOC, "profiles.json")
        self.set_config(**config)


class Hermes(PullCase):
    def install_hermes(self, text):
        folder = self.hermes / "hermes-agent/hermes_cli"
        folder.mkdir(parents=True, exist_ok=True)
        (folder / "__init__.py").write_text(text)

    def ranged(self, rng):
        """Release v1 with the data skill limited to a Hermes range."""
        _, comps = self.release("v1")
        for comp, _ in comps:
            if comp["name"] == FEEDBACK:
                comp["requires"] = {"hermes": rng}
        return comps

    def test_version_is_read_as_text_never_executed(self):
        self.install_hermes('raise SystemExit("executed")\n__version__ = "0.21.7"\n__release_date__ = "x"\n')
        self.assertEqual(compat.hermes(str(self.hermes), {}),
                         {"version": "0.21.7", "source": str(self.hermes / "hermes-agent/hermes_cli/__init__.py")})
        for text in ('__version__ = "0.21.7"\n__version__ = "0.22.0"\n', '    __version__ = "1.0"\n',
                     '__version__ = "0.22.0rc1"\n', '__version__ = get()\n', ''):
            self.install_hermes(text)
            self.assertIsNone(compat.read_version(str(self.hermes / "hermes-agent")), text)
        self.assertEqual(compat.hermes(str(self.hermes), {"hermes_version": "0.20.5"})["version"], "0.20.5")
        self.assertEqual(compat.hermes(str(self.hermes), {}), {"version": None, "source": "unknown"})

    def test_unknown_hermes_skips_ranged_components_and_applies_the_rest(self):
        self.publish(11, self.ranged(">=0.21,<0.23"))
        code, out = self.pull(self.service.url)
        self.assertEqual((code, out["state"]), (0, "pending_confirm"))
        self.assertEqual(out["skipped"], [{"name": FEEDBACK, "reason": "incompatible", "axes": ["hermes"],
                                           "detail": "incompatible: hermes"}])
        self.assertEqual(out["hermes"], {"version": None, "source": "unknown"})
        self.assertFalse(self.live(FEEDBACK).exists())
        self.assertEqual(self.live_version("swarmhub-manager"), "1.0.0")

    def test_installed_hermes_inside_and_outside_the_range(self):
        self.install_hermes('__version__ = "0.24.0"\n')
        self.publish(11, self.ranged(">=0.21,<0.23"))
        out = self.pull(self.service.url)[1]
        self.assertEqual(out["skipped"][0]["detail"], "incompatible: hermes")
        self.assertEqual(out["hermes"]["version"], "0.24.0")
        self.install_hermes('__version__ = "0.21.7"\n')
        _, comps = self.release("v2", version="1.1.0", note="v2")
        for comp, _ in comps:
            if comp["name"] == FEEDBACK:
                comp["requires"] = {"hermes": ">=0.21,<0.23"}
        self.publish(12, comps, seq=6)
        out = self.pull(self.service.url)[1]
        self.assertEqual((out["skipped"], out["hermes"]["version"]), ([], "0.21.7"))
        self.assertEqual(self.live_version(FEEDBACK), "1.1.0")

    def test_line_with_a_hermes_range_needs_a_known_hermes(self):
        _, comps = self.release("v1")
        folder = self.publish(11, comps)
        raw = manifest(11, [c for c, _ in comps])
        ranged = dict(line(raw, 11), requires=dict(REQUIRES, hermes=">=0.21"))
        (folder / "channels/stable.json").write_bytes(index([ranged], 5))
        code, out = self.pull(self.service.url)
        self.assertEqual((code, out["last"]["reason"]), (65, "no_compatible_line"))
        self.assertEqual(out["last"]["lines"][0]["incompatible"], ["hermes"])
        self.install_hermes('__version__ = "0.22.0"\n')
        self.assertEqual(self.pull(self.service.url)[1]["state"], "pending_confirm")

    def test_hermes_files_stay_byte_identical(self):
        self.install_hermes('__version__ = "0.21.7"\n')
        allowed = ("skills/swarmhub/", "profiles/coder_2/skills/swarmhub/")

        def hermes_files():
            files = {}
            for directory, _, names in os.walk(str(self.hermes)):
                for name in names:
                    full = os.path.join(directory, name)
                    rel = os.path.relpath(full, str(self.hermes))
                    if not rel.startswith(allowed):
                        files[rel] = (Path(full).read_bytes(), os.lstat(full).st_mode)
            return files
        before = hermes_files()
        self.start()
        _, comps = self.release("v2", version="1.1.0", note="v2", plugin="p2")
        self.publish(12, comps, seq=6)
        self.pull(self.service.url)
        self.update("apply")
        self.pull("http://127.0.0.1:%d/" % closed_port())
        self.assertEqual(hermes_files(), before)
        self.assertEqual((self.hermes / "hermes-agent/gateway/platforms/api_server.py").read_bytes(),
                         HERMES_FIXTURE.read_bytes())
        self.assert_no_pycache()


class Selection(unittest.TestCase):
    def test_bucket_matches_the_signed_vectors_rule(self):
        vectors = json.loads((Path(__file__).resolve().parents[2]
                              / "Tests/Fixtures/release-bundles/vectors.json").read_text())
        ids = {c["inputs"]["install_id"] for c in vectors["cases"] if c["inputs"].get("install_id")}
        self.assertTrue(ids)
        for install_id in ids:
            for version in (1, 7, 12, 4096):
                self.assertEqual(channel.bucket(install_id, version), reference_bucket(install_id, version))
                self.assertEqual(channel.bucket(install_id, version), verify.rollout_bucket(install_id, version))


if __name__ == "__main__":
    unittest.main()
