"""P5b: operator-only enrollment, fail-closed local state, and challenge/read rules. TEST keys, temp HOME."""
import sim_isolation  # noqa: F401  Exits unless isolated (PID namespace / macOS signal guard); keep it the first import.
import os
from pathlib import Path
import sys
import time
from unittest.mock import patch
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from device_approval_harness import DEVICE, KEYS, ROOT, SCRIPTS, Box, clock, devices, ds, policy, remote, sign  # noqa: E402
import swarm_device_approvals as approvals  # noqa: E402
from swarm_store import database  # noqa: E402

GATEWAY = '/home/u/.hermes/hermes-agent/venv/bin/python /home/u/.hermes/hermes-agent/venv/bin/hermes gateway run'


class OperatorGuardTests(Box):
    def test_model_context_cannot_enroll_revoke_or_switch_mode(self):
        self.enroll()
        before = self.box_rows()
        for env in ({'HERMES_HOME': str(Path(self.tmp.name) / '.hermes/profiles/owner')},
                    {'HERMES_SESSION_ID': 'turn-1'}):
            with self.subTest(env=env), patch.dict(os.environ, env):
                for action in (lambda: self.enroll('TEST-device-2'), lambda: devices.revoke(DEVICE),
                               lambda: devices.set_mode('required'), lambda: devices.set_mode('legacy')):
                    with self.assertRaises(devices.OperatorOnly):
                        action()
                self.assertEqual(devices.main(['mode', 'required']), 77)
        with patch.object(devices, 'ancestors', return_value=['bash', GATEWAY]):
            with self.assertRaises(devices.OperatorOnly):
                devices.set_mode('required')
        with patch.object(devices.subprocess, 'run', side_effect=lambda *a, **k: devices.subprocess.CompletedProcess(a, 1, '', '')):
            with self.assertRaisesRegex(devices.OperatorOnly, 'ancestry'):
                devices.revoke(DEVICE)
        self.assertEqual(self.box_rows(), before)

    def test_hermes_ancestor_detection(self):
        for line in (GATEWAY, 'hermes chat', '/usr/local/bin/hermes-gateway --profile x',
                     'python3 -m hermes_cli.main gateway'):
            self.assertTrue(devices.hermes_process(line), line)
        for line in ('-bash', 'sshd: konrad@pts/0', 'python3 /home/u/.hermes/skills/swarmhub/swarmhub-messages/'
                     'scripts/swarm_devices.py list', 'tmux new -s ops', 'vim notes-on-hermesbots.txt'):
            self.assertFalse(devices.hermes_process(line), line)
        devices.refuse_model_context(environ={}, ancestry=lambda: ['-bash', 'sshd: konrad@pts/0'])

    def test_changes_need_a_code_typed_on_the_terminal(self):
        self.enroll()  # TEST fixtures enter through the library, never the operator CLI.
        with patch.object(devices, 'TTY', str(Path(self.tmp.name) / 'no-tty')):
            self.assertEqual(devices.main(['mode', 'required']), 77)
        self.assertEqual(devices.listing()['mode'], 'legacy')
        master, slave = os.openpty()
        self.addCleanup(os.close, master)
        self.addCleanup(os.close, slave)
        with patch.object(devices, 'TTY', os.ttyname(slave)), patch.object(devices.secrets, 'token_hex',
                                                                         return_value='c0ffee'):
            os.write(master, b'wrong\n')
            self.assertEqual(devices.main(['mode', 'required']), 77)
            self.assertEqual(devices.listing()['mode'], 'legacy')
            os.write(master, b'c0ffee\n')
            self.assertEqual(devices.main(['mode', 'required']), 0)
        listed = devices.listing()
        self.assertEqual((listed['mode'], [d['key_id'] for d in listed['devices']]), ('required', [DEVICE]))
        self.assertIn(b'c0ffee', os.read(master, 4096))

    def test_no_model_facing_entry_point(self):
        for name in ('swarmctl', 'swarm_control.py', 'bot-msg', 'peer-runtime.py'):
            self.assertNotIn('swarm_devices', (SCRIPTS / name).read_text(), name)
        self.assertNotIn('swarm_devices', (SCRIPTS.parent / 'SKILL.md').read_text())


