import Foundation
import Testing
@testable import SwarmHubCore

/// P5d2 review gaps: the phone follows the mode the box reports on every read (unknown or legacy: nothing shown,
/// nothing signed), and a valid receipt another enrolled device committed resolves the phone's card. The Mac's
/// `.compatible` checks keep the P5c behaviour.
struct ManagedApprovalModeTests {
    typealias Harness = ManagedApprovalFlowTests.Harness
    static let mac = "TEST-device-2"

    @Test func legacyOrUnreportedModeShowsNothing() async throws {
        for mode in ["legacy", nil] as [String?] {
            let harness = try Harness()
            harness.box.lock.withLock { harness.box.modes["receipt"] = mode }
            do { _ = try await harness.load(); Issue.record("a box not reporting device-required must not load") }
            catch ManagedControlError.notDeviceRequired {} catch { Issue.record(error) }
            // A committed receipt is hidden as well while the box is not device-required.
            harness.box.lock.withLock { harness.box.committed = DeviceBoxProtocol.receipt(harness.box.origin, approved: true, device: Self.mac) }
            do { _ = try await harness.load(); Issue.record("a receipt from a legacy box must not resolve anything") }
            catch ManagedControlError.notDeviceRequired {} catch { Issue.record(error) }
            #expect(harness.calls == ["receipt", "receipt"])
        }
    }

    @Test func returningToLegacyAfterReviewBlocksTheDecisionBeforeAnythingIsSigned() async throws {
        let harness = try Harness()
        let reviewed = try await harness.load()
        harness.box.lock.withLock { harness.box.modes["receipt"] = "legacy" }
        do { _ = try await harness.decide(reviewed, true); Issue.record("a legacy box must not get a decision") }
        catch ManagedControlError.notDeviceRequired {} catch { Issue.record(error) }
        // The operator's switch back to legacy can also land between the read and the challenge.
        harness.box.lock.withLock { harness.box.modes = ["receipt": "required", "challenge": "legacy"] }
        do { _ = try await harness.decide(reviewed, true); Issue.record("a legacy challenge must not be signed") }
        catch ManagedControlError.notDeviceRequired {} catch { Issue.record(error) }
        #expect(harness.calls == ["receipt", "receipt", "receipt", "challenge"])
        #expect(!harness.settings.hasAttempt(origin: harness.box.origin, task: DeviceBoxProtocol.task))
        // Device-required again: the same reviewed card decides normally.
        harness.box.lock.withLock { harness.box.modes["challenge"] = "required" }
        let receipt = try await harness.decide(reviewed, false)
        #expect(receipt.remoteReceipt?.approved == false && !ManagedApprovalFlow.decidedElsewhere(receipt, identity: harness.identity))
    }

    @Test func aDecisionFromAnotherEnrolledDeviceResolvesTheCard() async throws {
        let harness = try Harness()
        let reviewed = try await harness.load()
        harness.box.lock.withLock { harness.box.committed = DeviceBoxProtocol.receipt(harness.box.origin, approved: true, device: Self.mac) }
        let read = try await harness.load()
        #expect(read.remoteReceipt?.device == Self.mac && ManagedApprovalFlow.decidedElsewhere(read, identity: harness.identity))
        // A tap on the stale card adopts that receipt: no challenge, no decision, no saved attempt.
        let adopted = try await harness.decide(reviewed, false)
        #expect(adopted.remoteReceipt?.approved == true && ManagedApprovalFlow.decidedElsewhere(adopted, identity: harness.identity))
        #expect(harness.calls == ["receipt", "receipt", "receipt"])
        #expect(!harness.settings.hasAttempt(origin: harness.box.origin, task: DeviceBoxProtocol.task))
    }

