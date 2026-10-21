"""P5b: every P5a vector through the real box verifier, plus replay, crash, concurrency, revoke, cutover.

Real SQLite in a temp HOME, public TEST keys only, all outbound FAKE, no network (loopback once).
"""
import sim_isolation  # noqa: F401  Exits unless isolated (PID namespace / macOS signal guard); keep it the first import.
import base64
from concurrent.futures import ThreadPoolExecutor
import hashlib
import http.client
import json
import os
from pathlib import Path
import subprocess
import sys
import threading
from unittest.mock import patch
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from device_approval_harness import (DEVICE, DOCUMENT, KEYS, ORIGIN, ROOT, SCRIPTS, Box, clock,  # noqa: E402
                                     devices, ds, policy, remote, sign)
import swarm_device_approvals as approvals  # noqa: E402
from swarm_store import database  # noqa: E402


class VectorTests(Box):
    def run_vector(self, case):
        state = self.load_vector_state(case)
        service = self.service()
        raw = case['request'].encode()
        before = self.box_rows()
        with clock(case['now']):
            verdict, receipt = service.devices.decide(state['profile'], raw)
        self.assertEqual(verdict, case['expect'])
        if verdict['verdict'] != 'accept':
            self.assertEqual(self.box_rows(), before, 'a rejection consumes and decides nothing')
            self.wake.assert_not_called()
            self.assertIsNone(receipt)
        else:
            body = ds.jcs.loads(raw)['signed']
            row = policy.action(state['task'])
            self.assertEqual(row['status'], 'queued' if body['approved'] else 'denied')
            self.assertEqual(self.wake.called, body['approved'])
            self.assertEqual(receipt['remoteReceipt'], {
                'id': receipt['remoteReceipt']['id'], 'approved': body['approved'], 'protocol': 2,
                'device': body['key_id'], 'nonce': body['nonce'], 'fingerprint': state['fingerprint'],
                'message': hashlib.sha256(ds.CONTEXT + ds.jcs.canonical(body)).hexdigest()})
            self.assertEqual(receipt['remoteBinding'], {'origin': ORIGIN, 'runtime': state['runtime'],
                                                        'profile': 'owner'})
            with database() as db:
                self.assertEqual(db.execute('SELECT used FROM approval_challenges WHERE nonce=?',
                                            (body['nonce'],)).fetchone()[0], 1)
            with clock(case['now']):  # An identical retransmission always rejects.
                self.assertEqual(service.devices.decide('owner', raw)[0]['verdict'], 'reject')
        if 'v1_hmac' in case:
            self.run_v1(case, state, service, raw)

    def run_v1(self, case, state, service, raw):
        if state['device_required']:
            with patch.object(remote, 'profile_key', side_effect=AssertionError('v1 authentication ran')):
                with self.assertRaisesRegex(ValueError, 'device_required'):
                    service.handle(remote.PREFIX + 'owner', 'Bearer x', case['v1_hmac'], raw)
            self.assertEqual(policy.action(state['task'])['status'], 'awaiting-owner')
            return
        # defer/legacy_v1: the unchanged v1 verifier authenticates it with the synthetic transport key.
        key = 'TEST-v1-' + KEYS[case['v1_hmac_key_id']]['seed']
        (Path(self.tmp.name) / '.hermes/profiles/owner/.env').write_text('API_SERVER_KEY=' + key + '\n')
        with patch.object(remote.time, 'time', return_value=case['now']):
            response = service.handle(remote.PREFIX + 'owner', 'Bearer ' + key, case['v1_hmac'], raw)
        record = json.loads(base64.b64decode(response['payload']))['record']
        self.assertEqual(record['status'], 'queued')


for _case in DOCUMENT['cases']:
    def _test(self, case=_case):
        self.run_vector(case)
    setattr(VectorTests, 'test_vector_' + _case['id'].replace('-', '_'), _test)


