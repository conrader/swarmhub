"""P5d2: v2 reads report the box's current device-approval mode, so a device-signed-only app (iOS) can hide
managed approvals the moment an operator returns a box to legacy mode.

The mode is read under the same lock as the response. The exact `gone` receipt shape and the decide response
are unchanged (the Mac matches the gone shape key-for-key). TEST keys only, no network.
"""
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from device_approval_harness import Box, devices, ds, sign  # noqa: E402


class ModeReportTests(Box):
    def setUp(self):
        super().setUp()
        self.enroll()
        self.enroll('TEST-device-2', ('owner',))
        self.task = self.submit()

    def read(self, verb, task, key_id='TEST-device-1'):
        raw = sign(self.read_body(verb, task, key_id), key_id, ds.REQUEST_CONTEXT)
        return self.post(self.service(), verb, raw)

    def test_pending_reads_and_challenges_follow_the_current_mode(self):
        status, result = self.read('receipt', self.task)
        self.assertEqual((status, result['receipt'], result['mode']), (200, None, 'legacy'))
        devices.set_mode('required')
        status, result = self.read('receipt', self.task)
        self.assertEqual((status, result['status'], result['mode']), (200, 'awaiting-owner', 'required'))
        status, result = self.read('challenge', self.task)
        self.assertEqual((status, result['mode']), (200, 'required'))
        self.assertEqual(set(result), {'request', 'challenge', 'record', 'mode'})
        devices.set_mode('legacy')
        status, result = self.read('challenge', self.task)
        self.assertEqual((status, result['mode']), (200, 'legacy'))
        status, result = self.read('receipt', self.task)
        self.assertEqual(set(result), {'request', 'receipt', 'status', 'observed_at', 'record', 'mode'})
        self.assertEqual(result['mode'], 'legacy')

    def test_committed_receipts_report_the_mode_to_every_enrolled_reader(self):
        devices.set_mode('required')
        service = self.service()
        status, decided = self.post(service, 'decide', self.decision(self.challenge(service, self.task)))
        self.assertEqual(status, 200, decided)
        self.assertEqual(set(decided), {'request', 'receipt'}, 'decide response unchanged')
        # Another enrolled device (the phone) reads the same receipt, carrying the deciding device's key ID.
        status, result = self.read('receipt', self.task, 'TEST-device-2')
        self.assertEqual((status, set(result), result['mode']), (200, {'request', 'receipt', 'mode'}, 'required'))
        self.assertEqual(result['receipt'], decided['receipt'])
        self.assertEqual(result['receipt']['remoteReceipt']['device'], 'TEST-device-1')
        devices.set_mode('legacy')
        status, result = self.read('receipt', self.task, 'TEST-device-2')
        self.assertEqual((status, result['mode'], result['receipt']), (200, 'legacy', decided['receipt']))

    def test_phone_sees_the_macs_receipt_for_its_own_unfinished_attempt(self):
        """What iOS adopts as "decided on another device": same operation as its attempt, another key and nonce."""
        devices.set_mode('required')
        service = self.service()
        phone = self.challenge(service, self.task, 'TEST-device-2')  # the phone's saved attempt binds this
        mac = self.challenge(service, self.task)
        self.assertEqual(self.post(service, 'decide', self.decision(mac, approved=False))[0], 200)
        status, refused = self.post(service, 'decide', self.decision(phone, key_id='TEST-device-2'))
        self.assertEqual((status, refused['reason']), (403, 'operation_not_pending'))
        status, result = self.read('receipt', self.task, 'TEST-device-2')
        self.assertEqual((status, result['mode']), (200, 'required'))
        record = result['receipt']
        receipt, binding = record['remoteReceipt'], record['remoteBinding']
        self.assertEqual((receipt['device'], receipt['approved'], record['status']), ('TEST-device-1', False, 'denied'))
        # The fields DeviceSignedApprovalClient.validateOtherDeviceReceipt compares with the phone's attempt.
        self.assertEqual((binding['origin'], binding['runtime'], binding['profile'], record['id'], record['gate']),
                         (phone['origin'], phone['runtime'], phone['profile'], phone['task'], phone['gate']))
        self.assertEqual(receipt['fingerprint'], phone['fingerprint'])
        self.assertNotEqual(receipt['nonce'], phone['nonce'])
        self.assertRegex(receipt['device'], '^' + ds.KEY_ID + '$')

    def test_gone_shape_is_unchanged_in_both_modes(self):
        gone = 'task.' + 'f' * 32
        for mode in ('legacy', 'required'):
            with self.subTest(mode):
                devices.set_mode(mode)
                status, result = self.read('receipt', gone)
                self.assertEqual((status, set(result)), (200, {'request', 'receipt', 'status'}))
                self.assertEqual((result['receipt'], result['status']), (None, 'gone'))

    def test_refusals_carry_no_mode(self):
        devices.set_mode('required')
        status, result = self.read('receipt', self.task, 'TEST-device-unknown')
        self.assertEqual((status, set(result)), (403, {'error', 'reason'}))
        status, result = self.post(self.service(), 'receipt', b'{}')
        self.assertEqual((status, set(result)), (403, {'error', 'reason'}))

    def assert_mode_switch_refuses(self, issued_mode, current_mode):
        devices.set_mode(issued_mode)
        service = self.service()
        challenge = self.challenge(service, self.task)
        # Already signed on the phone; the operator switches before the decision arrives.
        raw = self.decision(challenge)
        devices.set_mode(current_mode)
        before = self.box_rows()
        # A new service instance also sees the persistent invalidation.
        for approved in (True, False):
            status, result = self.post(self.service(), 'decide', raw if approved else self.decision(challenge, False))
            self.assertEqual((status, result), (403, {'error': 'control request refused', 'reason': 'mode_changed'}))
            self.assertEqual(self.box_rows(), before, 'refusal consumes nothing and records no decision')
        status, result = self.receipt(service, self.task)
        self.assertEqual((status, result['receipt'], result['status'], result['mode']),
                         (200, None, 'awaiting-owner', current_mode))
        self.assertIsNone(result['record']['decided_at'])
        self.assertIsNone(result['record']['decided_by'])
        self.wake.assert_not_called()
        # The current mode's normal path still works for this pending operation.
        if current_mode == 'legacy':
            self.v1(service, 'decide', self.task)
        else:
            fresh = self.challenge(service, self.task)
            self.assertEqual(self.post(service, 'decide', self.decision(fresh))[0], 200)

    def test_required_to_legacy_refuses_in_flight_decision(self):
        self.assert_mode_switch_refuses('required', 'legacy')

    def test_legacy_to_required_refuses_in_flight_decision(self):
        self.assert_mode_switch_refuses('legacy', 'required')

    def test_same_mode_challenges_still_work_including_mac_legacy(self):
        for mode in ('legacy', 'required'):
            for approved in (True, False):
                with self.subTest(mode=mode, approved=approved):
                    devices.set_mode(mode)
                    task, service = self.submit(mode + str(approved)), self.service()
                    challenge = self.challenge(service, task)
                    devices.set_mode(mode)  # Repeating the operator command is not a switch.
                    status, result = self.post(service, 'decide', self.decision(challenge, approved))
                    self.assertEqual((status, result['receipt']['remoteReceipt']['approved']), (200, approved))

    def test_switching_back_does_not_revive_old_challenges(self):
        service = self.service()
        challenge = self.challenge(service, self.task)
        devices.set_mode('required')
        devices.set_mode('legacy')
        before = self.box_rows()
        status, result = self.post(service, 'decide', self.decision(challenge))
        self.assertEqual((status, result['reason']), (403, 'mode_changed'))
        self.assertEqual(self.box_rows(), before)
        self.wake.assert_not_called()

    def test_invalidation_marks_are_pruned_with_challenges(self):
        from device_approval_harness import clock
        service = self.service()
        challenge = self.challenge(service, self.task)
        devices.set_mode('required')
        self.assertEqual(self.box_rows()['approval_mode_changed'], [(challenge['nonce'],)])
        with clock(challenge['expires'] + ds.TTL):
            self.challenge(service, self.task)
        self.assertEqual(self.box_rows()['approval_mode_changed'], [])


if __name__ == '__main__':
    unittest.main()
