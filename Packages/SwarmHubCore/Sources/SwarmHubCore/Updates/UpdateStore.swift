import Foundation

/// Persisted floors, freshness and the install's rollout identity (CORE-PLAN §2.2, §3.2).
public struct UpdateState: Codable, Equatable, Sendable {
    public var keysVersion: Int64 = 0
    public var indexSequence: Int64 = 0
    public var bundleVersion: Int64 = 0
    /// Random and local; never sent anywhere (§2.2).
    public var installID: String
    public var lastCheck: String? = nil
    public var lastVerified: String? = nil
    /// `expires` of the last verified index.
    public var freshUntil: String? = nil
    /// First failed check since the last verified index.
    public var failingSince: String? = nil
    public var lastResult: UpdateVerdict? = nil
    /// Bundle whose floor was written before its switch (§3.1 step 5). Set until the switch completes, so a
    /// kill in between can re-apply exactly that bundle (or a newer one) and never a lower one.
    public var pendingBundle: Int64? = nil

    public init(installID: String) { self.installID = installID }

    public var floors: UpdateFloors {
        UpdateFloors(keysVersion: keysVersion, indexSequence: indexSequence, bundleVersion: bundleVersion)
    }

    /// Floors only rise: a persisted value below the compiled baseline is ignored.
    mutating func raise(to floors: UpdateFloors) {
        keysVersion = max(keysVersion, floors.keysVersion)
        indexSequence = max(indexSequence, floors.indexSequence)
        bundleVersion = max(bundleVersion, floors.bundleVersion)
    }

    /// "Updates stale since <date>" (§3.2): the expiry of the last verified index once passed, or the first
    /// failed check when no index has verified yet. Display only; runtime never depends on it.
    public func staleSince(now: String) -> String? {
        if let freshUntil { return now >= freshUntil ? freshUntil : nil }
        return failingSince
    }

    enum CodingKeys: String, CodingKey {
        case keysVersion = "keys_version", indexSequence = "index_seq", bundleVersion = "bundle_version"
        case installID = "install_id", lastCheck = "last_check", lastVerified = "last_verified"
        case freshUntil = "fresh_until", failingSince = "failing_since", lastResult = "last_result"
        case pendingBundle = "pending_bundle"
    }
}

/// `{bundle_version, manifest_sha256, applied_at}` (§3.1 step 5) plus the stored data components.
public struct UpdateRecord: Codable, Equatable, Sendable {
    public struct Component: Codable, Equatable, Sendable {
        public let name: String
        public let kind: String
        public let contentClass: String
        public let version: String
        public let sha256: String
        public let size: Int64

        enum CodingKeys: String, CodingKey {
            case name, kind, version, sha256, size
            case contentClass = "class"
        }
    }
    public let bundleVersion: Int64
    public let manifestSHA256: String
    public let appliedAt: String
    public let platform: String
    public let components: [Component]

    enum CodingKeys: String, CodingKey {
        case platform, components
        case bundleVersion = "bundle_version", manifestSHA256 = "manifest_sha256", appliedAt = "applied_at"
    }
}

/// Everything one commit writes: verified signed metadata and the verified archives, by component name.
struct UpdateSnapshot: Sendable {
    let record: UpdateRecord
    let keys: Data
    let index: Data
    let manifest: Data
    let blobs: [String: Data]
}

public enum UpdateStoreError: Error, Equatable { case unreadableState, noPrevious, storage }

/// P4a / CORE-PLAN §3.1 step 5, §3.3. Holds verified data only. Archives stay opaque bytes: nothing here
/// extracts, loads or executes them. Layout under `root`:
///
///     state.json            floors, freshness, install id
///     versions/<id>/        record.json, keys.json, index.json, bundle.json, components/<name>
///     current -> versions/<id>
///     previous -> versions/<id>
///
/// `current` and `previous` are symlinks, each replaced by a single rename(2), so an interrupted switch
/// leaves the old or the new bundle current, never neither. No error path deletes the running version.
public struct UpdateStore: Sendable {
    public enum Slot: String, Sendable { case current, previous }

    public let root: URL
    /// Test seam: runs after staging and before the switch. A throw must leave `current` untouched.
    var beforeSwitch: (@Sendable () throws -> Void)? = nil
    /// Test seam: runs right after `current` is switched, before anything else is written.
    var afterSwitch: (@Sendable () -> Void)? = nil
    /// Test seam: runs before each state write. A throw is a failed write; nothing is written.
    var beforeStateWrite: (@Sendable (UpdateState) throws -> Void)? = nil
    /// Test seam: runs after pinning the record, before each component's single byte read.
    var beforeComponentRead: (@Sendable (String) throws -> Void)? = nil

    public init(root: URL) { self.root = root }

