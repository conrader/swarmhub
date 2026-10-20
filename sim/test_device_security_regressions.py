"""P5b review regressions: unsigned local decisions, corrupt points, and CLI TEST-key refusal.

Temp HOME, stdlib only, public TEST seeds through library enrollment only; no sockets.
"""
import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
from unittest.mock import patch
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from device_approval_harness import DEVICE, KEYS, SCRIPTS, Box, devices, ds, policy  # noqa: E402
from swarm_device_approvals import v1_allowed  # noqa: E402
from swarm_store import database  # noqa: E402


class LocalDecisionTests(Box):
    def gateway(self):
        return patch.dict(os.environ, HERMES_HOME=str(Path(self.tmp.name) / '.hermes/profiles/owner'),
                          SWARMHUB_DEVICE_REQUIRED='0', SWARMHUB_ALLOW_V1='1')

    def test_required_mode_refuses_bound_and_unbound_local_allow_and_deny(self):
        self.enroll()
        devices.set_mode('required')
        for gate in ('owner', 'coordinator'):
            for approved in (True, False):
                for bound in (True, False):
                    with self.subTest(gate=gate, approved=approved, bound=bound):
                        task = self.submit(str((gate, approved, bound)))
                        with database() as db:
                            db.execute('UPDATE actions SET gate=?,status=? WHERE id=?',
                                       (gate, 'awaiting-' + gate, task))
                        row = policy.action(task)
                        binding = (row['fingerprint'], row['gate']) if bound else ()
                        before = self.box_rows()
                        with self.gateway(), self.assertRaisesRegex(ValueError, 'device_required'):
                            policy.decide(task, 'owner', approved, *binding)
                        self.assertEqual(self.box_rows(), before)

    def test_both_swarmctl_local_client_paths_refuse_unsigned_decisions(self):
        self.enroll()
        devices.set_mode('required')
        for approved in (True, False):
            task = self.submit(str(approved))
            row = policy.action(task)
            before = self.box_rows()
            for args in (['decide', task, 'owner', 'approve' if approved else 'deny'],
                         ['control', 'decide', task, 'owner']):
                with self.subTest(args=args), self.gateway():
                    result = subprocess.run([sys.executable, '-B', str(SCRIPTS / 'swarmctl'), *args],
                                            input=json.dumps({'approved': approved, 'gate': row['gate'],
                                                              'fingerprint': row['fingerprint']}),
                                            capture_output=True, text=True, timeout=30,
                                            env={**os.environ, 'PYTHONDONTWRITEBYTECODE': '1'})
                self.assertEqual(result.returncode, 64, result.stderr)
                self.assertIn('device_required', result.stderr)
                self.assertEqual(self.box_rows(), before)

    def test_local_mode_check_happens_under_the_transaction_lock(self):
        self.enroll()
        task = self.submit()
        real_database = policy.database

        class CutoverOnLock:
            def __init__(self, db):
                self.db = db

            def execute(self, sql, *args):
                result = self.db.execute(sql, *args)
                if sql == 'BEGIN IMMEDIATE':
                    self.db.execute('UPDATE approval_mode SET required=1')
                return result

        @contextlib.contextmanager
        def cutover_database():
            with real_database() as db:
                yield CutoverOnLock(db)

        with self.gateway(), patch.object(policy, 'database', cutover_database):
            with self.assertRaisesRegex(ValueError, 'device_required'):
                policy.decide(task, 'owner', True)
        self.assertEqual(policy.action(task)['status'], 'awaiting-owner')

    def test_corrupt_legacy_device_list_refuses_local_decisions(self):
        self.enroll()
        task = self.submit()
        with database() as db:
            db.execute('UPDATE approval_devices SET public=?', ('01' + '00' * 31,))
        before = self.box_rows()
        with self.gateway(), self.assertRaisesRegex(ValueError, 'state_invalid'):
            policy.decide(task, 'owner', True)
        self.assertEqual(self.box_rows(), before)

    def test_unenrolled_and_legacy_local_decisions_keep_existing_behavior(self):
        for enrolled in (False, True):
            if enrolled:
                self.enroll()
            for approved in (True, False):
                task = self.submit(str((enrolled, approved)))
                row = policy.action(task)
                with self.gateway():
                    policy.decide(task, 'owner', approved, row['fingerprint'], row['gate'])
                self.assertEqual(policy.action(task)['status'], 'queued' if approved else 'denied')


