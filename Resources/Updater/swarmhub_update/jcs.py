"""RFC 8785 (JCS) canonical JSON for Swarm Hub signed objects, restricted profile (docs/update-service/SCHEMAS.md §2).

The profile forbids floating-point numbers, so canonical form is: members sorted by name, no insignificant
whitespace, UTF-8, and JCS string escaping. Integers must be safe (|n| <= 2**53 - 1), member names are ASCII,
null and duplicate names are rejected. Stdlib only, Python 3.8+. Same profile as the P0a generator's
scripts/release/jcs.py; both are checked against the JCS vectors in Tests/Fixtures/release-bundles/vectors.json.
"""

import json
import re

_INTEGER = re.compile(r"-?(0|[1-9][0-9]*)")
MAX_SAFE_INT = 2**53 - 1
MAX_DEPTH = 32


class JCSError(ValueError):
    pass


def _reject_constant(name):
    raise JCSError(f"non-finite number {name}")


def _reject_float(text):
    raise JCSError(f"floating-point number {text}")


def _parse_int(text):
    if not _INTEGER.fullmatch(text):  # ASCII digits only, whichever json scanner is in use
        raise JCSError(f"invalid integer {text!r}")
    if text == "-0":
        raise JCSError("negative zero")
    value = int(text)
    if abs(value) > MAX_SAFE_INT:
        raise JCSError(f"integer out of range {text}")
    return value


def _pairs(pairs):
    out = {}
    for key, value in pairs:
        if key in out:
            raise JCSError(f"duplicate member {key!r}")
        out[key] = value
    return out


def loads(data):
    """Parse bytes or str as JSON under the profile; returns the value or raises JCSError."""
    if isinstance(data, bytes):
        try:
            data = data.decode("utf-8")
        except UnicodeDecodeError as error:
            raise JCSError("invalid UTF-8") from error
    if data.startswith("﻿"):
        raise JCSError("byte order mark")
    try:
        value = json.loads(data, parse_float=_reject_float, parse_int=_parse_int,
                           parse_constant=_reject_constant, object_pairs_hook=_pairs)
    except JCSError:
        raise
    except (ValueError, RecursionError) as error:
        raise JCSError(f"invalid JSON: {error}") from error
    check(value)
    return value


def check(value, depth=0):
    """Raise JCSError unless value is representable in the profile."""
    if depth > MAX_DEPTH:
        raise JCSError("nesting too deep")
    if value is None:
        raise JCSError("null is not allowed")
    if isinstance(value, bool):
        return
    if isinstance(value, int):
        if abs(value) > MAX_SAFE_INT:
            raise JCSError("integer out of range")
        return
    if isinstance(value, float):
        raise JCSError("floating-point number")
    if isinstance(value, str):
        _check_string(value)
        return
    if isinstance(value, list):
        for item in value:
            check(item, depth + 1)
        return
    if isinstance(value, dict):
        for key, item in value.items():
            if not isinstance(key, str) or not key.isascii():
                raise JCSError(f"member name must be ASCII: {key!r}")
            check(item, depth + 1)
        return
    raise JCSError(f"unsupported type {type(value).__name__}")


def _check_string(text):
    for char in text:
        if 0xD800 <= ord(char) <= 0xDFFF:
            raise JCSError("lone surrogate in string")


def _string(text):
    # json.dumps with ensure_ascii=False escapes exactly what JCS escapes: '"', '\\', \b \f \n \r \t,
    # and other C0 controls as lowercase \u00xx. Everything else, including '/' and U+007F, stays literal.
    return json.dumps(text, ensure_ascii=False)


def canonical(value):
    """The canonical UTF-8 bytes of value."""
    check(value)
    return _encode(value).encode("utf-8")


def _encode(value):
    if value is True:
        return "true"
    if value is False:
        return "false"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, str):
        return _string(value)
    if isinstance(value, list):
        return "[" + ",".join(_encode(item) for item in value) + "]"
    # ASCII names: UTF-16 code-unit order (RFC 8785 §3.2.3) equals byte order.
    items = sorted(value.items())
    return "{" + ",".join(_string(key) + ":" + _encode(item) for key, item in items) + "}"
