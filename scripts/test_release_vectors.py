"""P0a: the signed release test vectors regenerate byte-identically and every vector has its expected verdict."""

import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/release"))

import ed25519_ref  # noqa: E402
import jcs  # noqa: E402
import make_vectors  # noqa: E402
from reference_verify import evaluate, signing_message  # noqa: E402

FIXTURES = ROOT / "Tests/Fixtures/release-bundles"
VECTORS = json.loads((FIXTURES / "vectors.json").read_text(encoding="utf-8"))
CASES = {case["id"]: case for case in VECTORS["cases"]}

# P0a acceptance (CORE-PHASES.md): each listed situation -> the vectors that cover it.
REQUIRED = {
    "valid": ["valid-box", "valid-mac"],
    "tampered byte": ["tampered-keys", "tampered-index", "tampered-blob"],
    "wrong key": ["wrong-key"],
    "unknown key": ["unknown-key"],
    "key past not_after": ["key-expired"],
    "lower keys.version": ["lower-keys-version"],
    "lower index.seq": ["lower-index-seq"],
    "expired index": ["expired-index"],
    "manifest hash mismatch": ["manifest-hash-mismatch"],
    "archive ..": ["archive-dotdot"],
    "archive absolute path": ["archive-absolute"],
    "archive symlink": ["archive-symlink"],
    "archive device": ["archive-device"],
    "archive oversize": ["archive-oversize-file", "archive-oversize-total", "archive-oversize-blob"],
    "archive bad mode": ["archive-bad-mode-setuid", "archive-bad-mode-writable"],
    "data component holding code": ["class-mismatch-skill", "class-mismatch-exec-data"],
    "incompatible requires": ["incompatible-bundle-requires", "no-compatible-line", "incompatible-component"],
}


class RegenerationTests(unittest.TestCase):
    def test_regenerating_from_seeds_is_byte_identical(self):
        with tempfile.TemporaryDirectory() as temp:
            make_vectors.write(Path(temp))
            self.assertEqual(make_vectors.differences(Path(temp), FIXTURES), [])
            again = Path(temp) / "again"
            make_vectors.write(again)
            self.assertEqual(make_vectors.differences(again, Path(temp)), [])

    def test_check_mode_reports_a_changed_fixture(self):
        with tempfile.TemporaryDirectory() as temp:
            out = Path(temp)
            make_vectors.write(out)
            self.assertEqual(make_vectors.main(["--check", "--out", str(out)]), 0)
            (out / "keys/pins.json").write_bytes(b"{}")
            self.assertEqual(make_vectors.main(["--check", "--out", str(out)]), 1)

    def test_write_leaves_unowned_files_alone(self):
        with tempfile.TemporaryDirectory() as temp:
            out = Path(temp)
            (out / "renders").mkdir()
            (out / "renders/keep.md").write_text("keep")
            make_vectors.write(out)
            self.assertEqual((out / "renders/keep.md").read_text(), "keep")


class VerdictTests(unittest.TestCase):
    def test_every_vector_has_its_expected_verdict(self):
        self.assertGreaterEqual(len(CASES), 40)
        for case_id, case in CASES.items():
            with self.subTest(case_id):
                self.assertEqual(evaluate(case, FIXTURES), case["expect"])

    def test_acceptance_list_is_covered(self):
        for situation, ids in REQUIRED.items():
            for case_id in ids:
                with self.subTest(situation=situation, case=case_id):
                    self.assertIn(case_id, CASES)
        self.assertEqual(CASES["valid-box"]["expect"]["verdict"], "accept")
        rejected = [c for c in CASES.values() if c["expect"]["verdict"] == "reject"]
        self.assertGreaterEqual(len(rejected), 35)

    def test_tampered_files_differ_by_one_byte_from_their_originals(self):
        pairs = [("keys/keys-2.json", CASES["tampered-keys"]["inputs"]["keys"]),
                 ("channels/stable.json", CASES["tampered-index"]["inputs"]["index"])]
        for original, tampered in pairs:
            a, b = (FIXTURES / original).read_bytes(), (FIXTURES / tampered).read_bytes()
            self.assertEqual(len(a), len(b))
            self.assertEqual(sum(x != y for x, y in zip(a, b)), 1, tampered)

    def test_tampered_blob_is_one_byte_off_its_declared_hash(self):
        case = CASES["tampered-blob"]
        manifest = json.loads((FIXTURES / case["inputs"]["manifest"]).read_text())["signed"]
        feedback = next(c for c in manifest["components"] if c["name"] == "swarmhub-feedback")
        data = (FIXTURES / "blobs/sha256" / feedback["sha256"]).read_bytes()
        self.assertNotEqual(hashlib.sha256(data).hexdigest(), feedback["sha256"])
        self.assertEqual(len(data), feedback["size"])