class EnrollmentRuleTests(Box):
    def test_enrollment_validation_and_never_reused_ids(self):
        public = KEYS[DEVICE]['ed25519_pub']
        for key_id, key, profiles in (('bad id!', public, ['owner']), (DEVICE, public.upper(), ['owner']),
                                      (DEVICE, '01' + '00' * 31, ['owner']), (DEVICE, public[:62], ['owner']),
                                      (DEVICE, public, ['missing']), (DEVICE, public, ['owner', 'owner']),
                                      (DEVICE, public, []), (DEVICE, public, ['own.er'])):
            with self.subTest(key_id=key_id, key=key, profiles=profiles), self.assertRaises(ValueError):
                devices.enroll(key_id, key, profiles)
        with self.assertRaisesRegex(ValueError, 'active device'):
            devices.set_mode('required')
        self.enroll()
        devices.set_mode('required')
        devices.revoke(DEVICE)
        self.assertEqual(devices.listing()['mode'], 'required', 'revoking the last device never relaxes the mode')
        with self.assertRaisesRegex(ValueError, 'device_required'):
            self.v1(self.service(), 'get', self.submit())
        with self.assertRaisesRegex(ValueError, 'never reused'):
            self.enroll()
        self.enroll('TEST-device-2')  # Rotation: a new ID with a new key.
        with self.assertRaisesRegex(ValueError, 'unknown key ID'):
            devices.revoke('TEST-device-unknown')


class CorruptStateTests(Box):
    CORRUPTIONS = {
        'device public': "UPDATE approval_devices SET public='zz'",
        'device profiles not canonical': "UPDATE approval_devices SET profiles='[ \"owner\"]'",
        'device profiles empty': "UPDATE approval_devices SET profiles='[]'",
        'device revoked flag': "UPDATE approval_devices SET revoked=2",
        'device key duplicated': "INSERT INTO approval_devices SELECT 'TEST-copy',public,profiles,0,0,'' FROM approval_devices",
        'mode value': "UPDATE approval_mode SET required=7",
        'mode row removed': "DELETE FROM approval_mode",
        'challenge binding': "UPDATE approval_challenges SET binding='{'",
        'challenge used flag': "UPDATE approval_challenges SET used=3",
        'challenge column mismatch': "UPDATE approval_challenges SET expires=expires+1",
        'challenge unknown field': "UPDATE approval_challenges SET binding=substr(binding,1,1)||'\"x\":1,'||substr(binding,2)",
        'runtime': "UPDATE approval_runtime SET identity='not-a-uuid'",
    }

    def setUp(self):
        super().setUp()
        self.enroll()
        self.task = self.submit()

    def test_every_corruption_fails_closed_for_v2_v1_and_operator_changes(self):
        for name, sql in self.CORRUPTIONS.items():
            with self.subTest(name):
                self.reset_state()
                service = self.service()
                binding = self.challenge(service, self.task)
                with database() as db:
                    db.execute(sql)
                self.assertEqual(self.post(service, 'decide', self.decision(binding)),
                                 (403, {'error': 'control request refused', 'reason': 'state_invalid'}))
                self.assertEqual(policy.action(self.task)['status'], 'awaiting-owner')
                if name.startswith(('device', 'mode')):
                    with self.assertRaisesRegex(ValueError, 'device_required'):
                        self.v1(service, 'get', self.task)
                    self.assertEqual(devices.listing()['state'], 'invalid')
                    with self.assertRaisesRegex(ValueError, 'invalid'):
                        self.enroll('TEST-device-2')

    def reset_state(self):
        with database() as db:
            for table in ('approval_devices', 'approval_mode', 'approval_challenges', 'approval_runtime'):
                db.execute('DELETE FROM ' + table)
        self.enroll()

    def test_clock_problems_fail_closed(self):
        service = self.service()
        raw = self.decision(self.challenge(service, self.task))
        for value in (float('nan'), float('inf'), -1.0, 2.0 ** 60):
            with self.subTest(value=value), clock(value):
                self.assertEqual(self.post(service, 'decide', raw)[1]['reason'], 'state_invalid')
        issued = ds.jcs.loads(raw)['signed']['issued']
        with clock(issued - 30):  # Box clock went backwards behind an issued challenge.
            status, result = service.handle_v2(remote.PREFIX_V2 + 'owner/challenge', sign(
                self.read_body('challenge', self.task, issued=issued - 30), DEVICE, ds.REQUEST_CONTEXT))
            self.assertEqual((status, result['reason']), (403, 'state_invalid'))
            self.assertEqual(self.post(service, 'decide', raw)[1]['reason'], 'nonce_not_yet_valid')
        with clock(issued + 60):
            self.assertEqual(self.post(service, 'decide', raw)[1]['reason'], 'nonce_expired')
        self.assertEqual(policy.action(self.task)['status'], 'awaiting-owner')


