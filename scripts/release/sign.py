#!/usr/bin/env python3
"""Pluggable signers and signed envelopes for the update service (CORE-PHASES.md P1a; SCHEMAS.md §3).

A signer is anything with a `key_id`, a `public_key()` (32 raw bytes) and a `sign(message)` (64-byte Ed25519
signature over the exact message bytes, pure Ed25519, no prehash). Backends are chosen by a spec string
`<backend>:<argument>`:

    file:<path>     a TEST key file (`keys.py test-key`); pure-Python Ed25519, not constant-time, tests only

A hardware token adapter (P1b) implements `Signer` and registers itself with `register_backend("token", factory)`;
nothing else changes. Every signature is checked against the signer's own public key with the P0b verifier
before it is used, so a faulty adapter cannot publish a bad signature.

Production mode (`--production`, or `production=True`) wraps the signer in `ProductionGuard`, which refuses any
key whose `key_id` starts with `TEST-` (any case) and refuses file keys altogether: real keys live on hardware.

    python3 scripts/release/sign.py --signer file:K --in unsigned.json --out signed.json [--production]
"""

import abc
import argparse
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(ROOT / "Resources/Updater"))

import ed25519_ref  # noqa: E402
import jcs  # noqa: E402
from swarmhub_update import ed25519 as p0b_ed25519  # noqa: E402
from swarmhub_update import verify as p0b  # noqa: E402

TEST_PREFIX = "TEST-"
KEY_FILE_SCHEMA = "swarmhub/test-key/1"


class SignerError(Exception):
    pass


class Signer(abc.ABC):
    """The interface every backend implements. `sign` gets the full message (context line + JCS bytes)."""

    key_id = ""

    @abc.abstractmethod
    def public_key(self):
        """32 raw bytes."""

    @abc.abstractmethod
    def sign(self, message):
        """64 raw bytes: Ed25519 signature of message."""


def is_test_key_id(key_id):
    return key_id.upper().startswith(TEST_PREFIX)


class FileKeySigner(Signer):
    """A TEST key from a JSON file {schema, key_id, seed (64 hex)}. Refuses any key_id without the TEST- prefix."""

    test_only = True

    def __init__(self, key_id, seed):
        if not is_test_key_id(key_id):
            raise SignerError(f"file keys are TEST keys only; {key_id!r} does not start with {TEST_PREFIX}")
        if not p0b.KEY_ID.fullmatch(key_id) or len(seed) != 32:
            raise SignerError(f"bad TEST key {key_id!r}")
        self.key_id, self._seed = key_id, bytes(seed)
        self._public = ed25519_ref.public_key(self._seed)

    @classmethod
    def from_file(cls, path):
        try:
            doc = json.loads(Path(path).read_text(encoding="utf-8"))
            if doc.get("schema") != KEY_FILE_SCHEMA:
                raise SignerError(f"{path}: not a {KEY_FILE_SCHEMA} file")
            return cls(doc["key_id"], bytes.fromhex(doc["seed"]))
        except (OSError, ValueError, KeyError, TypeError, AttributeError) as error:
            raise SignerError(f"cannot read key file {path}: {error}") from error

    def public_key(self):
        return self._public

    def sign(self, message):
        return ed25519_ref.sign(self._seed, message)


class ProductionGuard(Signer):
    """Production mode: never sign with a TEST- key or a test-only backend."""

    def __init__(self, inner):
        if getattr(inner, "test_only", False):
            raise SignerError(f"production mode refuses the test-only backend {type(inner).__name__}")
        if not isinstance(inner.key_id, str) or is_test_key_id(inner.key_id):
            raise SignerError(f"production mode refuses TEST key {inner.key_id!r}")
        self.inner, self.key_id = inner, inner.key_id

    def public_key(self):
        return self.inner.public_key()

    def sign(self, message):
        return self.inner.sign(message)


_BACKENDS = {"file": FileKeySigner.from_file}


def register_backend(name, factory):
    """factory(argument) -> Signer. For the hardware token adapter (P1b)."""
    if name in _BACKENDS:
        raise SignerError(f"signer backend {name!r} already registered")
    _BACKENDS[name] = factory


def load_signer(spec, production=False):
    backend, sep, argument = spec.partition(":")
    if not sep or backend not in _BACKENDS:
        raise SignerError(f"unknown signer {spec!r}; known backends: {', '.join(sorted(_BACKENDS))}")
    signer = _BACKENDS[backend](argument)
    return ProductionGuard(signer) if production else signer


def public_hex(signer):
    public = signer.public_key()
    if not isinstance(public, (bytes, bytearray)) or len(public) != 32:
        raise SignerError(f"signer {signer.key_id!r} returned a bad public key")
    return bytes(public).hex()


def signature_entry(signer, signed):
    """{key_id, sig} for the signed body; the signature is verified with P0b before it is returned."""
    if not p0b.KEY_ID.fullmatch(signer.key_id or ""):
        raise SignerError(f"bad key_id {signer.key_id!r}")
    message = p0b.signing_message(signed)
    signature = signer.sign(message)
    if not isinstance(signature, (bytes, bytearray)) or len(signature) != 64 \
            or not p0b_ed25519.verify(bytes.fromhex(public_hex(signer)), message, bytes(signature)):
        raise SignerError(f"signer {signer.key_id!r} produced a signature that does not verify")
    return {"key_id": signer.key_id, "sig": bytes(signature).hex()}


def envelope(signed, signers):
    """The canonical bytes of {signed, signatures} signed by each signer in order."""
    jcs.check(signed)
    if not signers:
        raise SignerError("at least one signer is needed")
    ids = [s.key_id for s in signers]
    if len(set(ids)) != len(ids):
        raise SignerError(f"duplicate signer {ids}")
    return jcs.canonical({"signed": signed, "signatures": [signature_entry(s, signed) for s in signers]})


def add_signatures(envelope_bytes, signers):
    """Append signatures to an existing envelope (a second root signing later, elsewhere). Body is unchanged."""
    doc = jcs.loads(envelope_bytes)
    if not isinstance(doc, dict) or set(doc) != {"signed", "signatures"}:
        raise SignerError("not a signed envelope")
    present = {entry["key_id"] for entry in doc["signatures"]}
    for signer in signers:
        if signer.key_id in present:
            raise SignerError(f"{signer.key_id} already signed this object")
        doc["signatures"].append(signature_entry(signer, doc["signed"]))
        present.add(signer.key_id)
    return jcs.canonical(doc)


def read_signed_body(path):
    """An unsigned body file, or the `signed` member of an envelope."""
    doc = jcs.loads(Path(path).read_bytes())
    if isinstance(doc, dict) and set(doc) == {"signed", "signatures"}:
        return doc["signed"]
    return doc


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--signer", required=True, help="backend:argument, e.g. file:TEST-release-1.key.json")
    parser.add_argument("--in", dest="source", type=Path, required=True, help="unsigned body (JSON)")
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--production", action="store_true", help="refuse TEST- keys and test-only backends")
    args = parser.parse_args(argv)
    try:
        signer = load_signer(args.signer, args.production)
        data = envelope(read_signed_body(args.source), [signer])
    except (SignerError, jcs.JCSError, OSError) as error:
        print(f"sign: {error}", file=sys.stderr)
        return 1
    args.out.write_bytes(data)
    print(f"signed {args.source} with {signer.key_id} -> {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
