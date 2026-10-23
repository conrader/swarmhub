"""Sealed alert settings: the app encrypts the alert configuration (ntfy token, SMTP password) to this box's own key,
so the one terminal call that carries it through a model turn holds only ciphertext. Standard library only.

Box key: X25519 (RFC 7748), private part in ~/.hermes/swarmhub/alerts/box.key (0600); only the public part leaves.
Blob: "v1." + base64url(ephemeral public 32 || ciphertext || tag 16), where
  okm  = HKDF-SHA256(salt = ephemeral public || box public, ikm = X25519 shared secret, info = INFO, 64 bytes)
  key stream block i = HMAC-SHA256(okm[:32], i as 8-byte big-endian); ciphertext = plaintext XOR key stream
  tag  = HMAC-SHA256(okm[32:], ephemeral public || ciphertext)[:16]
The app side is CryptoKit (Curve25519.KeyAgreement, HKDF<SHA256>, HMAC<SHA256>), `AlertSeal` in BoxAlerts.swift.
"""
import base64
import hashlib
import hmac
import json
import os

from swarm_intake import write_private

P = 2 ** 255 - 19
INFO = b"swarmhub-alerts-seal-v1"
LIMIT = 4096


def x25519(scalar, point):
    """RFC 7748 section 5: the Montgomery ladder over Curve25519."""
    k = bytearray(scalar)
    k[0] &= 248
    k[31] &= 127
    k[31] |= 64
    k = int.from_bytes(bytes(k), "little")
    x1 = int.from_bytes(point, "little") & ((1 << 255) - 1)
    x2, z2, x3, z3, swap = 1, 0, x1, 1, 0
    for t in reversed(range(255)):
        bit = (k >> t) & 1
        swap ^= bit
        if swap:
            x2, x3, z2, z3 = x3, x2, z3, z2
        swap = bit
        a, b = (x2 + z2) % P, (x2 - z2) % P
        aa, bb = a * a % P, b * b % P
        e = (aa - bb) % P
        c, d = (x3 + z3) % P, (x3 - z3) % P
        da, cb = d * a % P, c * b % P
        x3, z3 = (da + cb) ** 2 % P, x1 * (da - cb) ** 2 % P
        x2, z2 = aa * bb % P, e * (aa + 121665 * e) % P
    if swap:
        x2, z2 = x3, z3
    return (x2 * pow(z2, P - 2, P) % P).to_bytes(32, "little")


def public(private):
    return x25519(private, (9).to_bytes(32, "little"))


def hkdf(salt, ikm, info, length):
    prk = hmac.new(salt, ikm, hashlib.sha256).digest()
    out, block, counter = b"", b"", 1
    while len(out) < length:
        block = hmac.new(prk, block + info + bytes([counter]), hashlib.sha256).digest()
        out, counter = out + block, counter + 1
    return out[:length]


def stream(key, data):
    blocks = b"".join(hmac.new(key, i.to_bytes(8, "big"), hashlib.sha256).digest() for i in range((len(data) + 31) // 32))
    return bytes(a ^ b for a, b in zip(data, blocks))


def b64(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def unb64(text):
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


def keys(ephemeral_public, box_public, shared):
    okm = hkdf(ephemeral_public + box_public, shared, INFO, 64)
    return okm[:32], okm[32:]


def seal(box_public, plaintext, ephemeral=None):
    """What the app does; here for tests and the test vector."""
    ephemeral = ephemeral or os.urandom(32)
    mine = public(ephemeral)
    enc, mac = keys(mine, box_public, x25519(ephemeral, box_public))
    body = stream(enc, plaintext)
    return "v1." + b64(mine + body + hmac.new(mac, mine + body, hashlib.sha256).digest()[:16])


def open_sealed(private, blob):
    """The plaintext of a blob sealed to this box's key. ValueError for anything else (wrong key, edited, truncated)."""
    if not isinstance(blob, str) or not blob.startswith("v1.") or len(blob) > LIMIT * 2:
        raise ValueError("sealed alert settings are not readable")
    try:
        raw = unb64(blob[3:])
    except (ValueError, TypeError) as exc:
        raise ValueError("sealed alert settings are not readable") from exc
    if len(raw) < 49:
        raise ValueError("sealed alert settings are not readable")
    theirs, body, tag = raw[:32], raw[32:-16], raw[-16:]
    shared = x25519(private, theirs)
    if shared == bytes(32):
        raise ValueError("sealed alert settings are not readable")
    enc, mac = keys(theirs, public(private), shared)
    if not hmac.compare_digest(hmac.new(mac, theirs + body, hashlib.sha256).digest()[:16], tag):
        raise ValueError("sealed alert settings do not match this box's key (refresh the status, then save again)")
    return stream(enc, body)


def open_settings(private, blob):
    """The alert settings the app sealed to this box, parsed (`swarm_alerts.configure`)."""
    plain = open_sealed(private, blob)
    try:
        return json.loads(plain.decode("utf-8"))
    except ValueError:  # UnicodeDecodeError and JSONDecodeError both
        raise ValueError("the sealed alert settings are not valid JSON") from None


def revision(config):
    """recsfix3: how often the settings were saved (0: never, or by a skill before revisions)."""
    value = (config or {}).get("revision")
    return value if isinstance(value, int) and not isinstance(value, bool) and value > 0 else 0


def revised(raw, config, previous):
    """recsfix3: the validated `config` with its revision, or None for an automatic push of the app (`if_revision`) over
    settings saved since `previous` (from another Mac): newer settings win. A save by the user (none) always applies."""
    expected = raw.get("if_revision") if isinstance(raw, dict) else None
    if expected is not None and expected != revision(previous):
        return None
    return dict(config, revision=revision(previous) + 1)


def box_key(folder):
    """This box's private key, created on first use (0600 in a 0700 folder)."""
    path = folder / "box.key"
    try:
        private = unb64(path.read_text().strip())
        if len(private) == 32:
            return private
    except (OSError, ValueError):
        pass
    private = os.urandom(32)
    write_private(path, (b64(private) + "\n").encode())
    return private
