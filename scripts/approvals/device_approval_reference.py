"""P5a offline reference only: no transport, disk writes, runtime imports or enrollment.

Caller supplies a trusted snapshot; evaluate consumes a nonce in that in-memory
snapshot only on accept. P5b must put all checks and receipt writes in one DB transaction.
"""

import hashlib
from pathlib import Path
import re
import sys
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'Resources/Updater'))
from swarmhub_update import ed25519, jcs

DOMAIN = 'swarmhub/device-approval/2'
CONTEXT = b'swarmhub-device-approval/2\n'
LIMIT = 16384
TTL = 60
FIELDS = {'version', 'domain', 'key_id', 'origin', 'runtime', 'profile', 'task',
          'fingerprint', 'gate', 'approved', 'nonce', 'issued', 'expires'}
NONCE_FIELDS = FIELDS - {'approved'}
NAME = r'[A-Za-z0-9_-]{1,64}'
KEY_ID = r'[A-Za-z0-9._-]{1,64}'
UUID = r'[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}'


class Refusal(ValueError):
    pass


def require(ok, reason):
    if not ok:
        raise Refusal(reason)


def matches(value, pattern):
    return isinstance(value, str) and re.fullmatch(pattern, value) is not None


def integer(value):
    return type(value) is int and 0 <= value <= jcs.MAX_SAFE_INT


