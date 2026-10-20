#!/usr/bin/env python3
"""Regenerate/check offline P5a TEST vectors; never contacts a box or update host."""

import argparse
import copy
import hashlib
import hmac
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
sys.path.insert(0, str(ROOT / 'scripts/release'))
from approvals import device_approval_reference as ref
import ed25519_ref

FIXTURE = ROOT / 'Tests/Fixtures/device_approval_protocol.json'
KEYS = ROOT / 'Tests/Fixtures/release-bundles/TEST-device-keys.json'
KEY_IDS = ('TEST-device-1', 'TEST-device-2', 'TEST-device-unknown')
SEED_LABEL = 'swarmhub-device-approval-vectors/TEST-seed/'


def key_document():
    keys = []
    for key_id in KEY_IDS:
        seed = hashlib.sha256((SEED_LABEL + key_id).encode()).digest()
        keys.append({'key_id': key_id, 'seed': seed.hex(),
                     'ed25519_pub': ed25519_ref.public_key(seed).hex()})
    return {'note': 'Public TEST seeds only; separate from release/OpenClaw keys. Never trust these keys.',
            'seed_label': SEED_LABEL, 'keys': keys}


def build():
    keys = key_document()['keys']
    seeds = {k['key_id']: bytes.fromhex(k['seed']) for k in keys}
    spec = {'kind': 'outbound', 'bot': 'worker', 'intent': 'TEST full operation', 'fake': True,
            'argv': ['/bin/true', 'café'], 'risks': ['money'],
            'to': 'nobody@example.invalid', 'text': 'TEST never sent ☃'}
    body = {'version': 2, 'domain': ref.DOMAIN, 'key_id': KEY_IDS[0],
            'origin': 'https://box.example.invalid', 'runtime': 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
            'profile': 'owner', 'task': 'task.' + 'a' * 32, 'fingerprint': ref.fingerprint(spec),
            'gate': 'owner', 'approved': True, 'nonce': '11' * 32, 'issued': 1000, 'expires': 1060}
    state = {'device_required': True, **{k: body[k] for k in
             ('origin', 'runtime', 'profile', 'task', 'fingerprint', 'gate')},
             'spec': spec, 'status': 'awaiting-owner',
             'devices': {k['key_id']: {'ed25519_pub': k['ed25519_pub'], 'profiles': ['owner'],
                                      'revoked': False} for k in keys[:2]},
             'nonces': {body['nonce']: {'binding': {k: body[k] for k in sorted(ref.NONCE_FIELDS)}, 'used': False}}}

    def sign(value, signer=KEY_IDS[0], context=ref.CONTEXT):
        return {'signed': copy.deepcopy(value), 'signature': ed25519_ref.sign(
            seeds[signer], context + ref.jcs.canonical(value)).hex()}

    valid = sign(body)
    cases = []

    def add(case_id, reason, envelope=None, overrides=None, now=1020, signature_valid=True):
        case = {'id': case_id, 'request': ref.jcs.canonical(valid if envelope is None else envelope).decode(),
                'state_overrides': overrides or {}, 'now': now,
                'expect': {'verdict': 'accept' if reason == 'ok' else 'reject', 'reason': reason},
                'signature_valid': signature_valid}
        cases.append(case)

    add('valid', 'ok')
    add('valid-deny', 'ok', sign({**body, 'approved': False}))
    add('valid-before-expiry', 'ok', now=1059)
    add('valid-at-issue', 'ok', now=1000)
    add('valid-before-cutover', 'ok', overrides={'device_required': False})
    changes = {'version': 3, 'domain': 'swarmhub/device-approval/3', 'key_id': KEY_IDS[1],
               'origin': 'https://other.example.invalid', 'runtime': 'bbbbbbbb-bbbb-cccc-dddd-eeeeeeeeeeee',
               'profile': 'other', 'task': 'task.' + 'b' * 32, 'fingerprint': '00' * 32,
               'gate': 'coordinator', 'approved': False, 'nonce': '22' * 32, 'issued': 1001, 'expires': 1059}
    for field, value in changes.items():
        tampered = copy.deepcopy(valid)
        tampered['signed'][field] = value
        reason = 'protocol_unsupported' if field in ('version', 'domain') else 'signature_invalid'
        add('tampered-' + field, reason, tampered, signature_valid=False)
    for case_id, field, value, reason in (
            ('wrong-box-origin', 'origin', 'https://other.example.invalid', 'box_mismatch'),
            ('wrong-box-runtime', 'runtime', 'bbbbbbbb-bbbb-cccc-dddd-eeeeeeeeeeee', 'box_mismatch'),
            ('wrong-profile', 'profile', 'other', 'profile_mismatch'),
            ('wrong-task', 'task', 'task.' + 'b' * 32, 'task_mismatch'),
            ('wrong-fingerprint', 'fingerprint', '00' * 32, 'fingerprint_mismatch'),
            ('wrong-gate', 'gate', 'coordinator', 'gate_mismatch')):
        add(case_id, reason, sign({**body, field: value}))
    nonces = copy.deepcopy(state['nonces'])
    nonces[body['nonce']]['used'] = True
    add('replayed-nonce', 'nonce_replayed', overrides={'nonces': nonces})
    add('expired-nonce', 'nonce_expired', now=1061)
    add('expiry-boundary', 'nonce_expired', now=1060)
    add('future-nonce', 'nonce_not_yet_valid', now=999)
    add('unknown-nonce', 'nonce_unknown', sign({**body, 'nonce': '22' * 32}))
    add('nonce-binding-mismatch', 'nonce_mismatch', sign({**body, 'issued': 1001}))
    for case_id, change, reason in (
            ('revoked-device', {'revoked': True}, 'device_revoked'),
            ('device-wrong-profile', {'profiles': ['other']}, 'device_unauthorized')):
        devices = copy.deepcopy(state['devices'])
        devices[KEY_IDS[0]].update(change)
        add(case_id, reason, overrides={'devices': devices})
    add('unknown-device', 'device_unknown', sign({**body, 'key_id': KEY_IDS[2]}, KEY_IDS[2]))
    add('wrong-signing-key', 'signature_invalid', sign(body, KEY_IDS[1]), signature_valid=False)
    add('wrong-signature-domain', 'signature_invalid', sign(body, context=b'swarmhub-signature/1\n'),
        signature_valid=False)
    add('unsupported-version', 'protocol_unsupported', sign({**body, 'version': 3}))
    add('operation-final', 'operation_not_pending', overrides={'status': 'queued'})
    changed_spec = copy.deepcopy(spec)
    changed_spec['text'] += ' changed'
    add('operation-corrupt', 'state_invalid', overrides={'spec': changed_spec})
    v1 = {'version': 1, 'origin': body['origin'], 'profile': body['profile'], 'verb': 'decide',
          'task': body['task'], 'nonce': '11111111-2222-3333-4444-555555555555',
          'issued': 1000, 'expires': 1060, 'binding': {k: body[k] for k in ('origin', 'runtime', 'profile')},
          'fingerprint': hashlib.sha256(json.dumps(spec, sort_keys=True, separators=(',', ':')).encode()).hexdigest(),
          'gate': 'owner', 'approved': True}
    for case_id, required in (('v1-device-required', True), ('v1-before-cutover', False)):
        add(case_id, 'device_required', v1, overrides={'device_required': required})
        cases[-1].pop('signature_valid')
        cases[-1]['v1_hmac_key_id'] = KEY_IDS[0]
        # v1 keys are UTF-8 strings; derive this separate synthetic transport key in memory only.
        transport_key = ('TEST-v1-' + seeds[KEY_IDS[0]].hex()).encode()
        cases[-1]['v1_hmac'] = hmac.new(transport_key, b'swarmhub-approval-v1:request\n' +
                                      cases[-1]['request'].encode(), hashlib.sha256).hexdigest()
        if not required:
            cases[-1]['expect'] = {'verdict': 'defer', 'reason': 'legacy_v1'}
    return {'schema': 'swarmhub/device-approval-vectors/2',
            'note': 'Offline reference only. Each case starts from state plus shallow state_overrides.',
            'test_keys': 'release-bundles/TEST-device-keys.json', 'state': state, 'cases': cases}


def encoded_document():
    return (json.dumps(build(), indent=2, sort_keys=True, ensure_ascii=False) + '\n').encode()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args(argv)
    files = ((FIXTURE, encoded_document()), (KEYS, ref.jcs.canonical(key_document())))
    if args.check:
        changed = [str(p.relative_to(ROOT)) for p, data in files if not p.exists() or p.read_bytes() != data]
        print('device vectors: ' + (', '.join(changed) if changed else 'byte-identical'))
        return int(bool(changed))
    for path, data in files:
        path.write_bytes(data)
    print(f'wrote {len(build()["cases"])} TEST device-approval vectors')
    return 0


if __name__ == '__main__':
    sys.exit(main())
