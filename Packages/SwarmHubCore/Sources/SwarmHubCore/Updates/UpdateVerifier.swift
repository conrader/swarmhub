import Foundation

/// P0c / CORE-PLAN §3.1. No storage, clock, network, execution or extraction policy.
public enum UpdateVerifier {
    /// Providers are invoked only after the preceding checks succeed. Provider errors propagate to the
    /// caller, like P0b; invalid caller inputs throw. Untrusted wire data always produces a verdict.
    public static func verify(
        pins: Data, keys: Data, index: Data,
        fetchManifest: (UpdateLine) throws -> Data,
        fetchBlob: (UpdateComponent) throws -> Data,
        channel: String, now: String, floors: UpdateFloors, consumer: UpdateConsumer, installID: String,
        revokedKeyIDs: Set<String> = [], limits: UpdateLimits = .init()
    ) throws -> UpdateVerification {
        guard validUpdateTime(now), updateAxes[consumer.platform] != nil,
              consumer.versions.values.allSatisfy({ matches($0, updateVersion) }),
              [floors.keysVersion, floors.indexSequence, floors.bundleVersion]
                .allSatisfy({ $0 >= 0 && $0 <= JCS.maxInteger }), limits.valid else {
            throw UpdateInputError.invalidCallerInput
        }
        do {
            let releaseKeys = try KeyManifest.verify(pins: pins, manifest: keys, floors: floors, limits: limits)
            let channelIndex = try ChannelIndex.verify(index, keys: releaseKeys, channel: channel, now: now,
                                                       floors: floors, revoked: revokedKeyIDs, limits: limits)
            let line = try channelIndex.select(consumer: consumer, installID: installID, floors: floors)
            let manifest = try BundleManifest.verify(fetchManifest(line), line: line, keys: releaseKeys,
                consumer: consumer, now: now, revoked: revokedKeyIDs, limits: limits)
            let (apply, skipped) = manifest.plan(consumer)
            var blobs: [String: Data] = [:]
            for component in apply {
                try requireUpdate(component.size <= Int64(limits.maxBlobSize), "component", "archive_oversize")
                let blob = try fetchBlob(component)
                try requireUpdate(Int64(blob.count) == component.size, "component", "blob_size_mismatch")
                try requireUpdate(updateDigest(blob) == component.sha256, "component", "blob_hash_mismatch")
                let inspection: ArchiveRules.Inspection
                do { inspection = try ArchiveRules.check(blob, kind: component.kind, limits: limits) }
                catch let error as ArchiveRules.Invalid {
                    throw UpdateRejection(stage: "component", reason: error.reason)
                }
                try requireUpdate(!inspection.needsCode || component.contentClass == "code", "component", "class_mismatch")
                blobs[component.name] = blob
            }
            let verdict = UpdateVerdict(verdict: "accept", stage: "component", reason: "ok",
                bundleVersion: manifest.version, apply: apply.map(\.name), skipped: skipped)
            return UpdateVerification(verdict: verdict, manifest: .object(manifest.signed), blobs: blobs)
        } catch let error as UpdateRejection {
            return UpdateVerification(verdict: UpdateVerdict(verdict: error.noUpdate ? "no_update" : "reject",
                stage: error.stage, reason: error.reason), manifest: nil, blobs: [:])
        }
    }
}
