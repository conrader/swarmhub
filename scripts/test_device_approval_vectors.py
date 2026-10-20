"""P5a offline conformance: TEST signatures, deterministic regeneration and fail-closed checks."""

import copy
import hashlib
import hmac
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
from approvals import device_approval_reference as ref
from approvals import device_approval_vectors as vectors

DOCUMENT = ref.jcs.loads(vectors.FIXTURE.read_bytes())
KEYS = ref.jcs.loads(vectors.KEYS.read_bytes())
CASES = {c['id']: c for c in DOCUMENT['cases']}


def snapshot(case):
    state = copy.deepcopy(DOCUMENT['state'])
    state.update(copy.deepcopy(case['state_overrides']))
    return state


def run_case(test, case):
    state = snapshot(case)
    before = copy.deepcopy(state)
    raw = case['request'].encode()
    test.assertEqual(ref.evaluate(raw, state, case['now']), case['expect'])
    if case['expect']['verdict'] == 'accept':
        nonce = ref.jcs.loads(raw)['signed']['nonce']
        before['nonces'][nonce]['used'] = True
    test.assertEqual(state, before, 'only accepted decisions may consume a nonce')
    if 'signature_valid' in case:
        envelope = ref.jcs.loads(raw)
        body = envelope['signed']
        key = next(k for k in KEYS['keys'] if k['key_id'] == body['key_id'])
        test.assertEqual(ref.signature_valid(bytes.fromhex(key['ed25519_pub']), ref.signing_message(body),
                                             bytes.fromhex(envelope['signature'])), case['signature_valid'])
    else:
        key = next(k for k in KEYS['keys'] if k['key_id'] == case['v1_hmac_key_id'])
        mac = hmac.new(('TEST-v1-' + key['seed']).encode(), b'swarmhub-approval-v1:request\n' + raw,
                       hashlib.sha256).hexdigest()
        test.assertEqual(mac, case['v1_hmac'])


class DeviceVectorTests(unittest.TestCase):
    pass


# One real unittest method per vector, so runner counts include every protocol case.
for _case_id, _case in CASES.items():
    def _test(self, case=_case):
        run_case(self, case)
    setattr(DeviceVectorTests, 'test_' + _case_id.replace('-', '_'), _test)