class FlowTests(Box):
    def setUp(self):
        super().setUp()
        self.enroll()
        self.task = self.submit()

    def test_challenge_decide_receipt_end_to_end(self):
        service = self.service()
        binding = self.challenge(service, self.task)
        spec = json.loads(policy.action(self.task)['spec'])
        self.assertEqual(binding['fingerprint'], hashlib.sha256(ds.jcs.canonical(spec)).hexdigest())
        self.assertEqual((binding['runtime'], binding['gate'], binding['expires'] - binding['issued']),
                         (service.runtime, 'owner', 60))
        status, result = self.post(service, 'decide', self.decision(binding))
        self.assertEqual(status, 200, result)
        receipt = result['receipt']
        self.assertEqual((receipt['status'], receipt['decided_by'], receipt['remoteReceipt']['device']),
                         ('queued', 'owner', DEVICE))
        self.wake.assert_called_once()
        status, read = self.receipt(service, self.task)
        self.assertEqual((status, read['receipt']), (200, receipt))
        v1 = json.loads(base64.b64decode(self.v1(service, 'get', self.task)['payload']))['record']
        self.assertEqual(v1, receipt, 'legacy v1 reads the same committed receipt')

    def test_nonce_replay_rejected_across_restart_and_challenges_survive_restart(self):
        first = self.service()
        binding = self.challenge(first, self.task)
        raw = self.decision(binding, approved=False)
        restarted = self.service()
        status, result = self.post(restarted, 'decide', raw)
        self.assertEqual(status, 200, result)
        for service in (first, self.service()):
            self.assertEqual(self.post(service, 'decide', raw)[1].get('reason'), 'operation_not_pending')
        self.assertEqual(self.receipt(self.service(), self.task)[1]['receipt'], result['receipt'])
        other = self.submit('second')
        reused = self.decision({**binding, 'task': other, 'fingerprint': self.challenge(first, other)['fingerprint']})
        self.assertEqual(self.post(first, 'decide', reused)[1]['reason'], 'nonce_mismatch')
        self.assertEqual(policy.action(other)['status'], 'awaiting-owner')
        self.wake.assert_not_called()

    def test_rollback_before_commit_consumes_nothing(self):
        service = self.service()
        raw = self.decision(self.challenge(service, self.task))
        before = self.box_rows()
        with patch.object(approvals, 'decide_in_transaction', side_effect=ValueError('synthetic crash')):
            self.assertEqual(self.post(service, 'decide', raw)[1]['reason'], 'state_invalid')
        self.assertEqual(self.box_rows(), before)
        self.assertEqual(self.post(service, 'decide', raw)[0], 200)

    def test_process_killed_mid_transaction_leaves_nonce_unused(self):
        service = self.service()
        raw = self.decision(self.challenge(service, self.task))
        before = self.box_rows()
        script = (f"import sys, os; sys.path.insert(0, {str(SCRIPTS)!r})\n"
                  "import swarm_device_approvals as a, swarm_remote as r\n"
                  "def die(db, *args):\n"
                  "    db.execute('UPDATE actions SET status=\"queued\"'); os._exit(9)\n"
                  "a.decide_in_transaction = die\n"
                  f"r.ControlService({ORIGIN!r}, lambda: None).devices.decide('owner', sys.stdin.buffer.read())\n")
        result = subprocess.run([sys.executable, '-B', '-c', script], input=raw, capture_output=True, timeout=60,
                                env={**os.environ, 'PYTHONDONTWRITEBYTECODE': '1'})
        self.assertEqual(result.returncode, 9, result.stderr)
        self.assertEqual(self.box_rows(), before, 'a crash before commit consumes and decides nothing')
        self.assertEqual(self.post(self.service(), 'decide', raw)[0], 200)

    def test_concurrent_consume_has_exactly_one_winner(self):
        service = self.service()
        raw = self.decision(self.challenge(service, self.task))
        other = self.decision(self.challenge(service, self.task), approved=False)
        with ThreadPoolExecutor(max_workers=10) as pool:
            results = list(pool.map(lambda body: self.post(self.service(), 'decide', body), [raw] * 8 + [other] * 2))
        winners = [r for status, r in results if status == 200]
        self.assertEqual(len(winners), 1, results)
        self.assertTrue(all(r.get('reason') in ('operation_not_pending', 'nonce_replayed')
                            for status, r in results if status != 200))
        with database() as db:
            self.assertEqual(db.execute('SELECT count(*) FROM approval_receipts').fetchone()[0], 1)
            self.assertEqual(db.execute('SELECT count(*) FROM approval_challenges WHERE used=1').fetchone()[0], 1)

    def test_revoke_takes_effect_immediately_without_restart(self):
        service = self.service()
        raw = self.decision(self.challenge(service, self.task))
        devices.revoke(DEVICE)
        self.assertEqual(self.post(service, 'decide', raw)[1]['reason'], 'device_revoked')
        status, result = service.handle_v2(remote.PREFIX_V2 + 'owner/challenge',
                                           sign(self.read_body('challenge', self.task), DEVICE, ds.REQUEST_CONTEXT))
        self.assertEqual((status, result['reason']), (403, 'device_revoked'))
        self.assertEqual(self.receipt(service, self.task)[1]['reason'], 'device_revoked')
        with self.assertRaisesRegex(ValueError, 'never reused'):
            self.enroll()
        with self.assertRaisesRegex(ValueError, 'never reused'):
            devices.enroll('TEST-device-1b', KEYS[DEVICE]['ed25519_pub'], ['owner'])
        self.assertEqual(policy.action(self.task)['status'], 'awaiting-owner')
        self.wake.assert_not_called()

    def test_device_required_rejects_v1_with_no_fallback(self):
        devices.set_mode('required')
        flags = {'SWARMHUB_DEVICE_REQUIRED': '0', 'SWARMHUB_APPROVALS': 'v1', 'SWARMHUB_ALLOW_V1': '1'}
        with self.assertRaisesRegex(ValueError, 'unknown policy setting'):
            policy.publish({'device_required': False})
        with patch.dict(os.environ, flags):
            for service in (self.service(), self.service()):  # Survives restarts.
                for verb in ('get', 'decide'):
                    with self.assertRaisesRegex(ValueError, 'device_required'):
                        self.v1(service, verb, self.task)
                with patch.object(remote, 'profile_key', side_effect=AssertionError('authenticated first')):
                    with self.assertRaisesRegex(ValueError, 'device_required'):
                        self.v1(service, 'decide', self.task)
        self.assertEqual(policy.action(self.task)['status'], 'awaiting-owner')
        service = self.service()
        self.assertEqual(self.post(service, 'decide', self.decision(self.challenge(service, self.task)))[0], 200)
        devices.set_mode('legacy')  # Explicit local operator recovery is the only way back.
        self.v1(service, 'get', self.submit('after-recovery'))

    def test_cutover_during_a_v1_request_wins_under_the_lock(self):
        with patch.object(remote, 'v1_allowed', side_effect=[True, False]):
            with self.assertRaisesRegex(ValueError, 'device_required'):
                self.v1(self.service(), 'decide', self.task)
        self.assertEqual(policy.action(self.task)['status'], 'awaiting-owner')

    def test_v2_failure_and_v1_body_on_v2_never_reach_v1(self):
        service = self.service()
        binding = self.challenge(service, self.task)
        tampered = json.loads(self.decision(binding))
        tampered['signed']['approved'] = False
        with patch.object(service, 'handle', side_effect=AssertionError('fell back to v1')):
            self.assertEqual(self.post(service, 'decide', json.dumps(tampered).encode())[1]['reason'],
                             'signature_invalid')
            v1_body = json.dumps({'version': 1, 'verb': 'decide', 'task': self.task}).encode()
            self.assertEqual(self.post(service, 'decide', v1_body)[1]['reason'], 'legacy_v1')
            self.assertEqual(self.post(service, 'challenge', v1_body)[1]['reason'], 'protocol_unsupported')
        self.assertEqual(policy.action(self.task)['status'], 'awaiting-owner')

    def test_http_boundary_routes_v2_without_shared_key(self):
        service = self.service()
        server = remote.ThreadingHTTPServer(('127.0.0.1', 0), remote.handler(service))
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        body = sign(self.read_body('challenge', self.task), DEVICE, ds.REQUEST_CONTEXT)
        with patch.object(remote, 'profile_key', side_effect=AssertionError('read a shared key')):
            connection = http.client.HTTPConnection('127.0.0.1', server.server_address[1], timeout=10)
            connection.request('POST', remote.PREFIX_V2 + 'owner/challenge', body)
            response = connection.getresponse()
            data = json.loads(response.read())
            connection.close()
        self.assertEqual((response.status, data['challenge']['task']), (200, self.task))
        self.assertEqual(response.getheader('Cache-Control'), 'no-store')


