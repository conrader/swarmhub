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


if __name__ == '__main__':
    unittest.main()