class ProtocolTests(unittest.TestCase):
    def test_regeneration_is_byte_identical(self):
        self.assertEqual(vectors.FIXTURE.read_bytes(), vectors.encoded_document())
        self.assertEqual(vectors.KEYS.read_bytes(), ref.jcs.canonical(vectors.key_document()))
        self.assertEqual(vectors.encoded_document(), vectors.encoded_document())

    def test_keys_are_distinct_test_keys_from_fixed_seeds(self):
        release_keys = json.loads((ROOT / 'Tests/Fixtures/release-bundles/keys/TEST-keys.json').read_text())
        release_publics = {k['ed25519_pub'] for k in release_keys['keys']}
        self.assertEqual(len({k['ed25519_pub'] for k in KEYS['keys']}), 3)
        for key in KEYS['keys']:
            self.assertTrue(key['key_id'].startswith('TEST-'))
            self.assertNotIn(key['ed25519_pub'], release_publics)
            self.assertEqual(hashlib.sha256((KEYS['seed_label'] + key['key_id']).encode()).hexdigest(), key['seed'])
            self.assertEqual(vectors.ed25519_ref.public_key(bytes.fromhex(key['seed'])).hex(), key['ed25519_pub'])

    def test_all_bound_fields_have_individual_tamper_vectors(self):
        original = ref.jcs.loads(CASES['valid']['request'])
        self.assertEqual({c[len('tampered-'):] for c in CASES if c.startswith('tampered-')}, ref.FIELDS)
        for field in ref.FIELDS:
            case = CASES['tampered-' + field]
            altered = ref.jcs.loads(case['request'])
            self.assertEqual(altered['signature'], original['signature'])
            self.assertEqual([k for k in original['signed'] if original['signed'][k] != altered['signed'][k]], [field])
            self.assertEqual(case['expect']['verdict'], 'reject')

    def test_nonce_is_one_use_even_after_snapshot_restart(self):
        case = CASES['valid']
        state = snapshot(case)
        raw = case['request'].encode()
        self.assertEqual(ref.evaluate(raw, state, case['now']), case['expect'])
        restarted = ref.jcs.loads(ref.jcs.canonical(state))
        self.assertEqual(ref.evaluate(raw, restarted, case['now']),
                         {'verdict': 'reject', 'reason': 'nonce_replayed'})

    def test_invalid_attempt_does_not_burn_nonce(self):
        state = snapshot(CASES['valid'])
        self.assertEqual(ref.evaluate(CASES['tampered-approved']['request'].encode(), state, 1020)['verdict'], 'reject')
        self.assertEqual(ref.evaluate(CASES['valid']['request'].encode(), state, 1020)['verdict'], 'accept')

    def test_noncanonical_wire_is_verified_over_canonical_signed_body(self):
        case = CASES['valid']
        envelope = ref.jcs.loads(case['request'])
        envelope['signed'] = dict(reversed(list(envelope['signed'].items())))
        raw = json.dumps(envelope, indent=3).encode()
        self.assertNotEqual(raw, case['request'].encode())
        self.assertEqual(ref.evaluate(raw, snapshot(case), case['now']), case['expect'])

    def test_raw_json_and_schema_fail_closed(self):
        valid = ref.jcs.loads(CASES['valid']['request'])
        raw = CASES['valid']['request'].encode()
        bad = [b'', b'[]', b'null', b'\xff', b'\xef\xbb\xbf' + raw, raw + b'x',
               b'[' * 40 + b']' * 40, b' ' * (ref.LIMIT + 1),
               raw.replace(b'"version":2', b'"version":2,"version":2'),
               raw.replace(b'"issued":1000', b'"issued":1e3'),
               raw.replace(b'"issued":1000', b'"issued":-0'),
               raw.replace(b'"issued":1000', b'"issued":9007199254740992')]
        for field in ref.FIELDS:
            for value in (None, {}, [], '', True, 0, -1, 1.0):
                if value == valid['signed'][field] and type(value) is type(valid['signed'][field]):
                    continue
                doc = copy.deepcopy(valid)
                doc['signed'][field] = value
                bad.append(json.dumps(doc).encode())
            doc = copy.deepcopy(valid)
            del doc['signed'][field]
            bad.append(json.dumps(doc).encode())
        for doc in ({**valid, 'extra': 1}, {**valid, 'signature': 'A' * 128},
                    {**valid, 'signed': {**valid['signed'], 'extra': True}}):
            bad.append(json.dumps(doc).encode())
        for value in bad:
            with self.subTest(raw=value[:100]):
                state = snapshot(CASES['valid'])
                before = copy.deepcopy(state)
                self.assertEqual(ref.evaluate(value, state, 1020)['verdict'], 'reject')
                self.assertEqual(state, before)

    def test_corrupt_local_state_fails_closed(self):
        raw = CASES['valid']['request'].encode()
        original = snapshot(CASES['valid'])
        for key in original:
            for value in (None, {}, [], '', True, 1.0):
                if value == original[key] and type(value) is type(original[key]):
                    continue
                # Both booleans are legitimate modes; changing true to true is no corruption.
                state = copy.deepcopy(original)
                state[key] = value
                with self.subTest(key=key, value=value):
                    self.assertEqual(ref.evaluate(raw, state, 1020)['verdict'], 'reject')
        for key in original:
            state = copy.deepcopy(original)
            del state[key]
            self.assertEqual(ref.evaluate(raw, state, 1020)['verdict'], 'reject')

    def test_full_spec_fingerprint_covers_every_field_and_array_content(self):
        case = CASES['valid']
        original = DOCUMENT['state']['spec']
        self.assertIn('☃', ref.jcs.canonical(original).decode())
        for key in original:
            state = snapshot(case)
            del state['spec'][key]
            self.assertNotEqual(ref.fingerprint(state['spec']), DOCUMENT['state']['fingerprint'])
            state['fingerprint'] = ref.fingerprint(state['spec'])
            self.assertEqual(ref.evaluate(case['request'].encode(), state, 1020)['reason'], 'fingerprint_mismatch')
        state = snapshot(case)
        state['spec']['argv'].append('--changed')
        state['fingerprint'] = ref.fingerprint(state['spec'])
        self.assertEqual(ref.evaluate(case['request'].encode(), state, 1020)['reason'], 'fingerprint_mismatch')

    def test_bad_nonce_and_device_rows_fail_closed(self):
        original = snapshot(CASES['valid'])
        raw = CASES['valid']['request'].encode()
        nonce_id = next(iter(original['nonces']))
        nonce_row = original['nonces'][nonce_id]
        device_row = original['devices']['TEST-device-1']
        rows = [None, [], {}, {**nonce_row, 'used': 1},
                {**nonce_row, 'binding': {**nonce_row['binding'], 'issued': 1000.0}},
                {**nonce_row, 'binding': {**nonce_row['binding'], 'approved': False}}]
        for row in rows:
            state = copy.deepcopy(original)
            state['nonces'][nonce_id] = row
            self.assertEqual(ref.evaluate(raw, state, 1020), {'verdict': 'reject', 'reason': 'state_invalid'})
        for row in (None, [], {}, {**device_row, 'revoked': 0}, {**device_row, 'profiles': []}):
            state = copy.deepcopy(original)
            state['devices']['TEST-device-1'] = row
            self.assertEqual(ref.evaluate(raw, state, 1020), {'verdict': 'reject', 'reason': 'state_invalid'})

    def test_strict_ed25519_rejects_malleability_and_small_order_points(self):
        envelope = ref.jcs.loads(CASES['valid']['request'])
        public = bytes.fromhex(KEYS['keys'][0]['ed25519_pub'])
        message = ref.signing_message(envelope['signed'])
        sig = bytes.fromhex(envelope['signature'])
        self.assertTrue(ref.signature_valid(public, message, sig))
        high_s = sig[:32] + (int.from_bytes(sig[32:], 'little') + ref.ed25519.L).to_bytes(32, 'little')
        identity = b'\x01' + b'\x00' * 31
        noncanonical = (ref.ed25519.P + 1).to_bytes(32, 'little')
        for pub, signature in ((public, high_s), (identity, identity + b'\x00' * 32),
                               (public, identity + sig[32:]), (noncanonical, sig),
                               (public, noncanonical + sig[32:]), (public[:31], sig), (public, sig[:63])):
            self.assertFalse(ref.signature_valid(pub, message, signature))

    def test_origin_is_exact_and_never_normalized_from_untrusted_input(self):
        for origin in ('http://box.invalid', 'https://BOX.invalid', 'https://box.invalid/',
                       'https://box.invalid/v1', 'https://user@box.invalid', 'https://box.invalid:443',
                       'https://box.invalid?x', 'https://box.invalid#x', 'https://box.invalid\n',
                       'https://box.invalid:', 'https://box.invalid:0444', 'https://box.invalid:99999',
                       'https://box..invalid', 'https://box.-invalid', 'https://' + 'a' * 64 + '.invalid'):
            self.assertFalse(ref.canonical_origin(origin), origin)
        self.assertTrue(ref.canonical_origin('https://box.example.invalid:8443'))

    def test_v1_fixture_and_hermes_are_byte_unchanged(self):
        expected = {'remote_approval_protocol.json': '59ea2d070a66704564b1ba8918be0b98544962f797989f66d2ea1e1b84706088',
                    'hermes_v0.21.7_server.py': 'ee87681c782b6b5fb92392d8273764b061d655952f0e9a3711e346271b9fb858'}
        with tempfile.TemporaryDirectory() as temp:
            for name, digest in expected.items():
                source = ROOT / 'Tests/Fixtures' / name
                target = Path(temp) / name
                target.write_bytes(source.read_bytes())
                for case in DOCUMENT['cases']:
                    ref.evaluate(case['request'].encode(), snapshot(case), case['now'])
                self.assertEqual(hashlib.sha256(target.read_bytes()).hexdigest(), digest)
                self.assertEqual(source.read_bytes(), target.read_bytes())

    def test_reference_runs_without_site_packages_or_network(self):
        script = (f"import sys; sys.path.insert(0, {str(ROOT / 'scripts')!r})\n"
                  "def deny(event, args):\n"
                  "    if event.startswith('socket.'): raise AssertionError('network forbidden')\n"
                  "sys.addaudithook(deny)\n"
                  "from approvals import device_approval_vectors as v\n"
                  "from approvals import device_approval_reference as r\n"
                  "import copy\n"
                  "d = v.build()\n"
                  "for c in d['cases']:\n"
                  "    s = copy.deepcopy(d['state']); s.update(copy.deepcopy(c['state_overrides']))\n"
                  "    assert r.evaluate(c['request'].encode(), s, c['now']) == c['expect'], c['id']\n"
                  "assert not any('site-packages' in (getattr(m, '__file__', '') or '') for m in sys.modules.values())\n")
        result = subprocess.run([sys.executable, '-B', '-I', '-S', '-c', script], capture_output=True,
                                text=True, timeout=30, env={**os.environ, 'PYTHONDONTWRITEBYTECODE': '1'})
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_new_source_files_stay_under_500_lines(self):
        for path in [Path(__file__), *Path(ref.__file__).parent.glob('*.py')]:
            self.assertLessEqual(len(path.read_text().splitlines()), 500, str(path))


if __name__ == '__main__':
    unittest.main()
