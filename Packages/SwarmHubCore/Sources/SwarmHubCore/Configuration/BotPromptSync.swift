import Foundation

/// One synced slot value. `at` is milliseconds since 1970 from a hybrid clock: a local write is never
/// stamped at or below a value this device has already seen, so a later edit wins even with a slow clock.
/// `at == 0` is a baseline: a device's first reading of its own settings, which any real edit beats.
public struct PromptStamp<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public var value: Value
    public var at: Int64
    public var origin: String
    public init(value: Value, at: Int64, origin: String) { self.value = value; self.at = at; self.origin = origin }

    /// Last write wins. Equal times break on origin, then value bytes, so every device picks the same winner.
    static func winner(_ a: Self?, _ b: Self?, sortKey: (Value) -> String) -> Self? {
        guard let a else { return b }; guard let b else { return a }
        if a.at != b.at { return a.at > b.at ? a : b }
        if !bytesEqual(a.origin, b.origin) { return bytesPrecede(a.origin, b.origin) ? b : a }
        return bytesPrecede(sortKey(a.value), sortKey(b.value)) ? b : a
    }
}

// Bytes, not String ==: Swift compares canonical equivalence, which would let NFC and NFD spellings tie
// and make the winner depend on argument order (and diverge from the Python port).
private func bytesPrecede(_ a: String, _ b: String) -> Bool { a.utf8.lexicographicallyPrecedes(b.utf8) }
private func bytesEqual(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }
private func bytesEqual(_ a: [String], _ b: [String]) -> Bool { a.count == b.count && zip(a, b).allSatisfy { bytesEqual($0, $1) } }

/// The synced BotPromptContext slots of one bot. Each field merges on its own; an absent field means no device
/// has written it and the reader's local default applies. Personas, credentials and transcripts are not here.
public struct BotPromptSettings: Codable, Equatable, Sendable {
    public var name: PromptStamp<String>?
    public var role: PromptStamp<String>?
    public var owner: PromptStamp<String>?
    /// An empty value is an explicit "no coordinator", so clearing it syncs like any other edit.
    public var coordinator: PromptStamp<String>?
    public var timeZone: PromptStamp<String>?
    public var language: PromptStamp<String>?
    public var approvalRules: PromptStamp<[String]>?
    public var quietHours: PromptStamp<String>?
    public init() {}

    typealias TextField = (settings: WritableKeyPath<BotPromptSettings, PromptStamp<String>?>,
                           context: WritableKeyPath<BotPromptContext, String>)
    // Computed, not a stored static: key paths are not reliably Sendable under Swift 6 checking.
    static var textFields: [TextField] {
        [(\.name, \.name), (\.role, \.role), (\.owner, \.owner), (\.coordinator, \.coordinatorText),
         (\.timeZone, \.timeZone), (\.language, \.language), (\.quietHours, \.quietHours)]
    }
    static let maxText = 2_000
    static let maxRules = 50

    static func merged(_ a: Self, _ b: Self) -> Self {
        var result = BotPromptSettings()
        for field in textFields {
            result[keyPath: field.settings] = PromptStamp<String>.winner(a[keyPath: field.settings].flatMap(acceptableText),
                                                                 b[keyPath: field.settings].flatMap(acceptableText)) { $0 }
        }
        result.approvalRules = PromptStamp<[String]>.winner(a.approvalRules.flatMap(acceptableRules), b.approvalRules.flatMap(acceptableRules)) {
            // Length-prefixed, so different rule lists never share a tie-break key.
            $0.map { "\($0.utf8.count):\($0)" }.joined()
        }
        return result
    }

    /// A remote device can be wrong or hostile; oversized values are dropped, never truncated into a new meaning.
    /// Lengths count Unicode scalars so the Python simulation (sim/prompt_sync.py) draws the same line.
    static func acceptableText(_ stamp: PromptStamp<String>) -> PromptStamp<String>? {
        stamp.value.unicodeScalars.count <= maxText && stamp.at >= 0 ? stamp : nil
    }

    static func acceptableRules(_ stamp: PromptStamp<[String]>) -> PromptStamp<[String]>? {
        stamp.value.count <= maxRules && stamp.value.allSatisfy { $0.unicodeScalars.count <= maxText } && stamp.at >= 0 ? stamp : nil
    }
}

extension BotPromptContext {
    var coordinatorText: String {
        get { coordinator ?? "" }
        set { coordinator = newValue.isEmpty ? nil : newValue }
    }
}