class KeyAndEncodingTests(unittest.TestCase):
    def test_all_keys_are_test_keys_from_their_published_seeds(self):
        listing = json.loads((FIXTURES / "keys/TEST-keys.json").read_text())
        for key in listing["keys"]:
            self.assertTrue(key["key_id"].startswith("TEST-"))
            expected_seed = hashlib.sha256((listing["seed_label"] + key["key_id"]).encode()).hexdigest()
            self.assertEqual(key["seed"], expected_seed)
            self.assertEqual(ed25519_ref.public_key(bytes.fromhex(key["seed"])).hex(), key["ed25519_pub"])
        for path in FIXTURES.rglob("*.json"):
            for key_id in _key_ids(json.loads(path.read_text(encoding="utf-8"))):
                self.assertTrue(key_id.startswith("TEST-"), f"{path}: {key_id}")

    def test_rfc8032_vector_and_cryptography_cross_check(self):
        secret = bytes.fromhex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")
        public = bytes.fromhex("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")
        signature = bytes.fromhex("e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a3"
                                  "3bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b")
        self.assertEqual(ed25519_ref.public_key(secret), public)
        self.assertEqual(ed25519_ref.sign(secret, b""), signature)
        self.assertTrue(ed25519_ref.verify(public, b"", signature))
        self.assertFalse(ed25519_ref.verify(public, b"x", signature))
        high_s = signature[:32] + (int.from_bytes(signature[32:], "little") + ed25519_ref.L).to_bytes(32, "little")
        self.assertFalse(ed25519_ref.verify(public, b"", high_s))
        try:
            from cryptography.exceptions import InvalidSignature
            from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
        except ImportError:
            self.skipTest("cryptography not installed; RFC 8032 vector checked above")
        listing = json.loads((FIXTURES / "keys/TEST-keys.json").read_text())
        seeds = {k["key_id"]: bytes.fromhex(k["seed"]) for k in listing["keys"]}
        checked = 0
        for path in sorted((FIXTURES / "channels").glob("*.json")) + sorted((FIXTURES / "bundles").glob("*.json")):
            try:
                envelope = jcs.loads(path.read_bytes())
            except jcs.JCSError:
                continue  # the float vector is not valid profile JSON by design
            entry = envelope["signatures"][0]
            ours = ed25519_ref.sign(seeds[entry["key_id"]], signing_message(envelope["signed"]))
            theirs = Ed25519PrivateKey.from_private_bytes(seeds[entry["key_id"]]).sign(
                signing_message(envelope["signed"]))
            self.assertEqual(ours, theirs)
            message, sig = signing_message(envelope["signed"]), bytes.fromhex(entry["sig"])
            public = Ed25519PrivateKey.from_private_bytes(seeds[entry["key_id"]]).public_key()
            try:
                public.verify(sig, message)
                valid = True
            except InvalidSignature:
                valid = False
            pub_bytes = ed25519_ref.public_key(seeds[entry["key_id"]])
            self.assertEqual(ed25519_ref.verify(pub_bytes, message, sig), valid, path.name)
            self.assertEqual(valid, sig == ours, path.name)
            checked += 1
        self.assertGreater(checked, 30)

    def test_jcs_vectors(self):
        for vector in VECTORS["jcs"]:
            with self.subTest(vector["id"]):
                if vector.get("error"):
                    with self.assertRaises(jcs.JCSError):
                        jcs.loads(vector["input"])
                else:
                    self.assertEqual(jcs.canonical(jcs.loads(vector["input"])), vector["canonical"].encode("utf-8"))

    def test_signed_fixture_files_are_canonical_and_float_free(self):
        exempt = {CASES["float-in-signed"]["inputs"]["index"]}
        for sub in ("keys", "channels", "bundles"):
            for path in (FIXTURES / sub).glob("*.json"):
                rel = str(path.relative_to(FIXTURES))
                if rel in exempt:
                    with self.assertRaises(jcs.JCSError):
                        jcs.loads(path.read_bytes())
                    continue
                data = path.read_bytes()
                self.assertEqual(jcs.canonical(jcs.loads(data)), data, rel)

    def test_release_sources_stay_under_500_lines(self):
        for path in (ROOT / "scripts/release").glob("*.py"):
            self.assertLessEqual(len(path.read_text().splitlines()), 500, path.name)


def _key_ids(value):
    if isinstance(value, dict):
        for key, item in value.items():
            if key == "key_id" and isinstance(item, str):
                yield item
            else:
                yield from _key_ids(item)
    elif isinstance(value, list):
        for item in value:
            yield from _key_ids(item)


if __name__ == "__main__":
    unittest.main()
