"""Offline P5c cross-check of the stored Mac signature fixture against P5a and the P5b verifier.

CryptoKit signatures may be randomized. Compare canonical payload/message bytes, verify signatures,
and never regenerate expected signatures. Only --write-candidate signs public TEST seeds on Linux;
SWARMHUB_WRITE_DEVICE_FIXTURE=1 swift test replaces that candidate with Mac-produced signatures.
No production keys, real boxes, sockets, Hermes writes, or changes to P5a/v1 fixtures.
"""
import copy
import hashlib
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'sim'))
from device_approval_harness import Box, DOCUMENT, KEYS, clock, ds, policy, remote  # noqa: E402
import ed25519_ref  # noqa: E402

FIXTURE = ROOT / 'Tests/Fixtures/release-bundles/TEST-mac-device-signatures.json'
CASES = [c for c in DOCUMENT['cases'] if 'signature_valid' in c]


def fixture_document():
    """Bootstrap only: the Mac writer uses the identical shape, with its own valid signatures."""
    cases = []
    for case in CASES:
        body = ds.jcs.loads(case['request'])['signed']
        message = ds.CONTEXT + ds.jcs.canonical(body)
        signature = ed25519_ref.sign(bytes.fromhex(KEYS[body['key_id']]['seed']), message).hex()
        cases.append({'id': case['id'], 'key_id': body['key_id'],
                      'public_key': KEYS[body['key_id']]['ed25519_pub'],
                      'canonical': ds.jcs.canonical(body).decode(), 'message': message.decode(),
                      'signature': signature,
                      'envelope': ds.jcs.canonical({'signed': body, 'signature': signature}).decode()})
    return {'schema': 'swarmhub/mac-device-signatures/2', 'cases': cases}


def check_entry(entry, case):
    """Validate stored bytes, including both signatures, without constructing a new signature."""
    body = ds.jcs.loads(case['request'])['signed']
    assert set(entry) == {'id', 'key_id', 'public_key', 'canonical', 'message', 'signature', 'envelope'}
    assert entry['id'] == case['id'] and entry['key_id'] == body['key_id']
    assert entry['public_key'] == KEYS[body['key_id']]['ed25519_pub']
    canonical = ds.jcs.canonical(body)
    message = ds.CONTEXT + canonical
    assert entry['canonical'].encode() == canonical
    assert entry['message'].encode() == message
    public = bytes.fromhex(entry['public_key'])
    assert ds.ed25519.verify(public, message, bytes.fromhex(entry['signature']))
    envelope = ds.jcs.loads(entry['envelope'])
    assert set(envelope) == {'signed', 'signature'} and envelope['signed'] == body
    assert ds.ed25519.verify(public, message, bytes.fromhex(envelope['signature']))


def alternate_test_signature(entry):
    """An alternate Ed25519 nonce, using only public TEST seed material (never production)."""
    seed = bytes.fromhex(KEYS[entry['key_id']]['seed'])
    scalar, prefix = ed25519_ref._expand(seed)
    message, public = entry['message'].encode(), bytes.fromhex(entry['public_key'])
    nonce = ed25519_ref._sha512_int(b'TEST-alternate-nonce\n' + prefix + message) % ed25519_ref.L
    encoded = ed25519_ref._compress(ed25519_ref._mul(nonce, ed25519_ref.G))
    challenge = ed25519_ref._sha512_int(encoded + public + message) % ed25519_ref.L
    return (encoded + ((nonce + challenge * scalar) % ed25519_ref.L).to_bytes(32, 'little')).hex()


