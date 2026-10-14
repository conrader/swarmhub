import Foundation

/// What `/v1/capabilities` advertises. Features are picked by flag and endpoint presence, never by version.
struct HermesCapabilities: Sendable, Equatable {
    var features: [String: Bool] = [:]
    var endpoints: Set<String> = []
    /// The virtual model alias the gateway advertises (e.g. `hermes-agent`, or the profile name when multiplexed).
    var model: String?

    /// A flag set to `false` turns the feature off. Without the flag, a listed endpoint (or no endpoint list at
    /// all) means "try it"; the caller still hides the feature when the route 404s.
    func supports(_ flag: String, endpoint: String) -> Bool {
        if let value = features[flag] { return value }
        return endpoints.isEmpty || endpoints.contains(endpoint)
    }
    var skills: Bool { supports("skills_api", endpoint: "skills") }
    /// `/v1/toolsets` has no flag of its own; it ships alongside `skills_api` and is listed under `endpoints`.
    var toolsets: Bool { endpoints.isEmpty ? features["skills_api"] != false : endpoints.contains("toolsets") }
    var modelOptions: Bool { supports("model_options", endpoint: "model_options") }
    var sessionModelLock: Bool { supports("session_model_lock", endpoint: "session_model_lock") }

    static func parse(_ json: [String: Any]) -> HermesCapabilities {
        let features = (json["features"] as? [String: Any] ?? [:]).compactMapValues { $0 as? Bool }
        let endpoints = Set((json["endpoints"] as? [String: Any] ?? [:]).keys)
        return .init(features: features, endpoints: endpoints, model: json["model"] as? String)
    }
}

struct HermesSkill: Sendable, Equatable, Identifiable {
    var id: String { name }
    let name: String; let description: String; let category: String?
    /// P27: a `version` when the server lists one (stock 0.20–0.22 do not).
    var version: String? = nil

    static func parseList(_ json: [String: Any]) -> [HermesSkill] {
        ((json["data"] as? [[String: Any]]) ?? []).compactMap { row in
            guard let name = (row["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
            let category = (row["category"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let version = (row["version"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return .init(name: name, description: oneLine(row["description"] as? String ?? ""), category: category, version: version)
        }
    }

    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }
}

struct HermesToolset: Sendable, Equatable, Identifiable {
    var id: String { name }
    let name: String; let label: String; let description: String
    let enabled: Bool?; let configured: Bool?; let tools: [String]

    static func parseList(_ json: [String: Any]) -> [HermesToolset] {
        ((json["data"] as? [[String: Any]]) ?? []).compactMap { row in
            guard let name = row["name"] as? String, !name.isEmpty else { return nil }
            let label = (row["label"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? name
            return .init(name: name, label: label, description: HermesSkill.oneLine(row["description"] as? String ?? ""),
                         enabled: row["enabled"] as? Bool, configured: row["configured"] as? Bool, tools: row["tools"] as? [String] ?? [])
        }
    }
}

/// Who pinned a chat (P13); nil = picked by hand or before P13.
/// `torvliDefault` keeps its pre-P18 name: it is the stored raw value (store format unchanged); it means the app-wide default.
enum LockOrigin: String, Codable, Sendable { case bot, torvliDefault, coding }

/// A chat's confirmed model lock as acknowledged by `POST /api/sessions/{id}/model`.
struct HermesModelLock: Codable, Sendable, Equatable {
    let sessionID: String; let provider: String; let model: String
    var origin: LockOrigin? = nil
    enum CodingKeys: CodingKey { case sessionID, provider, model, origin }
    init(sessionID: String, provider: String, model: String, origin: LockOrigin? = nil) { self.sessionID = sessionID; self.provider = provider; self.model = model; self.origin = origin }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try c.decode(String.self, forKey: .sessionID); provider = try c.decode(String.self, forKey: .provider); model = try c.decode(String.self, forKey: .model)
        origin = (try? c.decodeIfPresent(LockOrigin.self, forKey: .origin)) ?? nil
    }
}

extension HermesBackend {
    /// `nil` when the server has no `/v1/capabilities` (old gateway): every optional feature is then hidden.
    func capabilities() async throws -> HermesCapabilities? {
        do { return HermesCapabilities.parse(try await capabilitiesJSON()) }
        catch BackendError.http(404, _) { return nil }
    }

    /// The `version` `/health` reports through this connection (profile-prefixed, as nginx forwards only `/p/<profile>/`);
    /// `/health/detailed` when `/health` is absent.
    func hermesVersion() async -> HermesVersionReading {
        do {
            let json: [String: Any]
            do { json = try await jsonRequest(path: "health", timeout: 10) }
            catch BackendError.http(404, _) { json = try await jsonRequest(path: "health/detailed", timeout: 10) }
            guard let raw = json["version"] as? String else { return .init(raw: nil, problem: "/health reports no version.") }
            return .init(raw: raw)
        } catch {
            return .init(raw: nil, problem: BotInfoCache.describe(error, key: apiKey))
        }
    }

    func skills() async throws -> [HermesSkill] { HermesSkill.parseList(try await jsonRequest(path: "v1/skills")) }
    func toolsets() async throws -> [HermesToolset] { HermesToolset.parseList(try await jsonRequest(path: "v1/toolsets")) }
    func modelOptions() async throws -> HermesModelOptions { HermesModelOptions.parse(try await jsonRequest(path: "api/model/options")) }

    /// The `model` stored on the session row (`GET /api/sessions/{id}` → `session.model`).
    func sessionModel(sessionID: String) async throws -> String? {
        let json = try await jsonRequest(path: "api/sessions/\(Self.escapedPath(sessionID))")
        return ((json["session"] as? [String: Any])?["model"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Locks the session to `provider`/`model`. The body carries ids only — the server resolves credentials from its
    /// own config. Hermes forces `require_model_lock`, answers 409 when the pair cannot be routed (it refuses a silent
    /// fallback to the global default) and 400 when neither is given.
    func lockSessionModel(sessionID: String, provider: String, model: String) async throws -> HermesModelLock {
        let json = try await jsonRequest(path: "api/sessions/\(Self.escapedPath(sessionID))/model", method: "POST", body: Self.modelLockBody(provider: provider, model: model))
        let runtime = json["runtime"] as? [String: Any] ?? [:]
        guard (runtime["model_lock"] as? String ?? "accepted") == "accepted" else { throw BackendError.unavailable("Hermes did not accept the model change.") }
        let acceptedModel = (runtime["model"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? model
        let acceptedProvider = (runtime["provider"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? provider
        return .init(sessionID: sessionID, provider: acceptedProvider, model: acceptedModel)
    }

    static func modelLockBody(provider: String, model: String) -> [String: Any] {
        var body: [String: Any] = ["model": model]
        if !provider.isEmpty { body["provider"] = provider }
        return body
    }

    static func escapedPath(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? value
    }
}
