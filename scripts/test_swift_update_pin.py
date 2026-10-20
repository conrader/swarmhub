"""P8a parity guard for the Swift local pin and drills (UpdatePinTests.swift), without Swift or network.

    PYTHONDONTWRITEBYTECODE=1 python3 scripts/test_swift_update_pin.py

Every verdict UpdatePinTests expects from the verifier is re-derived here through the box verifier with the same
re-signed bundles 12-14, indexes and key manifests 3-4 (TEST-release-2's seed derived as SCHEMAS.md §11) and the
same floors. The pin record has the box's shape (`swarmhub-update pin`), and the pinned check returns before the
store is switched. This checks expectations and source rules, not Swift execution: the Mac run (`swift test`)
remains mandatory.
"""

import hashlib
import json
from pathlib import Path
import re
import sys
import unittest

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import test_swift_update_client as base  # noqa: E402  (shared fixtures and verifier replay)

ROOT = base.ROOT
SOURCES = ROOT / "Packages/SwarmHubCore/Sources/SwarmHubCore/Updates"
PIN_TEST_PATH = base.TESTS / "UpdatePinTests.swift"
PIN_TEST = PIN_TEST_PATH.read_text(encoding="utf-8")
CLIENT = (SOURCES / "UpdateClient.swift").read_text(encoding="utf-8")
STORE = (SOURCES / "UpdateStore.swift").read_text(encoding="utf-8")
BOX_CLI = (ROOT / "Resources/Updater/swarmhub_update/cli.py").read_text(encoding="utf-8")
SEED_LABEL = "swarmhub-release-vectors/TEST-seed/"


def sign(signed, key_id):
    """RotationKeys.envelope: any TEST key, its seed derived from the public label."""
    seed = hashlib.sha256((SEED_LABEL + key_id).encode("utf-8")).digest()
    sig = base.ed25519_ref.sign(seed, b"swarmhub-signature/1\n" + base.jcs.canonical(signed)).hex()
    return base.jcs.canonical({"signed": signed, "signatures": [{"key_id": key_id, "sig": sig}]})


def public_hex(key_id):
    return base.ed25519_ref.public_key(hashlib.sha256((SEED_LABEL + key_id).encode("utf-8")).digest()).hex()


def key_manifest(version, release_keys):
    signed = json.loads(base.read("keys/keys-2.json"))["signed"]
    signed.update(version=version, keys=[{"key_id": k, "ed25519_pub": public_hex(k), "roles": ["bundle", "index"],
                                          "not_after": "2027-01-01T00:00:00Z"} for k in release_keys])
    return sign(signed, "TEST-root-1")


def offering(version, seq, signer="TEST-release-1", keys=None):
    """UpdatePinTests.offering: bundle 11's body at `version` and an index at `seq`, both by `signer`."""
    signed = json.loads(base.read("bundles/11.json"))["signed"]
    signed["version"] = version
    manifest = sign(signed, signer)
    index = json.loads(base.read("channels/stable.json"))["signed"]
    line = dict(index["lines"][0], bundle_version=version, manifest_sha256=hashlib.sha256(manifest).hexdigest())
    index.update(seq=seq, lines=[line])
    return {"keys": keys, "index": sign(index, signer), "manifests": {version: manifest}}


def verdict(floors, offer=None):
    result, _ = base.client_verdict(floors=floors, **(offer or {}))
    return {k: result[k] for k in ("verdict", "stage", "reason", "bundle_version") if k in result}, result


