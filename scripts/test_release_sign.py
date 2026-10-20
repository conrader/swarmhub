"""P1a: pluggable signers, production mode and signed envelopes (scripts/release/sign.py).

    python3 scripts/test_release_sign.py
"""

import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/release"))

import jcs  # noqa: E402
import keys  # noqa: E402
import sign  # noqa: E402
import vector_world  # noqa: E402
from sign import p0b, p0b_ed25519  # noqa: E402

BODY = {"schema": "swarmhub/index/1", "channel": "stable", "seq": 1, "issued": "2026-10-20T00:00:00Z",
        "expires": "2026-10-27T00:00:00Z", "lines": []}


def key_file(directory, key_id):
    path = Path(directory) / f"{key_id}.key.json"
    path.write_text(json.dumps(keys.test_key_document(key_id)), encoding="utf-8")
    return path


class FakeToken(sign.Signer):
    """Stands in for a hardware token adapter: no key material, it only records what it was asked to sign."""

    def __init__(self, key_id, public=b"\x01" * 32, signature=b"\x02" * 64):
        self.key_id, self._public, self._signature, self.messages = key_id, public, signature, []

    def public_key(self):
        return self._public

    def sign(self, message):
        self.messages.append(message)
        return self._signature


class WrongSeed(sign.FileKeySigner):
    """A faulty adapter: reports one key's public key but signs with another."""

    def public_key(self):
        return bytes.fromhex(vector_world.public_hex("TEST-release-1"))


class FileSignerTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)

    def test_file_signer_signs_what_p0b_verifies(self):
        signer = sign.load_signer(f"file:{key_file(self.dir.name, 'TEST-release-1')}")
        self.assertEqual(signer.key_id, "TEST-release-1")
        self.assertEqual(sign.public_hex(signer), vector_world.public_hex("TEST-release-1"))
        doc = jcs.loads(sign.envelope(BODY, [signer]))
        self.assertEqual(doc["signed"], BODY)
        self.assertTrue(p0b_ed25519.verify(signer.public_key(), p0b.signing_message(BODY),
                                           bytes.fromhex(doc["signatures"][0]["sig"])))
        self.assertEqual(sign.envelope(BODY, [signer]), jcs.canonical(doc))  # deterministic, canonical bytes

    def test_file_signer_refuses_non_test_ids_and_bad_files(self):
        with self.assertRaisesRegex(sign.SignerError, "TEST keys only"):
            sign.FileKeySigner("release-1", vector_world.seed("release-1"))
        bad = Path(self.dir.name) / "bad.json"
        bad.write_text('{"schema": "other"}', encoding="utf-8")
        with self.assertRaisesRegex(sign.SignerError, "not a swarmhub/test-key/1"):
            sign.load_signer(f"file:{bad}")
        with self.assertRaisesRegex(sign.SignerError, "cannot read"):
            sign.load_signer(f"file:{bad}.missing")
        with self.assertRaisesRegex(sign.SignerError, "unknown signer"):
            sign.load_signer("pkcs11:slot0")
        with self.assertRaisesRegex(keys.KeysError, "TEST- keys only"):
            keys.test_key_document("release-1")

    def test_a_signature_that_does_not_verify_is_never_used(self):
        wrong = WrongSeed("TEST-rogue", vector_world.seed("TEST-rogue"))
        with self.assertRaisesRegex(sign.SignerError, "does not verify"):
            sign.envelope(BODY, [wrong])
        with self.assertRaisesRegex(sign.SignerError, "does not verify"):
            sign.envelope(BODY, [FakeToken("hw-release-1")])
        with self.assertRaisesRegex(sign.SignerError, "bad public key"):
            sign.envelope(BODY, [FakeToken("hw-release-1", public=b"\x01")])

    def test_add_signatures_keeps_the_body_and_refuses_duplicates(self):
        one = sign.load_signer(f"file:{key_file(self.dir.name, 'TEST-root-1')}")
        two = sign.load_signer(f"file:{key_file(self.dir.name, 'TEST-root-2')}")
        first = sign.envelope(BODY, [one])
        both = jcs.loads(sign.add_signatures(first, [two]))
        self.assertEqual(both["signed"], BODY)
        self.assertEqual([s["key_id"] for s in both["signatures"]], ["TEST-root-1", "TEST-root-2"])
        with self.assertRaisesRegex(sign.SignerError, "already signed"):
            sign.add_signatures(first, [one])
        with self.assertRaisesRegex(sign.SignerError, "duplicate signer"):
            sign.envelope(BODY, [one, one])


class ProductionModeTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)

    def test_production_refuses_every_test_key(self):
        for key_id in ("TEST-release-1", "test-release-1", "Test-root-2"):
            with self.assertRaisesRegex(sign.SignerError, "refuses TEST key"):
                sign.ProductionGuard(FakeToken(key_id))
        path = key_file(self.dir.name, "TEST-release-1")
        with self.assertRaisesRegex(sign.SignerError, "production mode refuses"):
            sign.load_signer(f"file:{path}", production=True)
        self.assertEqual(sign.main(["--signer", f"file:{path}", "--in", str(path), "--out",
                                    str(Path(self.dir.name) / "out.json"), "--production"]), 1)
        self.assertFalse((Path(self.dir.name) / "out.json").exists())

    def test_production_refuses_file_keys_even_without_the_prefix(self):
        signer = sign.FileKeySigner("TEST-release-1", vector_world.seed("TEST-release-1"))
        signer.key_id = "release-2027"  # a file key renamed to dodge the prefix check
        with self.assertRaisesRegex(sign.SignerError, "test-only backend"):
            sign.ProductionGuard(signer)

    def test_a_registered_token_backend_is_wrapped_and_delegates(self):
        token = FakeToken("hw-release-1")
        name = "fake-token-test"
        sign.register_backend(name, lambda argument: token)
        with self.assertRaisesRegex(sign.SignerError, "already registered"):
            sign.register_backend(name, lambda argument: token)
        guarded = sign.load_signer(f"{name}:slot0", production=True)
        self.assertIsInstance(guarded, sign.ProductionGuard)
        self.assertEqual(guarded.key_id, "hw-release-1")
        self.assertEqual(guarded.sign(b"m"), b"\x02" * 64)
        self.assertEqual(token.messages, [b"m"])
        self.assertIs(sign.load_signer(f"{name}:slot0"), token)


class CliTests(unittest.TestCase):
    def test_sign_cli_writes_an_envelope(self):
        with tempfile.TemporaryDirectory() as temp:
            path = key_file(temp, "TEST-release-1")
            body = Path(temp) / "body.json"
            body.write_bytes(jcs.canonical(BODY))
            out = Path(temp) / "signed.json"
            self.assertEqual(sign.main(["--signer", f"file:{path}", "--in", str(body), "--out", str(out)]), 0)
            self.assertEqual(jcs.loads(out.read_bytes())["signed"], BODY)
            self.assertEqual(sign.read_signed_body(out), BODY)


if __name__ == "__main__":
    unittest.main()