class StoredPointTests(Box):
    def test_invalid_points_fail_closed_including_v1_in_legacy_mode(self):
        self.enroll()
        service = self.service()
        task = self.submit()
        raw = self.decision(self.challenge(service, task))
        # Canonical encodings still need subgroup checks. Include a mixed-order point (B + order-2).
        base_y = 4 * pow(5, ds.ed25519.P - 2, ds.ed25519.P) % ds.ed25519.P
        mixed = (ds.ed25519.P - base_y) | (1 << 255)
        invalid = {'identity': '01' + '00' * 31, 'order-4': '00' * 32,
                   'order-2': (ds.ed25519.P - 1).to_bytes(32, 'little').hex(),
                   'off-curve': '02' + '00' * 31,
                   'noncanonical': ds.ed25519.P.to_bytes(32, 'little').hex(),
                   'mixed-order': mixed.to_bytes(32, 'little').hex()}
        for name, public in invalid.items():
            self.assertFalse(ds.prime_point(bytes.fromhex(public)), name)
            for required in (0, 1):
                for revoked in (0, 1):
                    with self.subTest(point=name, required=required, revoked=revoked):
                        with database() as db:
                            db.execute('UPDATE approval_devices SET public=?,revoked=?', (public, revoked))
                            db.execute('UPDATE approval_mode SET required=?', (required,))
                        before = self.box_rows()
                        with database() as db:
                            with self.assertRaisesRegex(ds.Refusal, 'state_invalid'):
                                ds.devices(db)
                            self.assertFalse(v1_allowed(db))
                        self.assertEqual(devices.listing()['state'], 'invalid')
                        self.assertEqual(self.post(service, 'decide', raw)[1]['reason'], 'state_invalid')
                        self.assertEqual(self.receipt(service, task)[1]['reason'], 'state_invalid')
                        with self.assertRaisesRegex(ValueError, 'device_required'):
                            self.v1(service, 'decide', task)
                        with self.assertRaisesRegex(ValueError, 'invalid'):
                            self.enroll('TEST-device-2')
                        self.assertEqual(self.box_rows(), before)

    def test_corrupt_unrelated_revoked_device_blocks_valid_device(self):
        self.enroll()
        self.enroll('TEST-device-2')
        devices.revoke('TEST-device-2')
        service = self.service()
        task = self.submit()
        raw = self.decision(self.challenge(service, task))
        with database() as db:
            db.execute('UPDATE approval_devices SET public=? WHERE key_id=?',
                       ('00' * 32, 'TEST-device-2'))
        before = self.box_rows()
        self.assertEqual(self.post(service, 'decide', raw)[1].get('reason'), 'state_invalid')
        with database() as db:
            self.assertFalse(v1_allowed(db))
        self.assertEqual(self.box_rows(), before)


class OperatorTestKeyTests(Box):
    def test_cli_refuses_test_keys_before_confirmation_but_library_can_enroll(self):
        before = self.box_rows()
        with patch.object(devices, 'confirm') as confirm, contextlib.redirect_stdout(io.StringIO()), \
                contextlib.redirect_stderr(io.StringIO()) as error:
            code = devices.main(['enroll', DEVICE, KEYS[DEVICE]['ed25519_pub'], '--profile', 'owner'])
        self.assertEqual(code, 2)
        self.assertIn('TEST-', error.getvalue())
        confirm.assert_not_called()
        self.assertEqual(self.box_rows(), before)
        self.assertEqual(self.enroll()['devices'][0]['key_id'], DEVICE)

    def test_cli_environment_and_flags_cannot_enable_test_keys(self):
        args = ['enroll', DEVICE, KEYS[DEVICE]['ed25519_pub'], '--profile', 'owner']
        before = self.box_rows()
        with patch.dict(os.environ, SWARMHUB_ALLOW_TEST_KEYS='1', SWARMHUB_TEST_MODE='1'):
            with patch.object(devices, 'confirm'), contextlib.redirect_stdout(io.StringIO()), \
                    contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(devices.main(args), 2)
        for flag in ('--allow-test-keys', '--test-keys'):
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as error:
                devices.main([*args, flag])
            self.assertEqual(error.exception.code, 2)
        self.assertEqual(self.box_rows(), before)


if __name__ == '__main__':
    unittest.main()
