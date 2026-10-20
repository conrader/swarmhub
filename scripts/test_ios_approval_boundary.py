"""P5d: iOS managed approvals are device-signed only.

Runs scripts/check-ios-approvals.py on this checkout and on temporary copies with injected shared-key code,
and checks statically that the Mac device-signed client moved into SwarmHubCore without a second copy.
Swift cannot be built here; these checks read sources. No network, no Hermes, no keys.
"""
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
CHECK = ROOT / 'scripts/check-ios-approvals.py'
CORE = ROOT / 'Packages/SwarmHubCore/Sources/SwarmHubCore/Approvals'
MAC = ROOT / 'Sources/AgentApp'
IOS = ROOT / 'Apps/iOS/Sources'
MOVED = ['JSONValue', 'ManagedRecord', 'ManagedControlError', 'DeviceApprovalJSON', 'DeviceApprovalWire',
         'DeviceApprovalIdentity', 'DeviceApprovalKeyStore', 'DeviceApprovalSettings']


def run(*args, root=ROOT):
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE='1')
    return subprocess.run([sys.executable, str(CHECK), '--root', str(root), *args],
                          capture_output=True, text=True, env=env, timeout=60)


class BoundaryCheckTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix='p5d-boundary.'))
        for part in ['Apps/iOS/Sources', 'Apps/iOS/SwarmHub.xcodeproj', 'Packages/SwarmHubCore/Sources']:
            shutil.copytree(ROOT / part, self.tmp / part)

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def append(self, relative, text):
        path = self.tmp / relative
        path.write_text(path.read_text() + '\n' + text + '\n')

    def test_checkout_is_clean(self):
        result = run()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('no shared-key approval path', result.stdout)
        self.assertEqual(run(root=self.tmp).returncode, 0)

    def test_injected_shared_key_symbols_fail(self):
        cases = [
            ('Apps/iOS/Sources/ChatView.swift', 'let mac = HMAC<SHA256>.authenticationCode(for: Data(), using: key)', 'CryptoKit HMAC'),
            ('Apps/iOS/Sources/ChatView.swift', 'let key = SymmetricKey(size: .bits256)', 'symmetric approval key'),
            ('Packages/SwarmHubCore/Sources/SwarmHubCore/CoreError.swift', 'let domain = "swarmhub-approval-v1:request"', 'v1 signature domain'),
            ('Packages/SwarmHubCore/Sources/SwarmHubCore/Approvals/DeviceSignedApprovalClient.swift',
             'let path = "/swarmhub/control/v1/" + "owner"', 'v1 control endpoint'),
            ('Packages/SwarmHubCore/Sources/SwarmHubCore/HermesClient.swift',
             'let header = "X-SwarmHub-Signature"', 'v1 signature header'),
            ('Apps/iOS/Sources/MobileStore.swift', 'func legacy() { _ = ManagedRemoteControl.self }', 'Mac v1 client'),
            ('Apps/iOS/Sources/MobileStore.swift', 'let s = "https://box" ; let x = HMAC<SHA256>.self', 'CryptoKit HMAC'),
        ]
        for relative, text, label in cases:
            with self.subTest(label=label, file=relative):
                original = (self.tmp / relative).read_text()
                self.append(relative, text)
                result = run(root=self.tmp)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn(label, result.stderr)
                self.assertIn(relative, result.stderr)
                (self.tmp / relative).write_text(original)

    def test_comments_do_not_count_but_strings_do(self):
        self.append('Apps/iOS/Sources/ChatView.swift', '// No HMAC, SymmetricKey or swarmhub-approval-v1 here.\n/* nested /* HMAC */ still comment */')
        self.assertEqual(run(root=self.tmp).returncode, 0)
        self.append('Apps/iOS/Sources/ChatView.swift', 'let note = "uses // swarmhub-approval-v1"')
        self.assertEqual(run(root=self.tmp).returncode, 1)

    def test_approval_code_cannot_read_the_hermes_key(self):
        self.append('Apps/iOS/Sources/ManagedApprovalStore.swift', 'private let leak = KeychainCredentials()')
        result = run(root=self.tmp)
        self.assertEqual(result.returncode, 1)
        self.assertIn('Hermes key store', result.stderr)

    def test_project_must_compile_only_ios_sources_and_core(self):
        project = self.tmp / 'Apps/iOS/SwarmHub.xcodeproj/project.pbxproj'
        text = project.read_text()
        project.write_text(text.replace('path = "Sources/ChatView.swift"', 'path = "../../Sources/AgentApp/Models/ManagedRemoteControl.swift"'))
        self.assertIn('outside Apps/iOS/Sources', run(root=self.tmp).stderr)
        project.write_text(text.replace('relativePath = ../../Packages/SwarmHubCore;', 'relativePath = ../..;'))
        self.assertIn('package references', run(root=self.tmp).stderr)
        project.write_text(text.replace('check-ios-approvals.py', 'nothing.py'))
        self.assertIn('missing the approval boundary build phase', run(root=self.tmp).stderr)
        project.write_text(text)
        (self.tmp / 'Apps/iOS/Sources/Stale.swift').write_text('struct Stale {}\n')
        self.assertIn('run scripts/generate-ios-project.py', run(root=self.tmp).stderr)

    def test_binary_mode(self):
        clean, dirty = self.tmp / 'clean.bin', self.tmp / 'dirty.bin'
        clean.write_bytes(b'\x00swarmhub-device-approval/2\x00$s9CryptoKit7Curve25519O\x00')
        dirty.write_bytes(b'\x00$s9CryptoKit4HMACVyxGAA\x00')
        self.assertEqual(run('--binary', str(clean)).returncode, 0)
        result = run('--binary', str(dirty))
        self.assertEqual(result.returncode, 1)
        self.assertIn('9CryptoKit4HMAC', result.stderr)
        self.assertEqual(run('--binary', str(self.tmp / 'missing.bin')).returncode, 2)

    def test_generated_project_is_current_and_deterministic(self):
        (self.tmp / 'scripts').mkdir()
        shutil.copy(ROOT / 'scripts/generate-ios-project.py', self.tmp / 'scripts/')
        subprocess.run([sys.executable, str(self.tmp / 'scripts/generate-ios-project.py')], check=True, capture_output=True,
                       env=dict(os.environ, PYTHONDONTWRITEBYTECODE='1'))
        relative = 'Apps/iOS/SwarmHub.xcodeproj/project.pbxproj'
        self.assertEqual((self.tmp / relative).read_bytes(), (ROOT / relative).read_bytes())
        text = (ROOT / relative).read_text()
        phases = re.search(r'buildPhases = \(([^)]*)\)', text).group(1).split(',')
        boundary = re.search(r'(\w+) = \{ isa = PBXShellScriptBuildPhase;[^\n]*check-ios-approvals\.py', text).group(1)
        self.assertEqual(phases[0], boundary, 'the boundary check runs before compiling')
        self.assertEqual(text.count('ENABLE_USER_SCRIPT_SANDBOXING = "NO"'), 2)