class ChallengeRuleTests(Box):
    def setUp(self):
        super().setUp()
        self.enroll()
        self.task = self.submit()
        self.service_ = self.service()

    def read(self, verb, profile='owner', key_id=DEVICE, context=ds.REQUEST_CONTEXT, **changes):
        raw = sign(self.read_body(verb, self.task, key_id, profile, **changes), key_id, context)
        return self.service_.handle_v2(remote.PREFIX_V2 + profile + '/' + verb, raw)

    def reason(self, *args, **kwargs):
        status, result = self.read(*args, **kwargs)
        self.assertEqual(status, 403, result)
        return result['reason']

    def test_read_requests_are_signed_fresh_exact_and_scoped(self):
        now = int(time.time())
        self.assertEqual(self.reason('challenge', context=ds.CONTEXT), 'signature_invalid')
        self.assertEqual(self.reason('challenge', issued=now - 61), 'request_expired')
        self.assertEqual(self.reason('challenge', issued=now + 30), 'request_expired')
        self.assertEqual(self.reason('challenge', origin='https://other.example.invalid'), 'box_mismatch')
        wrong_verb = sign(self.read_body('receipt', self.task), DEVICE, ds.REQUEST_CONTEXT)
        self.assertEqual(self.service_.handle_v2(remote.PREFIX_V2 + 'owner/challenge', wrong_verb)[1]['reason'],
                         'protocol_unsupported')
        self.assertEqual(self.reason('challenge', extra=1), 'schema_invalid')
        self.assertEqual(self.reason('challenge', key_id='TEST-device-unknown'), 'device_unknown')
        self.enroll('TEST-device-2', profiles=('worker',))
        self.assertEqual(self.reason('challenge', profile='worker', key_id='TEST-device-2'), 'profile_mismatch')
        self.assertEqual(self.reason('challenge', key_id='TEST-device-2'), 'device_unauthorized')
        status, result = self.read('receipt', profile='worker', key_id='TEST-device-2')
        self.assertEqual((status, result['receipt'], result['status']), (200, None, 'awaiting-owner'))
        bad = self.service_.handle_v2(remote.PREFIX_V2 + 'owner', b'{}')
        self.assertEqual(bad, (403, {'error': 'control request refused', 'reason': 'schema_invalid'}))

    def test_challenge_limits_and_pending_state(self):
        for _ in range(approvals.PER_DEVICE):
            self.assertEqual(self.read('challenge')[0], 200)
        self.assertEqual(self.reason('challenge'), 'challenge_limited')
        policy.stop(self.task)
        self.assertEqual(self.reason('challenge'), 'operation_not_pending')

    def test_policy_rotation_runtime_replacement_and_expiry_while_waiting(self):
        binding = self.challenge(self.service_, self.task)
        raw = self.decision(binding)
        policy.publish({'owner': 'other'})
        self.assertEqual(self.post(self.service_, 'decide', raw)[1]['reason'], 'profile_mismatch')
        policy.publish({'owner': 'owner'})
        with database() as db:
            db.execute("UPDATE approval_runtime SET identity='bbbbbbbb-bbbb-cccc-dddd-eeeeeeeeeeee'")
        self.assertEqual(self.post(self.service_, 'decide', raw)[1]['reason'], 'box_mismatch')
        with database() as db:
            db.execute('UPDATE approval_runtime SET identity=?', (binding['runtime'],))
        real, moved = approvals.database, clock(binding['expires'])

        def slow_lock():  # The clock passes expiry while this decision waits for the database lock.
            moved.start()
            self.addCleanup(moved.stop)
            return real()
        with patch.object(approvals, 'database', side_effect=slow_lock):
            self.assertEqual(self.post(self.service_, 'decide', raw)[1]['reason'], 'nonce_expired')
        self.assertEqual(policy.action(self.task)['status'], 'awaiting-owner')


if __name__ == '__main__':
    unittest.main()
