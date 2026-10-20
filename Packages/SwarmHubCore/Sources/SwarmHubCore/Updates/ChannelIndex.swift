import Foundation
import CryptoKit

/// Passed to the caller's manifest provider only after index verification and selection.
public struct UpdateLine: Sendable {
    public let bundleVersion: Int64
    public let manifestSHA256: String
    public let rolloutPercent: Int64
    let requires: [String: String]
}

struct ChannelIndex {
    let lines: [UpdateLine]

    static func verify(_ data: Data, keys: KeyManifest, channel: String, now: String,
                       floors: UpdateFloors, revoked: Set<String>, limits: UpdateLimits) throws -> Self {
        let s = UpdateShape(stage: "index")
        let envelope = try updateEnvelope(data, stage: "index", limits: limits)
        let signed = envelope.signed
        try requireUpdate(signed["schema"] == .string("swarmhub/index/1"), "index")
        let name = try s.text(signed["channel"], pattern: "[a-z0-9-]{1,32}")
        let sequence = try s.number(signed["seq"], low: 1)
        _ = try s.time(signed["issued"])
        let expires = try s.time(signed["expires"])
        let lines = try s.array(signed["lines"]).map { value in
            let line = try s.object(value)
            return UpdateLine(bundleVersion: try s.number(line["bundle_version"], low: 1),
                              manifestSHA256: try s.text(line["manifest_sha256"], pattern: "[0-9a-f]{64}"),
                              rolloutPercent: try s.number(line["rollout_percent"], high: 100),
                              requires: try s.requires(line["requires"]))
        }
        try keys.check(envelope, role: "index", stage: "index", now: now, revoked: revoked)
        try requireUpdate(sequence >= floors.indexSequence, "index", "index_rollback")
        try requireUpdate(name == channel, "index", "channel_mismatch")
        try requireUpdate(now < expires, "index", "index_expired")
        return Self(lines: lines)
    }

    func select(consumer: UpdateConsumer, installID: String, floors: UpdateFloors) throws -> UpdateLine {
        let compatible = lines.filter { satisfies($0.requires, consumer) }
        try requireUpdate(!compatible.isEmpty, "index", "no_compatible_line")
        let included = compatible.filter {
            Self.bucket(installID: installID, bundleVersion: $0.bundleVersion) < $0.rolloutPercent
        }
        guard var line = included.first else {
            throw UpdateRejection(stage: "index", reason: "not_in_rollout", noUpdate: true)
        }
        // Stable on ties, as Python max() is.
        for candidate in included.dropFirst() where candidate.bundleVersion > line.bundleVersion { line = candidate }
        try requireUpdate(line.bundleVersion >= floors.bundleVersion, "index", "bundle_rollback")
        if line.bundleVersion == floors.bundleVersion {
            throw UpdateRejection(stage: "index", reason: "already_applied", noUpdate: true)
        }
        return line
    }

    static func bucket(installID: String, bundleVersion: Int64) -> Int64 {
        let digest = SHA256.hash(data: Data("\(installID)\n\(bundleVersion)".utf8))
        let number = digest.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        return Int64(number % 100)
    }
}