    @Test func modeSwitchAfterChallengeRefusesAndFreesThePhoneAttemptWithoutRetry() async throws {
        for approved in [true, false] {
            let harness = try Harness()
            let reviewed = try await harness.load()
            harness.box.lock.withLock { harness.box.modeAfterChallenge = "legacy" }
            do { _ = try await harness.decide(reviewed, approved); Issue.record("mode switch must refuse") }
            catch ManagedControlError.refused(let reason) {
                #expect(reason == "mode_changed")
                #expect(ManagedControlError.refused(reason).localizedDescription ==
                        "Not accepted, box mode changed. The operation remains pending.")
            } catch { Issue.record(error) }
            #expect(!harness.settings.hasAttempt(origin: harness.box.origin, task: DeviceBoxProtocol.task))
            #expect(harness.box.lock.withLock { harness.box.committed == nil })
            #expect(harness.calls == ["receipt", "receipt", "challenge", "decide"])
            // Refresh is read-only and hides the legacy box; it never re-signs the freed choice.
            do { _ = try await harness.load(); Issue.record("legacy box must stay hidden") }
            catch ManagedControlError.notDeviceRequired {} catch { Issue.record(error) }
            #expect(harness.calls == ["receipt", "receipt", "challenge", "decide", "receipt"])
        }
    }

    @Test func anotherDevicesReceiptSettlesThisDevicesUncertainAttempt() async throws {
        let harness = try Harness()
        let reviewed = try await harness.load()
        harness.box.lock.withLock { harness.box.dropDecision = true }
        await #expect(throws: ManagedControlError.self) { try await harness.decide(reviewed, true) }
        #expect(harness.settings.hasAttempt(origin: harness.box.origin, task: DeviceBoxProtocol.task))
        harness.box.lock.withLock { harness.box.committed = DeviceBoxProtocol.receipt(harness.box.origin, approved: false, device: Self.mac) }
        let settled = try await harness.load()
        #expect(settled.remoteReceipt?.approved == false && ManagedApprovalFlow.decidedElsewhere(settled, identity: harness.identity))
        #expect(!harness.settings.hasAttempt(origin: harness.box.origin, task: DeviceBoxProtocol.task))
        #expect(harness.calls.filter { $0 == "decide" }.count == 1)
    }

    @Test func forgedOrMismatchedReceiptsAreStillRejected() async throws {
        let harness = try Harness()
        let origin = harness.box.origin
        // Without a saved attempt: another operation's fingerprint, another box's binding, an invalid key ID.
        for record in [DeviceBoxProtocol.receipt(origin, approved: true, device: Self.mac, fingerprint: String(repeating: "d", count: 64)),
                       DeviceBoxProtocol.receipt(origin, approved: true, device: Self.mac, bindingOrigin: "https://elsewhere.example.invalid"),
                       DeviceBoxProtocol.receipt(origin, approved: true, device: "bad key id!")] {
            harness.box.lock.withLock { harness.box.committed = record }
            do { _ = try await harness.load(); Issue.record("a mismatched receipt was adopted") }
            catch ManagedControlError.invalidRecord {} catch { Issue.record(error) }
        }
        // With an uncertain attempt: a receipt reusing this device's nonce, or carrying this device's key ID with a
        // nonce it never signed, is not another device's decision. The attempt stays locked.
        harness.box.lock.withLock { harness.box.committed = nil; harness.box.dropDecision = true }
        let reviewed = try await harness.load()
        await #expect(throws: ManagedControlError.self) { try await harness.decide(reviewed, true) }
        for record in [DeviceBoxProtocol.receipt(origin, approved: true, device: Self.mac, nonce: String(repeating: "1", count: 64)),
                       DeviceBoxProtocol.receipt(origin, approved: true, device: harness.identity.keyID)] {
            harness.box.lock.withLock { harness.box.committed = record }
            do { _ = try await harness.load(); Issue.record("a mismatched receipt settled the attempt") }
            catch ManagedControlError.invalidRecord {} catch { Issue.record(error) }
            #expect(harness.settings.hasAttempt(origin: origin, task: DeviceBoxProtocol.task))
        }
    }

    @Test func compatibleChecksKeepTheMacBehaviour() async throws {
        let harness = try Harness()
        let origin = harness.box.origin
        func get() async throws -> ManagedRecord {
            try await DeviceSignedApprovalClient.request(address: origin, profile: "owner", verb: "get", task: DeviceBoxProtocol.task,
                                                         input: nil, identity: harness.identity, settings: harness.settings,
                                                         session: harness.session, timeout: 5)
        }
        // A box that reports no mode still serves the Mac, and another device's receipt is still not this device's.
        harness.box.lock.withLock { harness.box.modes = [:] }
        #expect(try await get().awaiting)
        harness.box.lock.withLock { harness.box.committed = DeviceBoxProtocol.receipt(origin, approved: true, device: Self.mac) }
        do { _ = try await get(); Issue.record("the Mac adopted another device's receipt") }
        catch ManagedControlError.invalidRecord {} catch { Issue.record(error) }
        #expect(DeviceApprovalChecks.compatible == .init(requireDeviceRequiredMode: false, adoptOtherDeviceReceipts: false))
    }
}