def canonical_origin(value):
    """Operator-configured lowercase HTTPS authority, no path/credentials/default port."""
    if not isinstance(value, str) or not value.isascii() or any(c.isspace() for c in value):
        return False
    try:
        parts = urlsplit(value)
        return (parts.scheme == 'https' and bool(parts.hostname) and not parts.username
                and not parts.password and not parts.path and not parts.query and not parts.fragment
                and value == 'https://' + parts.netloc and parts.netloc == parts.netloc.lower()
                and len(parts.hostname) <= 253
                and all(matches(label, r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?')
                        for label in parts.hostname.split('.'))
                and (parts.port is None or 1 <= parts.port <= 65535 and parts.port != 443)
                and parts.netloc == parts.hostname + (':' + str(parts.port) if parts.port else ''))
    except ValueError:
        return False


def signing_message(signed):
    return CONTEXT + jcs.canonical(signed)


def fingerprint(spec):
    require(isinstance(spec, dict), 'state_invalid')
    return hashlib.sha256(jcs.canonical(spec)).hexdigest()


def prime_point(encoded):
    point = ed25519.decode_point(encoded)
    return (point is not None and not ed25519._equal(point, ed25519.IDENTITY)
            and ed25519._equal(ed25519._mul(ed25519.L, point), ed25519.IDENTITY))


def signature_valid(public, message, signature):
    return (prime_point(public) and prime_point(signature[:32])
            and ed25519.verify(public, message, signature))


def check_shape(body):
    require(isinstance(body, dict) and set(body) == FIELDS, 'schema_invalid')
    require(type(body['version']) is int and isinstance(body['domain'], str), 'schema_invalid')
    require(matches(body['key_id'], KEY_ID) and canonical_origin(body['origin'])
            and matches(body['runtime'], UUID) and matches(body['profile'], NAME)
            and matches(body['task'], r'task\.[a-f0-9]{32}')
            and matches(body['fingerprint'], r'[a-f0-9]{64}')
            and body['gate'] in ('owner', 'coordinator')
            and type(body['approved']) is bool and matches(body['nonce'], r'[a-f0-9]{64}')
            and integer(body['issued']) and integer(body['expires'])
            and 0 < body['expires'] - body['issued'] <= TTL, 'schema_invalid')


def check_state(state, now):
    require(isinstance(state, dict) and integer(now), 'state_invalid')
    jcs.check(state)
    require(type(state['device_required']) is bool and canonical_origin(state['origin'])
            and matches(state['runtime'], UUID) and matches(state['profile'], NAME)
            and matches(state['task'], r'task\.[a-f0-9]{32}')
            and state['gate'] in ('owner', 'coordinator')
            and isinstance(state['status'], str)
            and isinstance(state['devices'], dict) and isinstance(state['nonces'], dict), 'state_invalid')
    require(fingerprint(state['spec']) == state['fingerprint'], 'state_invalid')
    for key_id, device in state['devices'].items():
        require(matches(key_id, KEY_ID) and isinstance(device, dict)
                and type(device['revoked']) is bool and isinstance(device['profiles'], list)
                and bool(device['profiles']) and all(matches(p, NAME) for p in device['profiles'])
                and matches(device['ed25519_pub'], r'[a-f0-9]{64}'), 'state_invalid')
    for nonce_id, nonce in state['nonces'].items():
        require(isinstance(nonce, dict) and set(nonce) == {'binding', 'used'}
                and type(nonce['used']) is bool and isinstance(nonce['binding'], dict)
                and set(nonce['binding']) == NONCE_FIELDS, 'state_invalid')
        check_shape({**nonce['binding'], 'approved': False})
        require(nonce_id == nonce['binding']['nonce'] and nonce['binding']['version'] == 2
                and nonce['binding']['domain'] == DOMAIN, 'state_invalid')


def evaluate(raw, state, now):
    """Return {verdict, reason}; never accept malformed input or silently delegate v2 to v1.

    `defer/legacy_v1` is dispatch advice, NOT approval; the existing v1 verifier
    must authenticate it. All other failures reject, leaving the snapshot untouched.
    """
    try:
        check_state(state, now)
    except (Refusal, ValueError, TypeError, KeyError, AttributeError, RecursionError):
        return {'verdict': 'reject', 'reason': 'state_invalid'}
    try:
        require(isinstance(raw, bytes) and 0 < len(raw) <= LIMIT, 'schema_invalid')
        doc = jcs.loads(raw)
        require(isinstance(doc, dict), 'schema_invalid')
        if type(doc.get('version')) is int and doc['version'] == 1:
            require(not state['device_required'], 'device_required')
            return {'verdict': 'defer', 'reason': 'legacy_v1'}
        require(set(doc) == {'signed', 'signature'}, 'schema_invalid')
        body = doc['signed']
        check_shape(body)
        require(body['version'] == 2 and body['domain'] == DOMAIN, 'protocol_unsupported')
        require(matches(doc['signature'], r'[a-f0-9]{128}'), 'schema_invalid')
        device = state['devices'].get(body['key_id'])
        require(device is not None, 'device_unknown')
        require(not device['revoked'], 'device_revoked')
        require(signature_valid(bytes.fromhex(device['ed25519_pub']), signing_message(body),
                                bytes.fromhex(doc['signature'])), 'signature_invalid')
        require(body['origin'] == state['origin'] and body['runtime'] == state['runtime'], 'box_mismatch')
        require(body['profile'] == state['profile'], 'profile_mismatch')
        require(body['profile'] in device['profiles'], 'device_unauthorized')
        require(body['task'] == state['task'], 'task_mismatch')
        require(body['fingerprint'] == state['fingerprint'], 'fingerprint_mismatch')
        require(body['gate'] == state['gate'], 'gate_mismatch')
        require(state['status'] == 'awaiting-' + state['gate'], 'operation_not_pending')
        nonce = state['nonces'].get(body['nonce'])
        require(nonce is not None, 'nonce_unknown')
        require(nonce['binding'] == {k: body[k] for k in NONCE_FIELDS}, 'nonce_mismatch')
        require(not nonce['used'], 'nonce_replayed')
        require(body['issued'] <= now, 'nonce_not_yet_valid')
        require(now < body['expires'], 'nonce_expired')
        nonce['used'] = True
        return {'verdict': 'accept', 'reason': 'ok'}
    except Refusal as error:
        return {'verdict': 'reject', 'reason': str(error)}
    except (ValueError, TypeError, KeyError, AttributeError, RecursionError, OverflowError):
        return {'verdict': 'reject', 'reason': 'schema_invalid'}
