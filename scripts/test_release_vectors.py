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
import schemas  # noqa: E402
import ustar  # noqa: E402
from reference_verify import check_archive, evaluate, signing_message  # noqa: E402

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
    "malformed shapes": ["keys-roles-object", "manifest-targets-object", "manifest-kind-array"],
    "path grammar": ["index-key-id-newline", "manifest-path-newline", "archive-path-newline"],
}
# Values that must never crash a structural check: unhashable, wrong type, trailing newline, out of range.
BAD_VALUES = [[{}], [[]], {}, [], "", "\n", "box\n", "TEST-release-1\n", 0, -1, True, 2**60, [1], ["box", "box"]]
CONTROL_CHARS = [chr(c) for c in list(range(1, 32)) + [127]]


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

    def test_schemas_doc_states_the_vector_counts(self):
        verdicts = [c["expect"]["verdict"] for c in CASES.values()]
        text = (ROOT / "docs/update-service/SCHEMAS.md").read_text(encoding="utf-8")
        stated = f"{len(verdicts)} cases: {verdicts.count('accept')} `accept`, {verdicts.count('no_update')} " \
                 f"`no_update`, {verdicts.count('reject')} `reject`; {len(VECTORS['jcs'])} JCS vectors"
        self.assertIn(stated, text)

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
            if entry["key_id"] not in seeds:
                continue  # malformed key_id vector: schema_invalid before any signature check
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


class MalformedShapeTests(unittest.TestCase):
    """Every malformed shape is a Reject (schema_invalid or a later verdict), never another exception."""

    def _objects(self):
        def signed(rel):
            return jcs.loads((FIXTURES / rel).read_bytes())
        return [(schemas.check_pins, jcs.loads((FIXTURES / "keys/pins.json").read_bytes())),
                (schemas.check_key_manifest, signed("keys/keys-2.json")["signed"]),
                (schemas.check_index, signed("channels/stable.json")["signed"]),
                (schemas.check_bundle, signed("bundles/11.json")["signed"]),
                (lambda e: schemas.check_envelope(e, "keys"), signed("keys/keys-2--two-roots.json")),
                (lambda e: schemas.check_envelope(e, "index"), signed("channels/stable.json"))]

    def test_every_single_member_mutation_is_rejected_or_valid(self):
        checked = 0
        for check, valid in self._objects():
            check(valid)
            for mutated in _mutations(valid):
                try:
                    check(mutated)
                except schemas.Reject:
                    pass
                checked += 1
        self.assertGreater(checked, 1000)

    def test_component_paths_with_control_characters_are_schema_invalid(self):
        bundle = jcs.loads((FIXTURES / "bundles/11.json").read_bytes())["signed"]
        for char in CONTROL_CHARS:
            for path in (f"swarmhub-feedback{char}", f"swarm{char}hub", f"{char}x", f"a/b{char}"):
                with self.subTest(path=path):
                    bundle["components"][1]["path"] = path
                    with self.assertRaises(schemas.Reject) as caught:
                        schemas.check_bundle(bundle)
                    self.assertEqual(caught.exception.reason, "schema_invalid")

    def test_archive_paths_with_control_characters_are_unsafe(self):
        limits = CASES["valid-box"]["inputs"]["limits"]
        for char in CONTROL_CHARS:
            for name in (f"SKILL.md{char}", f"scripts/re{char}port", f"{char}a.md"):
                with self.subTest(name=name):
                    data = ustar.build([{"name": name, "type": "file", "mode": 0o644, "data": b"x"}])
                    with self.assertRaises(schemas.Reject) as caught:
                        check_archive(data, "skill", limits)
                    self.assertEqual(caught.exception.reason, "archive_unsafe_path")


def _mutations(value):
    """Copies of value with one member or element replaced by each BAD_VALUES entry or removed, at any depth."""
    if isinstance(value, dict):
        for key in value:
            yield {k: v for k, v in value.items() if k != key}
            for bad in BAD_VALUES:
                yield {**value, key: bad}
            for inner in _mutations(value[key]):
                yield {**value, key: inner}
    elif isinstance(value, list):
        for i, item in enumerate(value):
            for bad in BAD_VALUES:
                yield value[:i] + [bad] + value[i + 1:]
            for inner in _mutations(item):
                yield value[:i] + [inner] + value[i + 1:]


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
