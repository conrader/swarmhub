"""P0b: the updater's verifier library (Resources/Updater/swarmhub_update) against the P0a vectors.

Every vector in Tests/Fixtures/release-bundles/vectors.json must give its expected verdict through
swarmhub_update.verify (never scripts/release/reference_verify.py); malformed shapes are verdicts, not crashes; the
vendored Ed25519 agrees with RFC 8032 and `cryptography`; the package imports only the standard library.
Extractor containment tests live in test_archive.py.

    python3 -m unittest discover -s Tests/Updater
"""

import ast
import hashlib
import json
import os
from pathlib import Path
import random
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
PACKAGE_PARENT = ROOT / "Resources/Updater"
PACKAGE = PACKAGE_PARENT / "swarmhub_update"
sys.path.insert(0, str(PACKAGE_PARENT))

from swarmhub_update import ed25519, jcs, verify  # noqa: E402

FIXTURES = ROOT / "Tests/Fixtures/release-bundles"
VECTORS = json.loads((FIXTURES / "vectors.json").read_text(encoding="utf-8"))
CASES = {case["id"]: case for case in VECTORS["cases"]}
BAD_VALUES = [[{}], [[]], {}, [], "", "\n", "box\n", "TEST-release-1\n", 0, -1, True, 2**60, [1], ["box", "box"]]
CONTROL_CHARS = [chr(c) for c in list(range(1, 32)) + [127]]
RFC8032 = [  # RFC 8032 §7.1 TEST 1 and TEST 2: (secret, public, message, signature)
    ("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60",
     "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a", "",
     "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b"),
    ("4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb",
     "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c", "72",
     "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00"),
]


def run_case(case, root=FIXTURES, fetched=None):
    """Evaluate one vector through the library; the fixture directory stands in for the service and pin file."""
    inputs = case["inputs"]

    def fetch_blob(component):
        if fetched is not None:
            fetched.append(component["name"])
        return (root / "blobs/sha256" / component["sha256"]).read_bytes()
    return verify.verify_release(
        (root / inputs["pins"]).read_bytes(), (root / inputs["keys"]).read_bytes(),
        (root / inputs["index"]).read_bytes(),
        fetch_manifest=lambda line: (root / inputs["manifest"]).read_bytes(),
        fetch_blob=fetch_blob, channel=inputs["channel"], now=inputs["now"], floors=inputs["floors"],
        consumer=inputs["consumer"], install_id=inputs["install_id"], revoked_key_ids=inputs["revoked_key_ids"],
        limits=inputs["limits"])


def public_verdict(verdict):
    """The verdict without the verified payload (manifest, blobs), i.e. the `expect` shape of vectors.json."""
    return {k: v for k, v in verdict.items() if k not in ("manifest", "blobs")}


