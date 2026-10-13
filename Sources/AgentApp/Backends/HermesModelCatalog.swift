import Foundation

/// When a supplier's credential pool is rate-limited (0.21.x `limit`). A time is kept only when it parses.
enum HermesModelLimit: Sendable, Equatable {
    case account(resetsAt: Date?)
    case models([String: Date?])

    /// `{scope:"account", resets_at}` or `{scope:"models", models:{id: iso}}`; any other shape is no state.
    static func parse(_ value: Any?) -> HermesModelLimit? {
        guard let object = value as? [String: Any], let scope = object["scope"] as? String else { return nil }
        switch scope {
        case "account": return .account(resetsAt: (object["resets_at"] as? String).flatMap(HermesModelCatalog.date))
        case "models":
            guard let models = object["models"] as? [String: Any] else { return nil }
            var result: [String: Date?] = [:]
            for (id, value) in models where HermesModelCatalog.isUsableID(id) { result[id] = .some((value as? String).flatMap(HermesModelCatalog.date)) }
            return result.isEmpty ? nil : .models(result)
        default: return nil
        }
    }
}

/// One supplier row of `GET /api/model/options`. Only allowlisted keys are read; credential hints, endpoints,
/// warnings, usage and pricing never enter this type. Deliberately not `Codable`.
struct HermesModelProvider: Sendable, Equatable, Identifiable {
    var id: String { slug }
    let slug: String; let name: String; let models: [String]; let isCurrent: Bool
    /// `false` for catalogue rows the box has no credentials for.
    let authenticated: Bool?
    var source: String? = nil
    var aliases: [String] = []
    var unavailableModels: Set<String> = []
    var freeTierPending = false
    var limit: HermesModelLimit? = nil

    /// A setup skeleton: no credentials and nothing to offer. A signed-out default (`configured-current`) is not one.
    var isSkeleton: Bool { authenticated == false && models.isEmpty && source != "configured-current" }
    /// The box still lists this supplier but its login is gone.
    var isSignedOut: Bool { source == "configured-current" || (authenticated == false && !models.isEmpty) }

    func answers(to provider: String) -> Bool {
        let wanted = provider.lowercased()
        return slug.lowercased() == wanted || aliases.contains { $0.lowercased() == wanted }
    }
}

struct HermesModelOptions: Sendable, Equatable {
    let providers: [HermesModelProvider]
    /// The profile's configured default.
    let model: String?; let provider: String?

    /// Providers a chat can actually be switched to (credentials present, at least one model).
    var selectable: [HermesModelProvider] { providers.filter { $0.authenticated != false && !$0.models.isEmpty } }

    /// The profile's default supplier: `is_current`, else the row whose slug or alias is the top-level `provider`.
    var defaultProvider: HermesModelProvider? {
        providers.first { $0.isCurrent } ?? provider.flatMap { wanted in providers.first { $0.answers(to: wanted) } }
    }

    static func parse(_ json: [String: Any]) -> HermesModelOptions {
        let rows = (json["providers"] as? [[String: Any]]) ?? []
        let providers: [HermesModelProvider] = rows.compactMap { row in
            guard let slug = HermesModelCatalog.id(row["slug"]) else { return nil }
            let name = HermesModelCatalog.label(row["name"]) ?? slug
            let models = HermesModelCatalog.ids((row["models"] as? [Any]) ?? []) { item in
                guard let object = item as? [String: Any] else { return nil }
                return (object["id"] ?? object["name"]) as? String
            }
            return .init(slug: slug, name: name, models: models, isCurrent: row["is_current"] as? Bool ?? false,
                         authenticated: row["authenticated"] as? Bool, source: HermesModelCatalog.id(row["source"]),
                         aliases: HermesModelCatalog.ids((row["aliases"] as? [Any]) ?? []),
                         unavailableModels: Set(HermesModelCatalog.ids((row["unavailable_models"] as? [Any]) ?? [])),
                         freeTierPending: row["free_tier_pending"] as? Bool ?? false, limit: HermesModelLimit.parse(row["limit"]))
        }
        return .init(providers: providers, model: HermesModelCatalog.id(json["model"]), provider: HermesModelCatalog.id(json["provider"]))
    }

    /// Model ids compare equal when one is the other with a vendor prefix (`vendor/model` vs `model`).
    static func sameModel(_ a: String, _ b: String) -> Bool { a == b || a.hasSuffix("/" + b) || b.hasSuffix("/" + a) }
}

enum HermesModelCatalog {
    static let maxIDLength = 200
    static let maxNameLength = 80

    static func isUsableID(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.count <= maxIDLength
            && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    static func id(_ value: Any?) -> String? { (value as? String).flatMap { isUsableID($0) ? $0 : nil } }

    /// Strings (or objects via `object`) that pass `isUsableID`, de-duplicated in order.
    static func ids(_ items: [Any], object: (Any) -> String? = { _ in nil }) -> [String] {
        var seen: Set<String> = [], result: [String] = []
        for item in items {
            guard let value = (item as? String) ?? object(item), isUsableID(value), seen.insert(value).inserted else { continue }
            result.append(value)
        }
        return result
    }

    static func label(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        let clean = String(String.UnicodeScalarView(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
        return clean.isEmpty ? nil : String(clean.prefix(maxNameLength))
    }

    /// Python `isoformat()`: fractional seconds dropped, offset optional, naive means UTC. Anything else is nil.
    static func date(_ text: String) -> Date? {
        let pattern = #"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(\.\d+)?(Z|[+-]\d{2}:\d{2})?$"#
        guard let match = text.range(of: pattern, options: .regularExpression), match == text.startIndex..<text.endIndex else { return nil }
        let base = String(text.prefix(19))
        let rest = text.dropFirst(19).drop { $0 == "." || $0.isNumber }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: base + (rest.isEmpty ? "Z" : String(rest)))
    }
}
