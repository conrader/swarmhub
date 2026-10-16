import Foundation

/// JSON that can cross Swift concurrency boundaries without carrying untyped objects.
enum ComposioValue: Codable, Sendable, Equatable {
    case object([String: ComposioValue]), array([ComposioValue]), string(String), number(Double), bool(Bool), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let value = try? c.decode(Bool.self) { self = .bool(value) }
        else if let value = try? c.decode(String.self) { self = .string(value) }
        else if let value = try? c.decode(Double.self) { self = .number(value) }
        else if let value = try? c.decode([ComposioValue].self) { self = .array(value) }
        else { self = .object(try c.decode([String: ComposioValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let value): try c.encode(value)
        case .array(let value): try c.encode(value)
        case .string(let value): try c.encode(value)
        case .number(let value): try c.encode(value)
        case .bool(let value): try c.encode(value)
        case .null: try c.encodeNil()
        }
    }

    subscript(_ key: String) -> ComposioValue { object?[key] ?? .null }
    var object: [String: ComposioValue]? { if case .object(let value) = self { value } else { nil } }
    var array: [ComposioValue]? { if case .array(let value) = self { value } else { nil } }
    var string: String? { if case .string(let value) = self { value } else { nil } }
    var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
    static func strings(_ values: [String]) -> Self { .array(values.map(Self.string)) }

    func text() throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    /// Tool results are data, never instructions. Strip credential fields before forwarding to a bot.
    func withoutCredentials() -> Self {
        switch self {
        case .object(let values):
            let secrets: Set<String> = ["token", "accesstoken", "refreshtoken", "apikey", "authorization", "password", "secret", "clientsecret", "cookie", "privatekey", "oauthtoken", "oauthtokensecret"]
            return .object(values.filter { !secrets.contains($0.key.lowercased().filter { $0.isLetter || $0.isNumber }) }
                .mapValues { $0.withoutCredentials() })
        case .array(let values): return .array(values.map { $0.withoutCredentials() })
        default: return self
        }
    }
}

struct ComposioToolkit: Identifiable, Sendable, Equatable {
    let id: String; let name: String; let detail: String
    init?(_ value: ComposioValue) {
        guard let slug = value["slug"].string, ComposioClient.validIdentifier(slug) else { return nil }
        id = slug; name = value["name"].string ?? slug; detail = value["meta"]["description"].string ?? ""
    }
    static func displayName(_ slug: String, catalog: [Self] = []) -> String {
        (catalog + popular).first { $0.id == slug }?.name ?? slug.replacingOccurrences(of: "_", with: " ").capitalized
    }
    /// Initial choices need no user key. The full catalog loads after the first connection is started.
    static let popular: [Self] = [
        ("gmail", "Gmail", "Email and drafts"), ("googlecalendar", "Google Calendar", "Events and calendars"),
        ("slack", "Slack", "Channels and messages"), ("googledrive", "Google Drive", "Files and documents"),
        ("notion", "Notion", "Pages and databases"), ("github", "GitHub", "Repositories and issues")
    ].compactMap { slug, name, detail in Self(.object(["slug": .string(slug), "name": .string(name), "meta": .object(["description": .string(detail)])])) }
}

struct ComposioAccount: Identifiable, Sendable, Equatable {
    let id: String; let toolkit: String; let label: String; let status: String; let disabled: Bool
    var isActive: Bool { status == "ACTIVE" && !disabled }
    init?(_ value: ComposioValue) {
        guard let id = value["id"].string, let toolkit = value["toolkit"]["slug"].string,
              ComposioClient.validIdentifier(id), ComposioClient.validIdentifier(toolkit), let status = value["status"].string else { return nil }
        self.id = id; self.toolkit = toolkit; self.status = status; disabled = value["is_disabled"].bool ?? false
        label = value["alias"].string ?? value["word_id"].string ?? toolkit
        // Intentionally discard state/data: connected-account responses can contain credentials.
    }
}

struct ComposioTool: Sendable, Equatable {
    let slug: String; let toolkit: String; let name: String; let schema: ComposioValue
    init?(_ value: ComposioValue) {
        guard let slug = value["slug"].string, let toolkit = value["toolkit"]["slug"].string,
              ComposioClient.validIdentifier(slug), !slug.hasPrefix("COMPOSIO_"), ComposioClient.validIdentifier(toolkit),
              value["input_parameters"].object != nil else { return nil }
        self.slug = slug; self.toolkit = toolkit; name = value["name"].string ?? slug; schema = value["input_parameters"]
    }
    var definition: ComposioValue { .object(["tool": .string(slug), "app": .string(toolkit), "name": .string(name), "arguments_schema": schema]) }
}
