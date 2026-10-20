import Foundation

/// A future carrier exchanges only the shared document, never the device's local observation history.
/// Implementations must preserve remote fields when publishing (merge or conditional write), and may
/// return duplicates or stale snapshots: the caller merges them into its latest local state.
/// No network, iCloud or export/import implementation is selected here.
public protocol BotPromptSyncTransport: Sendable {
    func exchange(_ document: BotPromptDocument) async throws -> BotPromptDocument
}

/// Local, atomic persistence shared by both apps. The stable origin and observation history survive
/// relaunch so an unchanged Mac setting cannot overwrite a received edit after restart.
/// All access is serialized on the main actor; a failed save leaves the in-memory state unchanged.
@MainActor public final class BotPromptSyncStore {
    private struct Saved: Codable {
        var origin: String
        var state: BotPromptSyncState
    }

    public let origin: String
    public private(set) var state: BotPromptSyncState
    private let fileURL: URL?
    private let writeFile: (Data, URL) throws -> Void

    /// A nil URL is an isolated in-memory store for demos/tests. Corrupt or future-schema files throw
    /// and remain untouched; callers must surface the storage problem rather than reset the file.
    /// The writer defaults to an atomic write; injection lets callers test persistence failures.
    public init(fileURL: URL?, writeFile: @escaping (Data, URL) throws -> Void = { data, url in
        try data.write(to: url, options: .atomic)
    }) throws {
        self.fileURL = fileURL
        self.writeFile = writeFile
        if let fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
            let saved = try JSONDecoder().decode(Saved.self, from: Data(contentsOf: fileURL))
            guard !saved.origin.isEmpty, saved.state.document.schema == BotPromptDocument.schema else {
                throw CoreError.storage
            }
            origin = saved.origin
            var restored = saved.state
            // Apply the same field validation as a received document.
            restored.document = BotPromptDocument()
            restored.merge(saved.state.document)
            state = restored
        } else {
            origin = UUID().uuidString
            state = BotPromptSyncState()
        }
    }

    public func context(for key: String, fallback: BotPromptContext) -> BotPromptContext {
        state.context(for: key, fallback: fallback)
    }

    public func observe(_ local: BotPromptContext, key: String, now: Int64) throws {
        try update { $0.observe(local, key: key, origin: origin, now: now) }
    }

    public func edit(key: String, now: Int64, fallback: BotPromptContext,
                     _ change: (inout BotPromptContext) -> Void) throws {
        try update { $0.edit(key: key, origin: origin, now: now, fallback: fallback, change) }
    }

    @discardableResult public func merge(_ remote: BotPromptDocument) throws -> Bool {
        guard remote.schema == BotPromptDocument.schema else { return false }
        try update { _ = $0.merge(remote) }
        return true
    }

    /// Merge into the state that exists AFTER the await, preserving edits made during the exchange.
    /// Local commits are already durable if the transport fails; callers can retry later.
    @discardableResult public func synchronize(using transport: any BotPromptSyncTransport) async throws -> Bool {
        let remote = try await transport.exchange(state.document)
        return try merge(remote)
    }

    private func update(_ change: (inout BotPromptSyncState) -> Void) throws {
        var next = state
        change(&next)
        // Swift String equality treats NFC/NFD as equal. Compare canonical JSON bytes so a winner
        // that differs only in Unicode spelling is still committed, even at clock saturation.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard try encoder.encode(next) != encoder.encode(state) else { return }
        if let fileURL {
            let data = try encoder.encode(Saved(origin: origin, state: next))
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try writeFile(data, fileURL)
        }
        state = next
    }
}