class UnenrolledBoxTests(Box):
    def test_unenrolled_box_keeps_v1_unchanged(self):
        task = self.submit()
        service = self.service()
        record = json.loads(base64.b64decode(self.v1(service, 'decide', task)['payload']))['record']
        self.assertTrue(record['remoteReceipt']['approved'])
        self.assertEqual(set(record['remoteReceipt']), {'id', 'approved'})
        with database() as db:
            self.assertEqual(db.execute('SELECT count(*) FROM approval_mode').fetchone()[0], 0)
        other = self.submit('other')
        status, result = service.handle_v2(remote.PREFIX_V2 + 'owner/challenge',
                                           sign(self.read_body('challenge', other), DEVICE, ds.REQUEST_CONTEXT))
        self.assertEqual((status, result['reason']), (403, 'device_unknown'))


class OfflineAndHermesTests(Box):
    def test_update_host_unreachable_changes_nothing(self):
        """Socket use is forbidden in a child process; enrollment, v2 and v1 all still work."""
        script = (f"import sys, os, json, time; sys.path.insert(0, {str(ROOT / 'sim')!r})\n"
                  "def deny(event, args):\n"
                  "    if event.startswith('socket.'): raise AssertionError('network: ' + event)\n"
                  "sys.addaudithook(deny)\n"
                  "import unittest, device_approval_harness as h\n"
                  "class T(h.Box):\n"
                  "    def test(self):\n"
                  "        self.enroll(); task = self.submit(); s = self.service()\n"
                  "        assert self.post(s, 'decide', self.decision(self.challenge(s, task)))[0] == 200\n"
                  "        assert self.receipt(s, task)[0] == 200\n"
                  "        self.v1(s, 'decide', self.submit('v1'))\n"
                  "        h.devices.set_mode('required')\n"
                  "        assert self.post(s, 'decide', self.decision(self.challenge(s, self.submit('v2'))))[0] == 200\n"
                  "r = unittest.TextTestRunner(verbosity=0).run(unittest.defaultTestLoader.loadTestsFromTestCase(T))\n"
                  "sys.exit(0 if r.wasSuccessful() and r.testsRun == 1 else 1)\n")
        env = {**os.environ, 'PYTHONDONTWRITEBYTECODE': '1', 'HTTPS_PROXY': 'http://192.0.2.1:9',
               'HTTP_PROXY': 'http://192.0.2.1:9', 'SWARMHUB_UPDATE_HOST': 'https://192.0.2.1'}
        result = subprocess.run([sys.executable, '-B', '-c', script], capture_output=True, text=True, timeout=120,
                                env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        for name in ('swarm_device_state.py', 'swarm_device_approvals.py', 'swarm_devices.py', 'swarm_remote.py'):
            source = (SCRIPTS / name).read_text()
            self.assertNotIn('urllib.request', source)
            self.assertNotIn('http.client', source)

    def test_hermes_files_and_fixtures_stay_byte_identical(self):
        home = Path(self.tmp.name) / '.hermes'
        server = home / 'hermes-agent/hermes/server.py'
        server.parent.mkdir(parents=True)
        server.write_bytes((ROOT / 'Tests/Fixtures/hermes_v0.21.7_server.py').read_bytes())
        (home / 'config.yaml').write_text('model: TEST\n')

        def hermes_tree():
            return {str(p): p.read_bytes() for p in home.rglob('*')
                    if p.is_file() and 'swarmhub' not in p.relative_to(home).parts}
        before = hermes_tree()
        self.enroll()
        service = self.service()
        task = self.submit()
        self.post(service, 'decide', self.decision(self.challenge(service, task)))
        self.v1(service, 'decide', self.submit('v1'))
        devices.set_mode('required')
        devices.revoke(DEVICE)
        self.assertEqual(hermes_tree(), before)
        digests = {'hermes_v0.21.7_server.py': 'ee87681c782b6b5fb92392d8273764b061d655952f0e9a3711e346271b9fb858',
                   'remote_approval_protocol.json': '59ea2d070a66704564b1ba8918be0b98544962f797989f66d2ea1e1b84706088'}
        for name, digest in digests.items():
            self.assertEqual(hashlib.sha256((ROOT / 'Tests/Fixtures' / name).read_bytes()).hexdigest(), digest)
        sys.path.insert(0, str(ROOT / 'scripts'))
        from approvals import device_approval_vectors as vectors
        self.assertEqual(vectors.encoded_document(), vectors.FIXTURE.read_bytes())

    def test_vendored_crypto_is_byte_identical_to_the_updater(self):
        for name in ('jcs', 'ed25519'):
            self.assertEqual((SCRIPTS / ('swarm_' + name + '.py')).read_bytes(),
                             (ROOT / 'Resources/Updater/swarmhub_update' / (name + '.py')).read_bytes())


if __name__ == '__main__':
    unittest.main()