class MoveTests(unittest.TestCase):
    def swift(self, folder):
        return {p: p.read_text() for p in folder.rglob('*.swift')}

    def test_moved_types_are_defined_once_in_core(self):
        mac, core = self.swift(MAC), self.swift(CORE)
        alias = (MAC / 'Approvals/DeviceApprovalCore.swift').read_text()
        for name in MOVED:
            pattern = re.compile(r'^(?:public )?(?:final )?(?:enum|struct|class|protocol) ' + name + r'\b', re.M)
            public = re.compile(r'^public (?:final )?(?:enum|struct|class|protocol) ' + name + r'\b', re.M)
            self.assertEqual(len([p for p, t in core.items() if public.search(t)]), 1, name)
            self.assertEqual([p.name for p, t in mac.items() if pattern.search(t)], [], name)
            self.assertIn(f'typealias {name} = SwarmHubCore.{name}', alias)
        self.assertFalse(list(MAC.rglob('DeviceApprovalClient.swift')))

    def test_mac_keeps_its_environment_and_v1_path(self):
        alias = (MAC / 'Approvals/DeviceApprovalCore.swift').read_text()
        self.assertIn('QAMode.boundary.native(request)', alias)
        self.assertIn('TestRunGuard.guarded($0)', alias)
        self.assertIn('TestRunGuard.refuses($0)', alias)
        self.assertEqual(alias.count('environment: .mac'), 2)
        remote = (MAC / 'Models/ManagedRemoteControl.swift').read_text()
        for v1 in ['swarmhub-approval-v1:', 'X-SwarmHub-Signature', '/swarmhub/control/v1/', 'HMAC<SHA256>']:
            self.assertIn(v1, remote)
        client = (CORE / 'DeviceSignedApprovalClient.swift').read_text()
        self.assertIn('"/swarmhub/control/v2/"', client)
        self.assertNotIn('QAMode', client)
        self.assertNotIn('TestRunGuard', client)

    def test_ios_shows_managed_cards_only_for_device_required_boxes(self):
        views = (IOS / 'ManagedApprovalViews.swift').read_text()
        self.assertIn('!managed.requiredOrigins(store.profiles).isEmpty', views)
        store = (IOS / 'ManagedApprovalStore.swift').read_text()
        self.assertIn('ManagedApprovalScope.targets(', store)
        self.assertIn('DeviceApprovalIdentity.iosKeyPrefix', store)
        scope = (CORE / 'ManagedApprovalScope.swift').read_text()
        self.assertIn('settings.isRequired(origin)', scope)
        for path in IOS.glob('*.swift'):
            text = path.read_text()
            self.assertNotIn('DeviceApprovalClient.', text, path.name)  # the Mac wrapper; iOS calls the core flow
            if path.name != 'ManagedApprovalStore.swift':
                self.assertNotIn('confirmOperatorCutover', text, path.name)  # one place routes a box to device-required

    def test_ios_visibility_follows_the_mode_the_box_reports(self):
        """P5d2: a sticky phone setting only opts a box in; legacy or unknown box mode hides and blocks everything."""
        client = (CORE / 'DeviceSignedApprovalClient.swift').read_text()
        self.assertIn('checks: DeviceApprovalChecks = .compatible', client)  # Mac default: P5c behaviour
        self.assertIn('guard response["mode"] == .string("required") else { throw ManagedControlError.notDeviceRequired }', client)
        read = client.index('let response = try await read("receipt"')
        self.assertLess(client.index('if checks.requireDeviceRequiredMode, !gone { try requireDeviceMode(response) }', read),
                        client.index('let record = try decodeRecord(value)', read), 'mode is checked before adopting')
        challenge = client.index('let response = try await read("challenge"')
        self.assertLess(client.index('if checks.requireDeviceRequiredMode { try requireDeviceMode(response) }', challenge),
                        client.index('try settings.remember(signed', challenge), 'mode is checked before signing')
        flow = (CORE / 'ManagedApprovalScope.swift').read_text()
        self.assertEqual(flow.count('checks: .deviceRequiredOnly'), 2)
        store = (IOS / 'ManagedApprovalStore.swift').read_text()
        self.assertIn('.filter(reportedRequired.contains)', store)
        self.assertIn('case .notDeviceRequired:', store)
        self.assertIn('cards.removeAll { $0.target.origin == target.origin }', store)
        self.assertIn('guard reportedRequired.contains(target.origin) else', store)
        self.assertIn('if case .attemptExpired = control { reportedRequired.insert(target.origin) }', store)
        for path in MAC.rglob('*.swift'):
            self.assertNotIn('deviceRequiredOnly', path.read_text(), path)  # Mac behaviour unchanged

    def test_receipts_from_another_enrolled_device_resolve_the_card(self):
        client = (CORE / 'DeviceSignedApprovalClient.swift').read_text()
        self.assertIn('if checks.adoptOtherDeviceReceipts, let device = record.remoteReceipt?.device, device != identity.keyID {',
                      client)
        self.assertIn('receipt.device == device', client)
        self.assertNotIn('receipt.device == identity.keyID', client)
        self.assertIn('try validateReceipt(record, device: identity.keyID,', client)  # public Mac entry unchanged
        other = client[client.index('static func validateOtherDeviceReceipt'):client.index('private static func requireDeviceMode')]
        for check in ('device != identity.keyID', 'expected: nil', 'pending["fingerprint"] == receipt.fingerprint',
                      'pending["runtime"] == .string(binding.runtime)', 'pending["nonce"] != receipt.nonce'):
            self.assertIn(check, other)
        store = (IOS / 'ManagedApprovalStore.swift').read_text()
        self.assertIn('"Decided on another device. "', store)
        self.assertIn('ManagedApprovalFlow.decidedElsewhere(record, identity: identity)', store)

    def test_mode_changed_refusal_frees_the_attempt_and_hides_the_box_without_retry(self):
        client = (CORE / 'DeviceSignedApprovalClient.swift').read_text()
        self.assertIn('"mode_changed"', client[client.index('let refusals: Set<String>'):])
        refusal = client[client.index('} catch let refusal as Refusal {'):client.index('guard let receipt = result')]
        self.assertIn('try settings.clearRefusedAttempt(origin: origin, task: task)', refusal)
        self.assertIn('throw ManagedControlError.refused(refusal.reason)', refusal)
        store = (IOS / 'ManagedApprovalStore.swift').read_text()
        changed = store[store.index('case .refused("mode_changed"):'):store.index('case .notDeviceRequired:')]
        self.assertIn('notice = message', changed)
        self.assertIn('reportedRequired.remove(target.origin)', changed)
        self.assertIn('cards.removeAll { $0.target.origin == target.origin }', changed)
        self.assertIn('return', changed)
        self.assertNotIn('await', changed, 'refusal must not dispatch another request')
        self.assertIn('Not accepted, box mode changed.', (CORE / 'ManagedRecord.swift').read_text())
        views = (IOS / 'ManagedApprovalViews.swift').read_text()
        self.assertIn('else if !store.demo, let notice = managed.notice', views, 'notice survives hiding the section')
        removed = views.index('AvailabilityNote(text: "This operation is no longer pending on this phone.")')
        self.assertIn('if let notice = managed.notice', views[removed:], 'notice survives freeing the detail card')

    def test_native_hermes_approval_path_is_unchanged(self):
        base = subprocess.run(['git', '-C', str(ROOT), 'show', 'b3a5617:Apps/iOS/Sources/MobileStore.swift'],
                              capture_output=True, text=True)
        if base.returncode != 0:
            self.skipTest('base commit b3a5617 not available')
        self.assertEqual((IOS / 'MobileStore.swift').read_text(), base.stdout)
        old = subprocess.run(['git', '-C', str(ROOT), 'show', 'b3a5617:Apps/iOS/Sources/ApprovalsView.swift'],
                             capture_output=True, text=True, check=True).stdout
        new = (IOS / 'ApprovalsView.swift').read_text()
        detail = old[old.index('struct ApprovalDetailView'):]
        self.assertEqual(new[new.index('struct ApprovalDetailView'):], detail)
        added = [l for l in new.splitlines() if l not in old.splitlines()]
        self.assertEqual([l.strip() for l in added], [
            '@Environment(ManagedApprovalStore.self) private var managed',
            '// Device-signed managed approvals; renders nothing unless a connected box is device-required.',
            'ManagedApprovalsSection()',
            '// Asks opted-in boxes for their mode and pending operations even while the managed section is hidden.',
            '.task(id: managed.routingRevision) { await refreshManaged() }',
            '.refreshable { await refreshManaged() }',
            'private func refreshManaged() async { await managed.refresh(profiles: store.profiles, caches: store.caches, '
            'demo: store.demo) }'])

    def test_sources_stay_within_500_lines(self):
        for folder in [CORE, IOS, MAC / 'Approvals', MAC / 'Models', MAC / 'GrokExport/Local']:
            for path in folder.glob('*.swift'):
                self.assertLessEqual(len(path.read_text().splitlines()), 500, path)


if __name__ == '__main__':
    unittest.main()
