"""Verify-only Ed25519 (RFC 8032 §5.1.7, pure, no prehash), vendored so the updater needs no `cryptography`.

There is no signing code here: the updater only ever verifies. Verification is cofactorless ([S]B = R + [k]A) and
rejects a non-canonical S (S >= L), encodings with y >= p, and points that do not decode, as SCHEMAS.md §3 requires.
Tests cross-check it against RFC 8032 vectors and, where installed, `cryptography`. Stdlib only, Python 3.8+.
"""

import hashlib

P = 2**255 - 19
L = 2**252 + 27742317777372353535851937790883648493


def _inv(x):
    return pow(x, P - 2, P)


D = -121665 * _inv(121666) % P
SQRT_M1 = pow(2, (P - 1) // 4, P)
IDENTITY = (0, 1, 1, 0)


def _add(a, b):
    """Point addition in extended twisted Edwards coordinates (X, Y, Z, T), RFC 8032 §5.1.4."""
    x = (a[1] - a[0]) * (b[1] - b[0]) % P
    y = (a[1] + a[0]) * (b[1] + b[0]) % P
    c = 2 * a[3] * b[3] * D % P
    d = 2 * a[2] * b[2] % P
    e, f, g, h = y - x, d - c, d + c, y + x
    return (e * f % P, g * h % P, f * g % P, e * h % P)


def _mul(scalar, point):
    result = IDENTITY
    while scalar > 0:
        if scalar & 1:
            result = _add(result, point)
        point = _add(point, point)
        scalar >>= 1
    return result


def _equal(a, b):
    return (a[0] * b[2] - b[0] * a[2]) % P == 0 and (a[1] * b[2] - b[1] * a[2]) % P == 0


def _recover_x(y, sign):
    if y >= P:
        return None
    x2 = (y * y - 1) * _inv(D * y * y + 1) % P
    if x2 == 0:
        return None if sign else 0
    x = pow(x2, (P + 3) // 8, P)
    if (x * x - x2) % P != 0:
        x = x * SQRT_M1 % P
    if (x * x - x2) % P != 0:
        return None
    if (x & 1) != sign:
        x = P - x
    return x


_GY = 4 * _inv(5) % P
_GX = _recover_x(_GY, 0)
BASE = (_GX, _GY, 1, _GX * _GY % P)


def decode_point(data):
    """The point encoded by 32 bytes, or None when the encoding is invalid (RFC 8032 §5.1.3)."""
    if not isinstance(data, (bytes, bytearray)) or len(data) != 32:
        return None
    y = int.from_bytes(data, "little")
    sign = y >> 255
    y &= (1 << 255) - 1
    x = _recover_x(y, sign)
    if x is None:
        return None
    return (x, y, 1, x * y % P)


def verify(public, message, signature):
    """True when signature (64 bytes) is a valid Ed25519 signature of message under public (32 bytes)."""
    if not isinstance(signature, (bytes, bytearray)) or len(signature) != 64:
        return False
    a = decode_point(public)
    r = decode_point(signature[:32])
    if a is None or r is None:
        return False
    s = int.from_bytes(signature[32:], "little")
    if s >= L:
        return False
    k = int.from_bytes(hashlib.sha512(bytes(signature[:32]) + bytes(public) + bytes(message)).digest(), "little") % L
    return _equal(_mul(s, BASE), _add(r, _mul(k, a)))