class MacSignatureTests(unittest.TestCase):
    def test_all_applicable_p5a_payloads_are_present(self):
        fixture = ds.jcs.loads(FIXTURE.read_bytes())
        self.assertEqual(set(fixture), {'schema', 'cases'})
        self.assertEqual(fixture['schema'], 'swarmhub/mac-device-signatures/2')
        self.assertEqual(len(fixture['cases']), 38)
        self.assertEqual([c['id'] for c in fixture['cases']], [c['id'] for c in CASES])

    def test_alternate_valid_signature_survives_plain_fixture_check(self):
        entry = copy.deepcopy(ds.jcs.loads(FIXTURE.read_bytes())['cases'][0])
        entry['signature'] = alternate_test_signature(entry)
        envelope = ds.jcs.loads(entry['envelope'])
        envelope['signature'] = entry['signature']
        entry['envelope'] = ds.jcs.canonical(envelope).decode()
        # Serialize/reload just like a Mac fixture write followed by a plain test run.
        check_entry(ds.jcs.loads(ds.jcs.canonical(entry)), CASES[0])

    def test_fixture_drift_and_invalid_signatures_are_rejected(self):
        original = ds.jcs.loads(FIXTURE.read_bytes())['cases'][0]
        for field, value in [('canonical', '{}'), ('message', 'wrong domain'), ('public_key', '00' * 32),
                             ('signature', '00' * 64), ('envelope', '{}'), ('key_id', 'TEST-other')]:
            entry = {**original, field: value}
            with self.subTest(field=field), self.assertRaises(AssertionError):
                check_entry(entry, CASES[0])

    def test_original_protocol_fixtures_are_unchanged(self):
        # Baseline 54d26f8 hashes; no Git operation (or possible promisor fetch) in this offline check.
        expected = {
            'device_approval_protocol.json': '1bfe7669db05f64785819cacaa97c1c932a66eca0cb0e1c5a1f3b34a547da303',
            'remote_approval_protocol.json': '59ea2d070a66704564b1ba8918be0b98544962f797989f66d2ea1e1b84706088',
        }
        for name, digest in expected.items():
            self.assertEqual(hashlib.sha256((ROOT / 'Tests/Fixtures' / name).read_bytes()).hexdigest(), digest)


# Verify the stored fixture itself, never signatures regenerated by a Python signer.
for _case in CASES:
    def _test(self, case=_case):
        entries = ds.jcs.loads(FIXTURE.read_bytes())['cases']
        entry = next(c for c in entries if c['id'] == case['id'])
        check_entry(entry, case)
    setattr(MacSignatureTests, 'test_signature_' + _case['id'].replace('-', '_'), _test)


