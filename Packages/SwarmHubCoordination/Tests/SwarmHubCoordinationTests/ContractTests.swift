import Foundation
import Testing
@testable import SwarmHubCoordination

@Test func deliveryFingerprintBindsRecipientContentAndOrigin() throws {
    let identity = TeamIdentity(botID: UUID(), connection: "https://fixture.invalid", profile: "peer")
    let envelope = TeamEnvelope(operationID: "one", taskID: "task", conversationID: UUID(), recipient: identity, replyToID: nil, kind: "help", payload: "Inspect")
    let original = try envelope.fingerprint
    var changed = envelope; changed.recipient.profile = "other"
    #expect(try changed.fingerprint != original)
    changed = envelope; changed.payload = "Modify"
    #expect(try changed.fingerprint != original)
    let roundTrip = try JSONDecoder().decode(TeamEnvelope.self, from: JSONEncoder().encode(envelope))
    #expect(try roundTrip.fingerprint == original)
}

@Test func expiredOrRevokedPolicyNeverAuthorizesRouting() {
    let now = Date(), identity = TeamIdentity(botID: UUID(), connection: "fixture", profile: "peer")
    var policy = TeamPolicy(originID: UUID(), decision: "Inspect", members: [identity], ownerDeviceID: "device")
    #expect(policy.allows("requestHelp", identity: identity, at: now))
    #expect(!policy.allows("execute", identity: identity, at: now))
    policy.expiresAt = now
    #expect(!policy.allows("requestHelp", identity: identity, at: now))
    policy.expiresAt = nil; policy.revokedAt = now
    #expect(!policy.allows("requestHelp", identity: identity, at: now))
}
