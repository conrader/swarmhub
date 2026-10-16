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
    /// P48: the toolkit's `meta.logo`, https only; loaded only from `AppLogoLoader.hosts`.
    let logo: URL?
    init?(_ value: ComposioValue) {
        guard let slug = value["slug"].string, ComposioClient.validIdentifier(slug) else { return nil }
        id = slug; name = value["name"].string ?? slug; detail = value["meta"]["description"].string ?? ""
        logo = value["meta"]["logo"].string.flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }
    }
    /// Composio's public logo address (no key needed; the form its catalog page uses): the popular apps' logos before a key exists.
    static func publicLogo(_ slug: String) -> URL? { URL(string: "https://logos.composio.dev/api/\(slug)") }
    static func displayName(_ slug: String, catalog: [Self] = []) -> String {
        (catalog + popular).first { $0.id == slug }?.name ?? slug.replacingOccurrences(of: "_", with: " ").capitalized
    }
    /// Initial choices need no user key. The full catalog loads after the first connection is started.
    static let popular: [Self] = [
        ("gmail", "Gmail", "Email and drafts"), ("googlecalendar", "Google Calendar", "Events and calendars"),
        ("slack", "Slack", "Channels and messages"), ("googledrive", "Google Drive", "Files and documents"),
        ("notion", "Notion", "Pages and databases"), ("github", "GitHub", "Repositories and issues")
    ].compactMap { slug, name, detail in
        Self(.object(["slug": .string(slug), "name": .string(name), "meta": .object(["description": .string(detail), "logo": .string(publicLogo(slug)?.absoluteString ?? "")])]))
    }
}

struct ComposioAccount: Identifiable, Sendable, Equatable {
    let id: String; let toolkit: String; let status: String; let disabled: Bool
    /// P48: the account's alias at Composio (nil when it has none); `label` is what people and bots see.
    private(set) var alias: String?
    let connectedAt: Date?
    /// The alias, else "<App> account <n> · <connect date>" (`ComposioAccount.named`). Never Composio's random `word_id`.
    private(set) var label: String
    var isActive: Bool { status == "ACTIVE" && !disabled }
    var hasName: Bool { alias != nil }
    init?(_ value: ComposioValue) {
        guard let id = value["id"].string, let toolkit = value["toolkit"]["slug"].string,
              ComposioClient.validIdentifier(id), ComposioClient.validIdentifier(toolkit), let status = value["status"].string else { return nil }
        self.id = id; self.toolkit = toolkit; self.status = status; disabled = value["is_disabled"].bool ?? false
        alias = value["alias"].string.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        connectedAt = value["created_at"].string.flatMap(Self.date)
        label = alias ?? ComposioToolkit.displayName(toolkit) + " account"
        // Intentionally discard state/data and word_id: connected-account responses can contain credentials.
    }

    func withAlias(_ alias: String?) -> Self { var copy = self; copy.alias = alias; if let alias { copy.label = alias }; return copy }

    /// P48: labels for a whole list: an account without an alias is "<App> account <n>" (n by connect order within its
    /// app) with its connect date.
    static func named(_ accounts: [Self]) -> [Self] {
        let order = Dictionary(grouping: accounts, by: \.toolkit).mapValues { list in
            list.sorted { ($0.connectedAt ?? .distantFuture, $0.id) < ($1.connectedAt ?? .distantFuture, $1.id) }.map(\.id)
        }
        return accounts.map { account in
            guard account.alias == nil else { return account }
            var copy = account
            let n = (order[account.toolkit]?.firstIndex(of: account.id) ?? 0) + 1
            copy.label = "\(ComposioToolkit.displayName(account.toolkit)) account \(n)" + (account.connectedAt.map { " · " + dateText.string(from: $0) } ?? "")
            return copy
        }
    }

    private static func date(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter(); let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? plain.date(from: text)
    }
    nonisolated(unsafe) private static let dateText: DateFormatter = {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = .current
        formatter.dateFormat = "d MMM yyyy"; return formatter
    }()
}

struct ComposioTool: Sendable, Equatable {
    let slug: String; let toolkit: String; let name: String; let schema: ComposioValue
    /// P52: Composio's `tags` (strings only), read by `AppToolAccess`.
    let tags: [String]
    init?(_ value: ComposioValue) {
        guard let slug = value["slug"].string, let toolkit = value["toolkit"]["slug"].string,
              ComposioClient.validIdentifier(slug), !slug.hasPrefix("COMPOSIO_"), ComposioClient.validIdentifier(toolkit),
              value["input_parameters"].object != nil else { return nil }
        self.slug = slug; self.toolkit = toolkit; name = value["name"].string ?? slug; schema = value["input_parameters"]
        tags = (value["tags"].array ?? []).compactMap(\.string)
    }
    var definition: ComposioValue { .object(["tool": .string(slug), "app": .string(toolkit), "name": .string(name), "arguments_schema": schema]) }
}