/// The document a transport carries between the Mac and iOS apps: every bot's synced slots, keyed by botKey.
/// Merge is commutative, associative and idempotent, so devices converge in any delivery order.
public struct BotPromptDocument: Codable, Equatable, Sendable {
    public static let schema = 1
    public var schema = BotPromptDocument.schema
    public var bots: [String: BotPromptSettings] = [:]
    public init() {}

    enum CodingKeys: String, CodingKey { case schema, bots }

    /// Missing keys read as an unmergeable schema or no bots, as in the Python port, rather than a decode error.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decodeIfPresent(Int.self, forKey: .schema) ?? 0
        bots = try container.decodeIfPresent([String: BotPromptSettings].self, forKey: .bots) ?? [:]
    }

    /// The same bot on Mac and iPhone: its normalized server address plus its Hermes profile.
    public static func botKey(_ address: ConnectionAddress) -> String {
        var components = URLComponents(url: address.baseURL, resolvingAgainstBaseURL: false)
        components?.host = components?.host?.lowercased()
        return (components?.url?.absoluteString ?? address.baseURL.absoluteString) + "#" + address.profile
    }

    /// A document from a different schema is left unmerged (false) rather than half-read.
    @discardableResult public mutating func merge(_ remote: BotPromptDocument) -> Bool {
        guard remote.schema == Self.schema else { return false }
        for (key, theirs) in remote.bots { bots[key] = BotPromptSettings.merged(bots[key] ?? .init(), theirs) }
        return true
    }

    /// The prompt context to render: synced values over the reader's own defaults.
    public func context(for key: String, fallback: BotPromptContext) -> BotPromptContext {
        guard let settings = bots[key] else { return fallback }
        var context = fallback
        for field in BotPromptSettings.textFields {
            if let stamp = settings[keyPath: field.settings] { context[keyPath: field.context] = stamp.value }
        }
        if let rules = settings.approvalRules { context.approvalRules = rules.value }
        return context
    }

    /// Stamp every field where `new` differs from `old`. A nil `old` is a baseline reading: it only fills
    /// fields no device has written yet, at time 0, so it never overrides another device's edit.
    mutating func write(_ new: BotPromptContext, over old: BotPromptContext?, key: String, origin: String, now: Int64) {
        var settings = bots[key] ?? .init()
        let baseline = old == nil
        func stamp<V: Codable & Equatable & Sendable>(_ current: PromptStamp<V>?, _ value: V, changed: Bool) -> PromptStamp<V>? {
            if baseline { return current ?? PromptStamp(value: value, at: 0, origin: origin) }
            guard changed else { return current }
            return PromptStamp(value: value, at: max(now, (current?.at ?? -1) + 1), origin: origin)
        }
        for field in BotPromptSettings.textFields {
            let value = new[keyPath: field.context]
            settings[keyPath: field.settings] = stamp(settings[keyPath: field.settings], value,
                                                      changed: old.map { !bytesEqual($0[keyPath: field.context], value) } ?? true)
        }
        settings.approvalRules = stamp(settings.approvalRules, new.approvalRules,
                                       changed: old.map { !bytesEqual($0.approvalRules, new.approvalRules) } ?? true)
        bots[key] = settings
    }
}

/// One device's sync state: the shared document plus the last local settings it has published per bot.
public struct BotPromptSyncState: Codable, Equatable, Sendable {
    public var document = BotPromptDocument()
    public var observed: [String: BotPromptContext] = [:]
    public init() {}

    /// For a device that owns these settings elsewhere (the Mac's identity, routing and quiet-hour settings):
    /// call before rendering; only fields that changed locally since the last call are published.
    public mutating func observe(_ local: BotPromptContext, key: String, origin: String, now: Int64) {
        document.write(local, over: observed[key], key: key, origin: origin, now: now)
        observed[key] = local
    }

    /// An explicit edit made through this device's UI, applied to what it currently renders.
    public mutating func edit(key: String, origin: String, now: Int64, fallback: BotPromptContext,
                              _ change: (inout BotPromptContext) -> Void) {
        let current = document.context(for: key, fallback: fallback)
        var updated = current; change(&updated)
        document.write(updated, over: current, key: key, origin: origin, now: now)
    }

    public func context(for key: String, fallback: BotPromptContext) -> BotPromptContext {
        document.context(for: key, fallback: fallback)
    }

    @discardableResult public mutating func merge(_ remote: BotPromptDocument) -> Bool { document.merge(remote) }
}