class VectorTests(unittest.TestCase):
    def test_every_p0a_vector_gives_its_expected_verdict(self):
        self.assertEqual(len(CASES), 54)
        counts = {}
        for case_id, case in CASES.items():
            with self.subTest(case_id):
                verdict = public_verdict(run_case(case))
                self.assertEqual(verdict, case["expect"])
                counts[verdict["verdict"]] = counts.get(verdict["verdict"], 0) + 1
        self.assertEqual(counts, {"accept": 6, "no_update": 2, "reject": 46})

    def test_the_reference_verifier_is_not_loaded(self):
        for name in ("reference_verify", "schemas", "ed25519_ref", "vector_world"):
            self.assertNotIn(name, sys.modules)
        self.assertNotIn(str(ROOT / "scripts/release"), sys.path)

    def test_accept_returns_the_verified_manifest_and_blobs(self):
        verdict = run_case(CASES["valid-box"])
        self.assertEqual(sorted(verdict["blobs"]), sorted(verdict["apply"]))
        for component in verdict["manifest"]["components"]:
            if component["name"] in verdict["blobs"]:
                self.assertEqual(hashlib.sha256(verdict["blobs"][component["name"]]).hexdigest(),
                                 component["sha256"])

    def test_blobs_are_fetched_only_for_applied_components_after_the_size_check(self):
        fetched = []
        verdict = run_case(CASES["incompatible-component"], fetched=fetched)
        self.assertEqual(fetched, verdict["apply"])
        self.assertNotIn("swarm-tools", fetched)
        fetched.clear()
        self.assertEqual(run_case(CASES["archive-oversize-blob"], fetched=fetched)["reason"], "archive_oversize")
        self.assertEqual(fetched, [])  # the declared size is refused before any download

    def test_bad_caller_inputs_are_programming_errors(self):
        case = json.loads(json.dumps(CASES["valid-box"]))
        case["inputs"]["now"] = "2026-10-20 12:00"
        with self.assertRaises(ValueError):
            run_case(case)

    def test_jcs_vectors(self):
        for vector in VECTORS["jcs"]:
            with self.subTest(vector["id"]):
                if vector.get("error"):
                    with self.assertRaises(jcs.JCSError):
                        jcs.loads(vector["input"])
                else:
                    self.assertEqual(jcs.canonical(jcs.loads(vector["input"])), vector["canonical"].encode("utf-8"))

    def test_jcs_rejects_non_ascii_digits(self):
        with self.assertRaises(jcs.JCSError):
            jcs._parse_int("١")


class MalformedShapeTests(unittest.TestCase):
    """Any malformed shape is a Reject, never another exception (fail closed, never crash)."""

    def _objects(self):
        def load(rel):
            return jcs.loads((FIXTURES / rel).read_bytes())
        return [(verify.check_pins, load("keys/pins.json")),
                (verify.check_key_manifest, load("keys/keys-2.json")["signed"]),
                (verify.check_index, load("channels/stable.json")["signed"]),
                (verify.check_bundle, load("bundles/11.json")["signed"]),
                (lambda e: verify.check_envelope(e, "keys"), load("keys/keys-2--two-roots.json")),
                (lambda e: verify.check_envelope(e, "index"), load("channels/stable.json"))]

    def test_every_single_member_mutation_is_rejected_or_valid(self):
        checked = 0
        for check, valid in self._objects():
            check(valid)
            for mutated in _mutations(valid):
                try:
                    check(mutated)
                except verify.Reject:
                    pass
                checked += 1
        self.assertGreater(checked, 1000)

    def test_whole_chain_with_mutated_signed_files_returns_a_verdict(self):
        """Re-serialise mutated objects as the served file: the chain returns a verdict for every one."""
        base = CASES["valid-box"]["inputs"]
        rng = random.Random(8032)
        for rel, slot in ((base["keys"], "keys"), (base["index"], "index")):
            envelope = jcs.loads((FIXTURES / rel).read_bytes())
            mutations = list(_mutations(envelope))
            for mutated in rng.sample(mutations, min(150, len(mutations))):
                raw = json.dumps(mutated).encode("utf-8")
                files = {k: (FIXTURES / base[k]).read_bytes() for k in ("pins", "keys", "index")}
                files[slot] = raw
                verdict = verify.verify_release(
                    files["pins"], files["keys"], files["index"],
                    fetch_manifest=lambda line: (FIXTURES / base["manifest"]).read_bytes(),
                    fetch_blob=lambda c: (FIXTURES / "blobs/sha256" / c["sha256"]).read_bytes(),
                    channel=base["channel"], now=base["now"], floors=base["floors"], consumer=base["consumer"],
                    install_id=base["install_id"], limits=base["limits"])
                self.assertIn(verdict["verdict"], ("accept", "reject", "no_update"))

    def test_component_paths_with_control_characters_are_schema_invalid(self):
        bundle = jcs.loads((FIXTURES / "bundles/11.json").read_bytes())["signed"]
        for char in CONTROL_CHARS:
            for path in (f"swarmhub-feedback{char}", f"swarm{char}hub", f"{char}x", f"a/b{char}"):
                with self.subTest(path=path):
                    bundle["components"][1]["path"] = path
                    with self.assertRaises(verify.Reject) as caught:
                        verify.check_bundle(bundle)
                    self.assertEqual(caught.exception.reason, "schema_invalid")

    def test_trailing_newline_never_matches_a_pattern(self):
        for pattern, good in ((verify.KEY_ID, "TEST-release-1"), (verify.NAME, "policy"), (verify.CHANNEL, "stable"),
                              (verify.AXIS, "hermes"), (verify.VERSION, "1.3.12"), (verify.HEX64, "0" * 64),
                              (verify.TIMESTAMP, "2026-10-20T12:00:00Z")):
            self.assertTrue(verify._is_str(good, pattern))
            self.assertFalse(verify._is_str(good + "\n", pattern), pattern.pattern)


