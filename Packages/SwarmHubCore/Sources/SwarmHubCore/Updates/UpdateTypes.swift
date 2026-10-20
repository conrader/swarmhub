import Foundation

public struct UpdateFloors: Sendable {
    public let keysVersion: Int64
    public let indexSequence: Int64
    public let bundleVersion: Int64

    public init(keysVersion: Int64, indexSequence: Int64, bundleVersion: Int64) {
        self.keysVersion = keysVersion
        self.indexSequence = indexSequence
        self.bundleVersion = bundleVersion
    }
}

public struct UpdateConsumer: Sendable {
    public let platform: String
    public let versions: [String: String]

    public init(platform: String, versions: [String: String]) {
        self.platform = platform
        self.versions = versions
    }
}

public struct UpdateLimits: Sendable {
    public var maxSignedBytes = 1_048_576
    public var maxBlobSize = 67_108_864
    public var maxEntries = 4096
    public var maxFileSize = 8_388_608
    public var maxTotalSize = 67_108_864
    public var maxPathBytes = 255
    public var maxDepth = 16
    public init() {}

    var valid: Bool {
        [maxSignedBytes, maxBlobSize, maxEntries, maxFileSize, maxTotalSize, maxPathBytes, maxDepth]
            .allSatisfy { $0 >= 0 && Int64($0) <= JCS.maxInteger }
    }
}

/// Codable uses the exact public verdict shape from the shared vectors / P0b.
public struct UpdateVerdict: Codable, Equatable, Sendable {
    public struct Skipped: Codable, Equatable, Sendable {
        public let name: String
        public let reason: String
    }
    public let verdict: String
    public let stage: String
    public let reason: String
    public var bundleVersion: Int64? = nil
    public var apply: [String]? = nil
    public var skipped: [Skipped]? = nil

    enum CodingKeys: String, CodingKey {
        case verdict, stage, reason, apply, skipped
        case bundleVersion = "bundle_version"
    }
}

public struct UpdateVerification: Sendable {
    public let verdict: UpdateVerdict
    /// Available only after the entire chain succeeds. No partial results on rejection.
    public let manifest: JCS.Value?
    public let blobs: [String: Data]
}

public enum UpdateInputError: Error { case invalidCallerInput }

struct UpdateRejection: Error {
    let stage: String
    let reason: String
    var noUpdate = false
}

func requireUpdate(_ condition: Bool, _ stage: String, _ reason: String = "schema_invalid") throws {
    if !condition { throw UpdateRejection(stage: stage, reason: reason) }
}