class PinDrillParityTests(unittest.TestCase):
    def test_pinned_check_verifies_the_newer_bundle_it_holds_back(self):
        # pinPreviousHolds...: floors [2, 5, 11]; 12 verifies, so the pinned client reports it as held.
        self.assertEqual(verdict((2, 5, 11), offering(12, 6))[0]["bundle_version"], 12)
        self.assertIn('UpdateVerdict(verdict: "no_update", stage: "pin", reason: "pinned", bundleVersion: 12)', PIN_TEST)

    def test_clearing_with_nothing_newer_is_already_applied(self):
        self.assertEqual(verdict((2, 5, 11))[0], {"verdict": "no_update", "stage": "index", "reason": "already_applied"})
        self.assertIn('cleared.verdict.reason == "already_applied"', PIN_TEST)

    def test_roll_forward_drill(self):
        self.assertEqual(verdict((2, 5, 11), offering(12, 6))[0]["verdict"], "accept")
        result, full = verdict((2, 6, 12), offering(13, 7))
        self.assertEqual((result["verdict"], result["bundle_version"]), ("accept", 13))
        self.assertEqual(full["blobs"]["policy"], base.read("blobs/sha256/" + base.policy_sha()))
        self.assertEqual(verdict((2, 7, 13), offering(12, 6))[0],
                         {"verdict": "reject", "stage": "index", "reason": "index_rollback"})
        self.assertIn("[2, 7, 13]", PIN_TEST)

    def test_key_rotation_drill(self):
        overlap = key_manifest(3, ["TEST-release-1", "TEST-release-2"])
        rotated = key_manifest(4, ["TEST-release-2"])
        self.assertEqual(verdict((2, 5, 11), offering(12, 6, "TEST-release-2", overlap))[0]["verdict"], "accept")
        self.assertEqual(verdict((3, 6, 12), offering(13, 7, "TEST-release-2", rotated))[0]["verdict"], "accept")
        self.assertEqual(verdict((4, 7, 13), offering(14, 100, "TEST-release-1", rotated))[0],
                         {"verdict": "reject", "stage": "index", "reason": "unknown_key"})
        self.assertEqual(verdict((4, 7, 13), offering(14, 100, "TEST-release-1", overlap))[0],
                         {"verdict": "reject", "stage": "keys", "reason": "keys_rollback"})
        for stage, reason in (("index", "unknown_key"), ("keys", "keys_rollback")):
            self.assertIn('UpdateVerdict(verdict: "reject", stage: "%s", reason: "%s")' % (stage, reason), PIN_TEST)
        self.assertIn("[4, 7, 13]", PIN_TEST)


class PinSourceRuleTests(unittest.TestCase):
    def test_pin_record_has_the_box_shape(self):
        box = re.search(r'record\["pin"\] = \{"mode": [^,]+, "at": [^,]+, "bundle_version": ', BOX_CLI)
        self.assertIsNotNone(box, "box pin record changed shape")
        pin = STORE[STORE.index("public struct UpdatePin"):]
        pin = pin[:pin.index("\n}\n")]
        self.assertIn('case mode, at', pin)
        self.assertIn('case bundleVersion = "bundle_version"', pin)
        modes = set(re.search(r"enum Mode: String, Codable, Sendable \{ case ([a-z, ]+) \}", pin).group(1).split(", "))
        box_modes = set(re.search(r'add_argument\("mode", choices=\(([^)]*)\)\)', BOX_CLI).group(1)
                        .replace('"', "").replace(" ", "").split(","))
        self.assertEqual(modes, box_modes - {"clear"})
        self.assertIn("case pin\n", STORE)

    def test_a_pinned_check_returns_before_the_switch_and_keeps_the_bundle_floor(self):
        run = CLIENT[CLIENT.index("private func run("):CLIENT.index("private func persist(")]
        pinned = run[run.index("if state.pin != nil"):run.index("switch verdict.verdict")]
        self.assertLess(run.index("if state.pin != nil"), run.index("try store.commit(snapshot)"))
        self.assertIn("bundle: 0", pinned)
        self.assertIn('return UpdateVerdict(verdict: "no_update", stage: "pin", reason: "pinned"', pinned)
        self.assertNotIn("commit", pinned)

    def test_pin_waits_for_a_running_check_and_writes_the_hold_first(self):
        pin = CLIENT[CLIENT.index("public func pin("):CLIENT.index("public func clearPin(")]
        self.assertLess(pin.index("await settle()"), pin.index("try store.saveState(state)"))
        self.assertLess(pin.index("try store.saveState(state)"), pin.index("try store.revertToPrevious()"))
        self.assertLess(pin.index("if state.pin?.mode == .previous { return"), pin.index("try store.revertToPrevious()"))
        clear = CLIENT[CLIENT.index("public func clearPin("):CLIENT.index("private func restoreAfterClear(")]
        self.assertLess(clear.index("await settle()"), clear.index("try store.saveState(state)"))
        self.assertLess(clear.index("state.restoreBundle = pin.mode == .previous"), clear.index("return await check()"))
        # The swap-back runs inside the check, from persisted state, before the state is saved.
        perform = CLIENT[CLIENT.index("private func perform("):CLIENT.index("private struct PolicyFailure")]
        self.assertLess(perform.index("restoreAfterClear(&state, verdict: verdict)"), perform.index("store.saveState(state)"))
        self.assertIn('case restoreBundle = "restore_bundle"', STORE)

    def test_files_stay_small_and_execute_nothing(self):
        for path in (PIN_TEST_PATH, SOURCES / "UpdateClient.swift", SOURCES / "UpdateStore.swift", Path(__file__)):
            source = path.read_text(encoding="utf-8")
            self.assertLessEqual(len(source.splitlines()), 500, path.name)
        self.assertNotRegex(PIN_TEST, r"\bimport\s+(AppKit|UIKit)\b|\bProcess\s*\(")
        self.assertIn('"swarmhub-release-vectors/TEST-seed/"', PIN_TEST)


if __name__ == "__main__":
    unittest.main()