    /// Application Support on the Mac. On iOS the same lookup resolves inside the app container.
    public static func defaultRoot(folder: String = "SwarmHub") throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true)
            .appendingPathComponent(folder, isDirectory: true).appendingPathComponent("Updates", isDirectory: true)
    }

    // MARK: State

    /// nil when no state was ever written. A present but unreadable file throws: floors are never guessed.
    public func loadState() throws -> UpdateState? {
        let url = root.appendingPathComponent("state.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do { return try JSONDecoder().decode(UpdateState.self, from: Data(contentsOf: url)) }
        catch { throw UpdateStoreError.unreadableState }
    }

    public func saveState(_ state: UpdateState) throws {
        try beforeStateWrite?(state)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try encoder.encode(state).write(to: root.appendingPathComponent("state.json"), options: .atomic)
    }

    // MARK: Reading

    public func record(_ slot: Slot = .current) -> UpdateRecord? {
        (try? pinnedBundle(slot))?.record
    }

    /// Resolve the slot once, then read its record once. All subsequent reads use this directory and
    /// record, even if the slot switches. Collection/corruption fails reads; it never retargets them.
    func pinnedBundle(_ slot: Slot = .current) throws -> PinnedBundle? {
        guard let id = target(slot.rawValue) else { return nil }
        let directory = versions.appendingPathComponent(id, isDirectory: true)
        do {
            let record = try JSONDecoder().decode(UpdateRecord.self, from: Data(contentsOf: directory.appendingPathComponent("record.json")))
            return PinnedBundle(record: record, directory: directory, beforeComponentRead: beforeComponentRead)
        } catch { throw UpdateStoreError.storage }
    }

    struct PinnedBundle: Sendable {
        let record: UpdateRecord
        let directory: URL
        let beforeComponentRead: (@Sendable (String) throws -> Void)?

        func component(_ name: String) -> Data? {
            guard matches(name, updateName), let entry = record.components.first(where: { $0.name == name }) else { return nil }
            do { try beforeComponentRead?(name) } catch { return nil }
            let url = directory.appendingPathComponent("components").appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url), Int64(data.count) == entry.size,
                  updateDigest(data) == entry.sha256 else { return nil }
            return data
        }
    }

    /// The stored archive bytes, only when they still match the record's size and SHA-256. Opaque data:
    /// interpreting config or UI documents is the caller's compiled code (P6a, P7a).
    public func component(_ name: String, in slot: Slot = .current) -> Data? {
        (try? pinnedBundle(slot))?.component(name)
    }

    // MARK: Switching

    /// Stage into a fresh directory, then switch `previous` to the old current and `current` to the new one.
    func commit(_ snapshot: UpdateSnapshot) throws {
        let fm = FileManager.default
        let id = Self.versionID(snapshot.record)
        // Re-committing what is already current (killed after the switch, before the state recorded it) is a no-op.
        if target(Slot.current.rawValue) == id { return }
        guard target(Slot.previous.rawValue) != id else { throw UpdateStoreError.storage }
        let staging = root.appendingPathComponent("staging", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        let components = staging.appendingPathComponent("components", isDirectory: true)
        try fm.createDirectory(at: components, withIntermediateDirectories: true)
        try snapshot.keys.write(to: staging.appendingPathComponent("keys.json"))
        try snapshot.index.write(to: staging.appendingPathComponent("index.json"))
        try snapshot.manifest.write(to: staging.appendingPathComponent("bundle.json"))
        for entry in snapshot.record.components {
            guard matches(entry.name, updateName), let blob = snapshot.blobs[entry.name] else {
                throw UpdateStoreError.storage
            }
            try blob.write(to: components.appendingPathComponent(entry.name))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Written last: a version directory without a record is never made current.
        try encoder.encode(snapshot.record).write(to: staging.appendingPathComponent("record.json"))
        try beforeSwitch?()
        try fm.createDirectory(at: versions, withIntermediateDirectories: true)
        let destination = versions.appendingPathComponent(id, isDirectory: true)
        // Not current or previous (checked above), so only an interrupted earlier commit can have left it.
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: staging, to: destination)
        if let old = target(Slot.current.rawValue) { try point(.previous, to: old) }
        try point(.current, to: id)
        afterSwitch?()
        collect()
    }

    /// Local rollback (§2.2): swap `current` and `previous`. Floors are not lowered, so this pins the
    /// previous bundle until a newer one is published.
    public func revertToPrevious() throws {
        guard let old = target(Slot.previous.rawValue), let now = target(Slot.current.rawValue), old != now,
              record(.previous) != nil else { throw UpdateStoreError.noPrevious }
        try point(.current, to: old)
        try point(.previous, to: now)
    }

    static func versionID(_ record: UpdateRecord) -> String {
        "\(record.bundleVersion)-\(record.manifestSHA256.prefix(16))"
    }

    private var versions: URL { root.appendingPathComponent("versions", isDirectory: true) }

    /// The version directory a slot names, or nil when absent or not one of ours.
    func target(_ name: String) -> String? {
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(
                atPath: root.appendingPathComponent(name).path),
              destination.hasPrefix("versions/") else { return nil }
        let id = String(destination.dropFirst("versions/".count))
        return matches(id, "[0-9]{1,16}-[0-9a-f]{16}") ? id : nil
    }

    private func point(_ slot: Slot, to id: String) throws {
        let temporary = root.appendingPathComponent(".\(slot.rawValue)-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(atPath: temporary.path, withDestinationPath: "versions/" + id)
        guard rename(temporary.path, root.appendingPathComponent(slot.rawValue).path) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw UpdateStoreError.storage
        }
    }

    /// Best effort, after a successful switch: drop unreferenced versions and leftover staging.
    private func collect() {
        let fm = FileManager.default
        let live = Set([Slot.current, .previous].compactMap { target($0.rawValue) })
        for name in (try? fm.contentsOfDirectory(atPath: versions.path)) ?? [] where !live.contains(name) {
            try? fm.removeItem(at: versions.appendingPathComponent(name))
        }
        try? fm.removeItem(at: root.appendingPathComponent("staging", isDirectory: true))
        for name in (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
        where name.hasPrefix(".current-") || name.hasPrefix(".previous-") {
            try? fm.removeItem(at: root.appendingPathComponent(name))
        }
    }
}