class Ed25519Tests(unittest.TestCase):
    def test_rfc8032_vectors(self):
        for _, public, message, signature in RFC8032:
            public, message, signature = bytes.fromhex(public), bytes.fromhex(message), bytes.fromhex(signature)
            self.assertTrue(ed25519.verify(public, message, signature))
            self.assertFalse(ed25519.verify(public, message + b"x", signature))

    def test_rejects_high_s_bad_points_and_bad_lengths(self):
        _, public, message, signature = (bytes.fromhex(x) for x in RFC8032[0])
        high_s = signature[:32] + (int.from_bytes(signature[32:], "little") + ed25519.L).to_bytes(32, "little")
        self.assertFalse(ed25519.verify(public, message, high_s))
        non_canonical_y = (ed25519.P + 1).to_bytes(32, "little")  # y >= p never decodes
        self.assertIsNone(ed25519.decode_point(non_canonical_y))
        self.assertFalse(ed25519.verify(non_canonical_y, message, signature))
        self.assertFalse(ed25519.verify(public, message, non_canonical_y + signature[32:]))
        self.assertFalse(ed25519.verify(public[:31], message, signature))
        self.assertFalse(ed25519.verify(public, message, signature[:63]))
        self.assertFalse(ed25519.verify(public, message, None))

    def test_fixture_signatures_verify_with_the_published_test_keys(self):
        listing = json.loads((FIXTURES / "keys/TEST-keys.json").read_text())
        publics = {k["key_id"]: bytes.fromhex(k["ed25519_pub"]) for k in listing["keys"]}
        valid = 0
        for rel in ("keys/keys-2.json", "channels/stable.json", "bundles/11.json"):
            envelope = jcs.loads((FIXTURES / rel).read_bytes())
            for entry in envelope["signatures"]:
                self.assertTrue(ed25519.verify(publics[entry["key_id"]], verify.signing_message(envelope["signed"]),
                                               bytes.fromhex(entry["sig"])), rel)
                valid += 1
        self.assertEqual(valid, 3)

    def test_cross_check_against_cryptography(self):
        try:
            from cryptography.exceptions import InvalidSignature
            from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey
            from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
        except ImportError:
            self.skipTest("cryptography not installed; RFC 8032 vectors checked in test_rfc8032_vectors")

        def theirs(public, message, signature):
            try:
                Ed25519PublicKey.from_public_bytes(public).verify(signature, message)
                return True
            except (InvalidSignature, ValueError):
                return False
        rng = random.Random(25519)
        agreed = 0
        for i in range(120):
            key = Ed25519PrivateKey.from_private_bytes(rng.getrandbits(256).to_bytes(32, "little"))
            public = key.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
            message = bytes(rng.randrange(256) for _ in range(i % 70))
            signature = key.sign(message)
            self.assertTrue(ed25519.verify(public, message, signature))
            for _ in range(3):  # one flipped bit in the signature, the key or the message
                sig, pub, msg = bytearray(signature), bytearray(public), bytearray(message)
                target = rng.choice([sig, pub, msg] if msg else [sig, pub])
                bit = rng.randrange(8 * len(target))
                target[bit // 8] ^= 1 << (bit % 8)
                self.assertEqual(ed25519.verify(bytes(pub), bytes(msg), bytes(sig)),
                                 theirs(bytes(pub), bytes(msg), bytes(sig)))
                agreed += 1
        for path in sorted((FIXTURES / "channels").glob("*.json")) + sorted((FIXTURES / "bundles").glob("*.json")):
            try:
                envelope = jcs.loads(path.read_bytes())
            except jcs.JCSError:
                continue  # the float vector is not profile JSON by design
            listing = json.loads((FIXTURES / "keys/TEST-keys.json").read_text())
            publics = {k["key_id"]: bytes.fromhex(k["ed25519_pub"]) for k in listing["keys"]}
            entry = envelope["signatures"][0]
            if entry["key_id"] not in publics:
                continue  # malformed key_id vector
            message, sig = verify.signing_message(envelope["signed"]), bytes.fromhex(entry["sig"])
            self.assertEqual(ed25519.verify(publics[entry["key_id"]], message, sig),
                             theirs(publics[entry["key_id"]], message, sig), path.name)
            agreed += 1
        self.assertGreater(agreed, 390)


class StdlibOnlyTests(unittest.TestCase):
    def test_every_import_is_stdlib_or_package_relative(self):
        stdlib = getattr(sys, "stdlib_module_names", None)
        if stdlib is None:
            self.skipTest("sys.stdlib_module_names needs Python 3.10+; the -I -S import test still runs")
        for path in sorted(PACKAGE.glob("*.py")):
            tree = ast.parse(path.read_text(encoding="utf-8"))
            for node in ast.walk(tree):
                if isinstance(node, ast.Import):
                    names = [alias.name for alias in node.names]
                elif isinstance(node, ast.ImportFrom) and node.level == 0:
                    names = [node.module]
                else:
                    continue
                for name in names:
                    self.assertIn(name.split(".")[0], stdlib, f"{path.name}: import {name}")

    def test_imports_and_verifies_without_site_packages(self):
        """-I -S: no site-packages, no user site, no PYTHONPATH; `cryptography` is blocked outright."""
        case = CASES["valid-box"]
        script = (
            "import sys, json\n"
            "sys.modules['cryptography'] = None\n"
            f"sys.path.insert(0, {str(PACKAGE_PARENT)!r}); sys.path.insert(0, {str(Path(__file__).parent)!r})\n"
            "import swarmhub_update.verify, swarmhub_update.archive, swarmhub_update.ed25519, swarmhub_update.jcs\n"
            "import test_verify as t\n"
            f"print(json.dumps(t.public_verdict(t.run_case(t.CASES[{case['id']!r}]))))\n"
            "bad = [m for m, mod in sys.modules.items() if mod is not None and 'site-packages' in "
            "(getattr(mod, '__file__', None) or '')]\n"
            "print(json.dumps(bad))\n")
        env = {k: v for k, v in os.environ.items() if not k.startswith("PYTHON")}
        result = subprocess.run([sys.executable, "-I", "-S", "-B", "-c", script], capture_output=True, text=True, env=env,
                                timeout=120)
        self.assertEqual(result.returncode, 0, result.stderr)
        verdict_line, bad_line = result.stdout.strip().splitlines()[-2:]
        self.assertEqual(json.loads(verdict_line), case["expect"])
        self.assertEqual(json.loads(bad_line), [])

    def test_sources_stay_under_500_lines(self):
        for path in list(PACKAGE.glob("*.py")) + list(Path(__file__).parent.glob("*.py")):
            self.assertLessEqual(len(path.read_text(encoding="utf-8").splitlines()), 500, path.name)


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


if __name__ == "__main__":
    unittest.main()
