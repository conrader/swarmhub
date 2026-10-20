import Foundation

struct KeyManifest {
    struct ReleaseKey {
        let publicHex: String
        let roles: [String]
        let notAfter: String
    }
    let keys: [String: ReleaseKey]

    static func verify(pins data: Data, manifest: Data, floors: UpdateFloors, limits: UpdateLimits) throws -> Self {
        let p = UpdateShape(stage: "pins")
        let pins = try p.object(parseUpdate(data, stage: "pins", limits: limits))
        try requireUpdate(pins["schema"] == .string("swarmhub/pins/1"), "pins")
        let rootEntries = try p.array(pins["roots"], nonempty: true)
        var roots: [String: String] = [:]
        for entry in rootEntries {
            let root = try p.object(entry)
            let id = try p.text(root["key_id"], pattern: updateKeyID)
            roots[id] = try p.text(root["ed25519_pub"], pattern: "[0-9a-f]{64}")
        }
        let threshold = try p.number(pins["threshold"], low: 1, high: Int64(rootEntries.count))
        let s = UpdateShape(stage: "keys")
        let envelope = try updateEnvelope(manifest, stage: "keys", limits: limits)
        let signed = envelope.signed
        try requireUpdate(signed["schema"] == .string("swarmhub/keys/1"), "keys")
        let version = try s.number(signed["version"], low: 1)
        _ = try s.time(signed["issued"])
        let entries = try s.array(signed["keys"], nonempty: true)
        var keys: [String: ReleaseKey] = [:]
        for entry in entries {
            let key = try s.object(entry)
            let id = try s.text(key["key_id"], pattern: updateKeyID)
            let publicHex = try s.text(key["ed25519_pub"], pattern: "[0-9a-f]{64}")
            let notAfter = try s.time(key["not_after"])
            let roles = try s.stringSet(key["roles"], ["bundle", "index"])
            try requireUpdate(keys[id] == nil, "keys")
            keys[id] = ReleaseKey(publicHex: publicHex, roles: roles, notAfter: notAfter)
        }
        var seen: Set<String> = []
        for signature in envelope.signatures {
            guard let publicHex = roots[signature.keyID], !seen.contains(signature.keyID) else {
                throw UpdateRejection(stage: "keys", reason: "keys_untrusted")
            }
            try requireUpdate(validUpdateSignature(signature, publicHex: publicHex, signed: signed),
                              "keys", "keys_bad_signature")
            seen.insert(signature.keyID)
        }
        try requireUpdate(Int64(seen.count) >= threshold, "keys", "keys_threshold")
        try requireUpdate(version >= floors.keysVersion, "keys", "keys_rollback")
        return Self(keys: keys)
    }

    func check(_ envelope: UpdateEnvelope, role: String, stage: String, now: String, revoked: Set<String>) throws {
        let signature = envelope.signatures[0] // envelope validated as nonempty
        try requireUpdate(!revoked.contains(signature.keyID), stage, "key_revoked")
        guard let key = keys[signature.keyID] else { throw UpdateRejection(stage: stage, reason: "unknown_key") }
        try requireUpdate(key.roles.contains(role), stage, "key_wrong_role")
        try requireUpdate(now < key.notAfter, stage, "key_expired")
        try requireUpdate(validUpdateSignature(signature, publicHex: key.publicHex, signed: envelope.signed),
                          stage, "bad_signature")
    }
}