class MacBoxVerifierTests(Box):
    def test_pending_reads_return_full_bound_record_without_nonce_writes(self):
        self.enroll()
        task, service = self.submit(), self.service()
        before = self.box_rows()
        for _ in range(12):
            status, result = self.receipt(service, task)
            self.assertEqual((status, result['receipt'], result['status']), (200, None, 'awaiting-owner'))
            record = result['record']
            self.assertEqual((record['id'], record['decider'], record['gate']), (task, 'owner', 'owner'))
            self.assertEqual(record['spec']['text'], 'FAKE never sent ☃ fixture')
            self.assertEqual(record['remoteBinding'], {'origin': service.origin, 'runtime': service.runtime,
                                                       'profile': 'owner'})
            self.assertEqual(self.box_rows(), before)
        self.assertIsNotNone(self.challenge(service, task))

    def test_expired_nonce_pending_read_uses_box_time_and_cannot_commit(self):
        self.enroll()
        task, service = self.submit(), self.service()
        binding = self.challenge(service, task)
        before = self.box_rows()
        for observed in (binding['expires'] - 1, binding['expires'], binding['expires'] + 1):
            with clock(observed):
                status, result = self.receipt(service, task)
            self.assertEqual((status, result['receipt'], result['status'], result['observed_at']),
                             (200, None, 'awaiting-owner', observed))
            self.assertIsNone(result['record']['decided_at'])
            self.assertIsNone(result['record']['decided_by'])
            # Only the expiry mark is written, and only once box time reached `expires`.
            marked = [(binding['nonce'],)] if observed >= binding['expires'] else []
            self.assertEqual(self.box_rows(), {**before, 'approval_expired': marked})
        before = self.box_rows()
        with clock(binding['expires']):
            status, result = self.post(service, 'decide', self.decision(binding))
        self.assertEqual((status, result['reason']), (403, 'nonce_expired'))
        self.assertEqual(self.box_rows(), before)
        self.wake.assert_not_called()

    def test_box_clock_stepping_back_after_expired_read_cannot_commit(self):
        self.enroll()
        task, service = self.submit(), self.service()
        start = int(ds.time.time())
        with clock(start):
            binding = self.challenge(service, task)
        with clock(binding['expires']):
            status, result = self.receipt(service, task)
        self.assertEqual((status, result['observed_at']), (200, binding['expires']))
        before = self.box_rows()
        self.assertEqual(before['approval_expired'], [(binding['nonce'],)])
        # The box clock steps back below `expires`; a restarted service still refuses that nonce.
        for now in (binding['expires'] - 1, start + 1):
            with self.subTest(now=now), clock(now):
                status, result = self.post(self.service(), 'decide', self.decision(binding, approved=False))
            self.assertEqual((status, result['reason']), (403, 'nonce_expired'))
            self.assertEqual(self.box_rows(), before)
        self.assertEqual(policy.action(task)['status'], 'awaiting-owner')
        self.wake.assert_not_called()
        # A fresh nonce, issued later and never seen expired, still decides; the mark is per nonce.
        with clock(binding['expires'] - 1):
            fresh = self.challenge(service, task)
            status, result = self.post(service, 'decide', self.decision(fresh, approved=False))
        self.assertEqual((status, result['receipt']['status']), (200, 'denied'))
        self.assertEqual(self.box_rows()['approval_expired'], [(binding['nonce'],)])

    def test_expiry_marks_are_pruned_with_their_challenges(self):
        self.enroll()
        task, service = self.submit(), self.service()
        start = int(ds.time.time())
        with clock(start):
            binding = self.challenge(service, task)
        with clock(binding['expires']):
            self.receipt(service, task)
        with clock(binding['expires'] + ds.TTL):  # Old challenge rows (and their marks) may now be pruned.
            self.challenge(service, task)
        rows = self.box_rows()
        self.assertNotIn(binding['nonce'], [r[0] for r in rows['approval_challenges']])
        self.assertEqual(rows['approval_expired'], [])

    def test_refused_signature_can_retry_with_fresh_nonce_and_deny(self):
        self.enroll()
        task, service = self.submit(), self.service()
        binding = self.challenge(service, task)
        envelope = ds.jcs.loads(self.decision(binding))
        envelope['signature'] = '00' * 64
        before = self.box_rows()
        status, result = self.post(service, 'decide', ds.jcs.canonical(envelope))
        self.assertEqual((status, result['reason']), (403, 'signature_invalid'))
        self.assertEqual(self.box_rows(), before)
        self.assertEqual(self.receipt(service, task)[1]['receipt'], None)
        fresh = self.challenge(service, task)
        self.assertNotEqual(fresh['nonce'], binding['nonce'])
        status, result = self.post(service, 'decide', self.decision(fresh, approved=False))
        self.assertEqual((status, result['receipt']['status']), (200, 'denied'))
        self.wake.assert_not_called()

    def test_mac_valid_payload_through_real_p5b_http_boundary_and_receipt(self):
        case = next(c for c in CASES if c['id'] == 'valid')
        self.load_vector_state(case)
        entry = next(c for c in ds.jcs.loads(FIXTURE.read_bytes())['cases'] if c['id'] == 'valid')
        with clock(case['now']):
            status, result = self.service().handle_v2(remote.PREFIX_V2 + 'owner/decide', entry['envelope'].encode())
        self.assertEqual(status, 200, result)
        receipt = result['receipt']['remoteReceipt']
        self.assertEqual(receipt['protocol'], 2)
        self.assertEqual(receipt['message'], hashlib.sha256(entry['message'].encode()).hexdigest())
        self.assertEqual(receipt['device'], entry['key_id'])
        self.assertEqual(receipt['nonce'], next(iter(DOCUMENT['state']['nonces'])))
        self.wake.assert_called_once()

    def test_alternate_signature_passes_real_p5b_verifier(self):
        case = next(c for c in CASES if c['id'] == 'valid')
        self.load_vector_state(case)
        entry = next(c for c in ds.jcs.loads(FIXTURE.read_bytes())['cases'] if c['id'] == 'valid')
        envelope = ds.jcs.loads(entry['envelope'])
        envelope['signature'] = alternate_test_signature(entry)
        with clock(case['now']):
            status, result = self.service().handle_v2(remote.PREFIX_V2 + 'owner/decide', ds.jcs.canonical(envelope))
        self.assertEqual(status, 200, result)
        self.wake.assert_called_once()

    def test_mac_signature_rejects_tamper_without_consuming_nonce(self):
        case = next(c for c in CASES if c['id'] == 'valid')
        self.load_vector_state(case)
        entry = next(c for c in ds.jcs.loads(FIXTURE.read_bytes())['cases'] if c['id'] == 'valid')
        body = ds.jcs.loads(entry['envelope'])
        body['signed']['approved'] = False
        before = self.box_rows()
        with clock(case['now']):
            status, result = self.service().handle_v2(remote.PREFIX_V2 + 'owner/decide', ds.jcs.canonical(body))
        self.assertEqual((status, result['reason']), (403, 'signature_invalid'))
        self.assertEqual(self.box_rows(), before)
        self.wake.assert_not_called()


if __name__ == '__main__':
    if sys.argv[1:] == ['--write-candidate']:
        FIXTURE.write_bytes(ds.jcs.canonical(fixture_document()))
    else:
        unittest.main()
