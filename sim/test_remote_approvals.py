"""Offline remote approval protocol + real SQLite. Synthetic keys, all outbound FAKE."""
import sim_isolation  # noqa: F401  Exits unless isolated (PID namespace / macOS signal guard); keep it the first import.
import base64
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest.mock import Mock, patch
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'Resources/Skills/swarmhub-messages/scripts'))
import swarm_remote as remote
import swarm_policy as policy
from swarm_store import canonical, database


class RemoteApprovalTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        env = patch.dict(os.environ, HOME=self.tmp.name)
        env.start(); self.addCleanup(env.stop)
        self.keys = {name: 'synthetic-' + name + '-key' for name in ('owner', 'worker', 'other')}
        for name, key in self.keys.items():
            root = Path(self.tmp.name) / '.hermes/profiles' / name
            root.mkdir(parents=True)
            (root / '.env').write_text('export API_SERVER_KEY="' + key + '"\n')
        policy.publish({'owner': 'owner', 'coordinator': 'owner'})
        self.wake = Mock()
        self.service = remote.ControlService('https://box.example.invalid', self.wake)
        self.task = self.submit('fixture')

    def submit(self, intent):
        # FAKE plus risk forces a real owner gate without enabling outbound execution.
        return policy.submit({'kind': 'outbound', 'bot': 'worker', 'intent': intent, 'fake': True,
                              'to': 'nobody@example.invalid', 'text': 'FAKE never sent', 'risks': ['money']})

    def request(self, verb='get', profile='owner', task=None, **changes):
        now = int(time.time())
        value = dict(version=1, origin=self.service.origin, profile=profile, verb=verb, task=task or self.task,
                     nonce=str(uuid.uuid4()), issued=now, expires=now + 60)
        if verb == 'decide':
            row = policy.action(value['task'])
            value.update(binding=dict(origin=self.service.origin, runtime=self.service.runtime, profile='owner'),
                         fingerprint=row['fingerprint'], gate=row['gate'], approved=True)
        value.update(changes)
        return value

    def send(self, value, service=None, key=None):
        raw = canonical(value).encode()
        key = key or self.keys[value['profile']]
        response = (service or self.service).handle(remote.PREFIX + value['profile'], 'Bearer ' + key,
                                                  remote.mac(key, 'request', raw), raw)
        payload = base64.b64decode(response['payload'])
        self.assertEqual(response['signature'], remote.mac(key, 'response', payload))
        decoded = json.loads(payload)
        self.assertEqual(decoded['request'], hashlib.sha256(raw).hexdigest())
        self.assertEqual(decoded['expires'], value['expires'])
        return decoded['record']

    def unchanged(self):
        self.assertEqual(policy.action(self.task)['status'], 'awaiting-owner')
        self.wake.assert_not_called()

    def test_authenticated_get_exact_spec_and_decider_can_approve(self):
        row = self.send(self.request(profile='worker'))
        self.assertEqual(row['spec'], json.loads(policy.action(self.task)['spec']))
        receipt = self.send(self.request('decide'))
        self.assertTrue(receipt['remoteReceipt']['approved'])
        self.assertEqual(receipt, self.send(self.request()))
        self.assertEqual(receipt['decided_by'], 'owner')
        self.assertTrue(receipt['spec']['fake'])

    def test_deny_final_and_descendants_cancel_atomically(self):
        child = policy.submit({'kind': 'read', 'bot': 'worker', 'intent': 'child',
                               'parent': self.task, 'argv': ['/bin/ls'], 'fake': True})
        receipt = self.send(self.request('decide', approved=False))
        self.assertFalse(receipt['remoteReceipt']['approved'])
        self.assertEqual(policy.action(child)['status'], 'cancelled')
        with self.assertRaises(ValueError):
            self.send(self.request('decide', approved=True))
        self.assertEqual(receipt, self.send(self.request('decide', approved=False)))
        self.wake.assert_not_called()

    def test_tamper_body_signature_key_and_duplicate_json_fail_closed(self):
        value = self.request('decide')
        raw = canonical(value).encode()
        key = self.keys['owner']
        for body, signature, auth in [
                (raw.replace(b'"approved":true', b'"approved":false'), remote.mac(key, 'request', raw), key),
                (raw, '0' * 64, key), (raw, remote.mac('bad', 'request', raw), 'bad')]:
            with self.assertRaises(ValueError):
                self.service.handle(remote.PREFIX + 'owner', 'Bearer ' + auth, signature, body)
        raw = raw[:-1] + b',"approved":false}'
        with self.assertRaises(ValueError):
            self.service.handle(remote.PREFIX + 'owner', 'Bearer ' + key, remote.mac(key, 'request', raw), raw)
        self.unchanged()

    def test_wrong_host_runtime_profile_digest_gate_and_operation_fail_closed(self):
        for changes in [dict(origin='https://wrong.example.invalid'), dict(profile='other'), dict(profile='worker'),
                        dict(fingerprint='0' * 64), dict(gate='coordinator'),
                        dict(binding=dict(origin=self.service.origin, runtime=str(uuid.uuid4()), profile='owner')),
                        dict(binding=dict(origin='https://wrong.example.invalid', runtime=self.service.runtime, profile='owner')),
                        dict(task='task.' + '0' * 32)]:
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                self.send(self.request('decide', **changes))
        other = remote.ControlService('https://other.example.invalid', self.wake)
        with self.assertRaises(ValueError):
            self.send(self.request('decide'), service=other)
        self.unchanged()

    def test_replay_is_idempotent_and_nonce_cannot_authorize_another_operation(self):
        value = self.request('decide')
        receipt = self.send(value)
        restarted = remote.ControlService(self.service.origin, self.wake)
        self.assertEqual(receipt, self.send(value, service=restarted))
        self.assertEqual(receipt, self.send(self.request('decide')))
        second = self.submit('other-operation')
        with self.assertRaises(ValueError):
            self.send(self.request('decide', task=second, nonce=value['nonce']))
        self.assertEqual(policy.action(second)['status'], 'awaiting-owner')
        with database() as db:
            self.assertEqual(db.execute('SELECT count(*) FROM approval_receipts').fetchone()[0], 1)

    def test_concurrent_duplicate_decisions_have_one_authoritative_receipt(self):
        requests = [self.request('decide') for _ in range(8)]
        with ThreadPoolExecutor(max_workers=8) as pool:
            receipts = list(pool.map(self.send, requests))
        self.assertTrue(all(row == receipts[0] for row in receipts))

    def test_timeout_after_commit_retries_query_first_and_never_redecides(self):
        self.wake.side_effect = TimeoutError('synthetic lost ACK')
        # fixes12: the decision committed, so the client gets its receipt, not an error (xrev2 finding 4).
        decided = self.send(self.request('decide'))
        self.assertTrue(decided['remoteReceipt']['approved'])
        self.wake.assert_called_once()
        self.wake.reset_mock()
        # App restarts; get reads the committed receipt without calling the worker.
        restarted = remote.ControlService(self.service.origin, self.wake)
        receipt = self.send(self.request(), service=restarted)
        self.assertTrue(receipt['remoteReceipt']['approved'])
        self.assertEqual(receipt, decided)
        self.wake.assert_not_called()

    def test_expired_future_and_expiry_during_database_wait_fail_closed(self):
        now = int(time.time())
        for changes in [dict(issued=now - 100, expires=now - 40), dict(expires=now + 600),
                        dict(issued=now + 30, expires=now + 60)]:
            with self.assertRaises(ValueError):
                self.send(self.request('decide', **changes))
        value = self.request('decide')
        with patch.object(remote.time, 'time', side_effect=[now, now + 61]), self.assertRaises(ValueError):
            self.send(value)
        self.unchanged()

    def test_corrupt_runtime_spec_and_changed_policy_refuse(self):
        value = self.request('decide')
        policy.publish({'owner': 'other'})
        with self.assertRaises(ValueError):
            self.send(value)
        policy.publish({'owner': 'owner'})
        with database() as db:
            spec = json.loads(policy.action(self.task)['spec'])
            spec['text'] = 'tampered'
            db.execute('UPDATE actions SET spec=? WHERE id=?', (canonical(spec), self.task))
        with self.assertRaises(ValueError):
            self.send(value)
        self.unchanged()

    def test_key_rotation_and_missing_key_fail_closed_without_copying_secret(self):
        root = Path(self.tmp.name) / '.hermes/profiles/owner/.env'
        root.write_text('API_SERVER_KEY=synthetic-rotated\n')
        with self.assertRaises(ValueError):
            self.send(self.request())
        self.send(self.request(), key='synthetic-rotated')
        root.unlink()
        with self.assertRaises(OSError):
            self.send(self.request())
        for path in (Path(self.tmp.name) / '.hermes/swarmhub').rglob('*'):
            if path.is_file():
                self.assertNotIn(b'synthetic-rotated', path.read_bytes())
        self.unchanged()

    def test_python_swift_shared_signature_fixture(self):
        fixture = json.loads((ROOT / 'Tests/Fixtures/remote_approval_protocol.json').read_text())
        raw = fixture['request'].encode()
        self.assertEqual(remote.mac(fixture['key'], 'request', raw), fixture['requestSignature'])
        payload = base64.b64decode(fixture['response']['payload'])
        self.assertEqual(remote.mac(fixture['key'], 'response', payload), fixture['response']['signature'])
        self.assertEqual(json.loads(payload)['request'], hashlib.sha256(raw).hexdigest())


if __name__ == '__main__':
    unittest.main()
