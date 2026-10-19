"""Receipt rotation, signed retirement, and transactional cancellation; SQLite/stubs only."""
import base64
from contextlib import contextmanager
import hashlib
import json
from pathlib import Path
import sqlite3
import unittest
from unittest.mock import patch

try:
    from sim import test_remote_approvals as fixture
except ImportError:
    import test_remote_approvals as fixture


remote, policy, database, canonical = fixture.remote, fixture.policy, fixture.database, fixture.canonical


class ApprovalRobustnessTests(unittest.TestCase):
    setUp = fixture.RemoteApprovalTests.setUp
    submit = fixture.RemoteApprovalTests.submit
    request = fixture.RemoteApprovalTests.request
    send = fixture.RemoteApprovalTests.send
    unchanged = fixture.RemoteApprovalTests.unchanged

    def envelope(self, request):
        key = self.keys[request['profile']]
        raw = canonical(request).encode()
        envelope = self.service.handle(remote.PREFIX + request['profile'], 'Bearer ' + key,
                                       remote.mac(key, 'request', raw), raw)
        payload = base64.b64decode(envelope['payload'])
        self.assertEqual(envelope['signature'], remote.mac(key, 'response', payload))
        result = json.loads(payload)
        self.assertEqual(result['request'], hashlib.sha256(raw).hexdigest())
        self.assertEqual(result['expires'], request['expires'])
        return result

    def test_saved_receipt_uses_original_profile_after_policy_rotation_for_both_choices(self):
        for approved in (True, False):
            with self.subTest(approved=approved):
                policy.publish({'owner': 'owner'})
                self.task = self.submit('rotate-' + str(approved))
                receipt = self.send(self.request('decide', approved=approved))
                policy.publish({'owner': 'other'})
                restarted = remote.ControlService(self.service.origin, self.wake)
                self.assertEqual(receipt, self.send(self.request(), service=restarted))
                self.assertEqual(receipt['remoteBinding']['profile'], 'owner')
                with self.assertRaises(ValueError):
                    self.send(self.request('decide', approved=approved))
                with self.assertRaises(ValueError):
                    self.send(self.request(profile='other'))
        pending = policy.submit({'kind': 'outbound', 'bot': 'worker', 'intent': 'new-policy-operation',
                                 'fake': True, 'to': 'nobody@example.invalid', 'text': 'another FAKE operation',
                                 'risks': ['money']})
        with self.assertRaises(ValueError):
            self.send(self.request('decide', task=pending))
        binding = dict(origin=self.service.origin, runtime=self.service.runtime, profile='other')
        result = self.send(self.request('decide', task=pending, profile='other', binding=binding))
        self.assertEqual(result['decided_by'], 'other')

    def test_gone_and_superseded_gets_are_authenticated_retirements_not_decisions(self):
        gone = 'task.' + '0' * 32
        cases = [(self.request(task=gone), 'gone')]
        policy.publish({'owner': 'other'})
        cases.append((self.request(), 'superseded'))
        for request, reason in cases:
            result = self.envelope(request)
            self.assertNotIn('record', result)
            self.assertEqual(result['retired'], dict(task=request['task'], origin=self.service.origin,
                                                    runtime=self.service.runtime, reason=reason))
        self.unchanged()
        policy.publish({'owner': 'owner'})
        policy.stop(self.task)
        self.assertEqual(self.envelope(self.request())['retired']['reason'], 'superseded')
        with self.assertRaises(ValueError):
            self.send(self.request('decide'))

    def child(self):
        return policy.submit({'kind': 'read', 'bot': 'worker', 'intent': 'child',
                              'parent': self.task, 'argv': ['/bin/ls'], 'fake': True})

    def test_denial_markers_observe_committed_parent_and_child_status(self):
        child = self.child()
        touch = Path.touch
        seen = []
        def check(path, *args, **kwargs):
            if path.parent.name == 'cancelled':
                # A separate connection cannot see the uncommitted transaction.
                db = sqlite3.connect(Path(self.tmp.name) / '.hermes/swarmhub/control.sqlite')
                try:
                    states = dict(db.execute('SELECT id,status FROM actions'))
                    self.assertEqual(states[self.task], 'denied')
                    self.assertEqual(states[child], 'cancelled')
                    self.assertEqual(db.execute('SELECT count(*) FROM approval_receipts').fetchone()[0], 1)
                finally:
                    db.close()
                seen.append(path.name)
            return touch(path, *args, **kwargs)
        with patch.object(Path, 'touch', check):
            self.send(self.request('decide', approved=False))
        self.assertEqual(set(seen), {self.task, child})

    def test_commit_failure_leaves_neither_markers_nor_decision(self):
        child = self.child()
        with database() as db:
            db.executescript('''
                CREATE TABLE missing_parent(id INTEGER PRIMARY KEY);
                CREATE TABLE commit_failure(id INTEGER REFERENCES missing_parent(id) DEFERRABLE INITIALLY DEFERRED);
                CREATE TRIGGER fail_commit AFTER INSERT ON approval_receipts
                BEGIN INSERT INTO commit_failure VALUES(1); END;
            ''')
        @contextmanager
        def failing_database():
            with database() as db:
                db.execute('PRAGMA foreign_keys=ON')
                yield db
        with patch.object(remote, 'database', failing_database), self.assertRaises(sqlite3.IntegrityError):
            self.send(self.request('decide', approved=False))
        self.unchanged()
        self.assertEqual(policy.action(child)['status'], 'queued')
        folder = Path(self.tmp.name) / '.hermes/swarmhub/cancelled'
        self.assertFalse(folder.exists() and list(folder.iterdir()))
        with database() as db:
            for table in ('cancellation_markers', 'approval_receipts', 'approval_nonces', 'denials'):
                self.assertEqual(db.execute('SELECT count(*) FROM ' + table).fetchone()[0], 0, table)

    def test_marker_write_failure_keeps_committed_receipt_and_retries_outbox(self):
        child = self.child()
        with patch.object(Path, 'touch', side_effect=OSError('synthetic disk failure')), self.assertRaises(OSError):
            self.send(self.request('decide', approved=False))
        # Get replays the receipt and flushes the durable outbox, without a second decision.
        receipt = self.send(self.request())
        self.assertFalse(receipt['remoteReceipt']['approved'])
        folder = Path(self.tmp.name) / '.hermes/swarmhub/cancelled'
        self.assertEqual({p.name for p in folder.iterdir()}, {self.task, child})
        with database() as db:
            self.assertEqual(db.execute('SELECT count(*) FROM cancellation_markers').fetchone()[0], 0)
        self.wake.assert_not_called()

    def test_local_stop_uses_the_same_committed_outbox(self):
        child = self.child()
        stopped = policy.stop(self.task)
        folder = Path(self.tmp.name) / '.hermes/swarmhub/cancelled'
        self.assertEqual(set(stopped), {self.task, child})
        self.assertTrue(all((folder / task).exists() for task in stopped))
        self.assertTrue(all(policy.action(task)['status'] == 'cancelled' for task in stopped))
