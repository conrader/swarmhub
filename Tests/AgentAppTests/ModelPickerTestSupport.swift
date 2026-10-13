import Foundation
@testable import AgentApp

// Synthetic `/api/model/options` payloads shaped like Hermes `build_model_options_payload` (v2026.8.19 = 0.20.5 and
// v0.21.7): supplier rows with `slug`, `name`, `is_current`, `models`, `authenticated`, `source`, `aliases`, plus the
// keys Torvli must never read (`key_env`, `auth_type`, `api_url`, `warning`, `usage`, `pricing`), which carry sentinels.

enum CatalogShape: CaseIterable, Sendable { case v0205, v0217 }

let catalogSentinels = ["SENTINEL-KEYENV-41", "SENTINEL-AUTHTYPE-41", "https://sentinel-api-41.invalid/v1", "SENTINEL-WARNING-41", "SENTINEL-USAGE-41", "SENTINEL-PRICING-41"]
/// Names used only by these fixtures; none may appear in `Sources/`.
let catalogFixtureNames = ["lab-one", "Lab One", "lab-two", "lab-paid", "Relay Router", "relay/model-", "model-alpha", "model-beta", "preset-box", "box-local", "lab-solo", "solo-model"]

private func withSentinels(_ row: [String: Any]) -> [String: Any] {
    row.merging([
        "key_env": catalogSentinels[0], "auth_type": catalogSentinels[1], "api_url": catalogSentinels[2], "warning": catalogSentinels[3],
        "usage": ["windows": [["label": catalogSentinels[4], "used_percent": 12.5, "resets_at": NSNull(), "scope": "account"]]],
        "pricing": ["model-alpha": ["prompt": catalogSentinels[5]]], "is_user_defined": false, "total_models": 3,
    ] as [String: Any]) { mine, _ in mine }
}

func routerModels(_ count: Int) -> [String] { (1...count).map { "relay/model-\($0)" } }

/// Server order puts the default supplier second, so "default first" is the client's doing.
func catalogPayload(_ shape: CatalogShape, defaultSignedOut: Bool = false) -> [String: Any] {
    var rows: [[String: Any]] = [
        withSentinels(["slug": "router", "name": "  Relay Router  ", "is_current": false, "models": routerModels(20), "source": "hermes", "authenticated": true]),
        withSentinels(["slug": "lab-one", "name": "Lab One", "is_current": true, "source": "built-in", "authenticated": true, "aliases": ["lab-1"],
                       "models": ["model-alpha", ["id": "model-beta"], ["name": "model-gamma"], "model-alpha", "", "   ", String(repeating: "x", count: 201), "bad\u{7}id", 42] as [Any]]),
        withSentinels(["slug": "preset-box", "name": "Box Preset", "is_current": false, "models": ["preset-one"], "source": "virtual", "authenticated": true]),
        withSentinels(["slug": "lab-paid", "name": "Lab Paid", "is_current": false, "models": ["paid-a", "free-b"], "source": "hermes", "authenticated": true, "unavailable_models": ["paid-a"]]),
        withSentinels(["slug": "lab-two", "name": "Lab Two", "is_current": false, "models": [String](), "source": "canonical", "authenticated": false]),
        ["slug": "lab-three", "name": "Lab Three", "is_current": false, "models": [String](), "source": "canonical", "authenticated": false],
    ]
    if shape == .v0217 {
        rows[0]["limit"] = ["scope": "models", "models": ["relay/model-2": "2026-10-13T12:30:00.123456+00:00", "relay/model-3": "not a time"]]
        rows[3]["free_tier_pending"] = true
        rows.append(withSentinels(["slug": "box-local", "name": "Box Local", "is_current": false, "models": ["local-one"], "source": "local-runtime", "authenticated": true,
                                   "limit": ["scope": "account", "resets_at": "2026-10-13T12:30:00"]]))
        rows.append(withSentinels(["slug": "lab-odd", "name": "Lab Odd", "is_current": false, "models": ["odd-one"], "source": "hermes", "authenticated": true, "limit": ["scope": "galaxy"]]))
    }
    if defaultSignedOut {
        // 0.21.x `_append_unconfigured_rows`: the configured default lost its login and keeps only the saved model.
        rows[1] = withSentinels(["slug": "lab-one", "name": "Lab One", "is_current": true, "models": ["model-alpha"], "total_models": 1, "source": "configured-current", "authenticated": false])
    }
    return ["model": "model-alpha", "provider": "lab-one", "providers": rows]
}

func soloCatalogPayload() -> [String: Any] {
    ["model": "solo-model", "provider": "lab-solo", "providers": [withSentinels(["slug": "lab-solo", "name": "Lab Solo", "is_current": true, "models": ["solo-model", "solo-mini"], "source": "built-in", "authenticated": true])]]
}

func pickerCapabilities(modelOptions: Bool = true, modelLock: Bool = true) -> [String: Any] {
    ["object": "hermes.api_server.capabilities", "platform": "hermes-agent", "model": "hermes-agent",
     "features": ["session_resources": true, "model_options": modelOptions, "session_model_lock": modelLock, "skills_api": true, "session_chat_streaming": true],
     "endpoints": ["model_options": ["method": "GET", "path": "/api/model/options"], "skills": ["method": "GET", "path": "/v1/skills"],
                   "toolsets": ["method": "GET", "path": "/v1/toolsets"], "session_model_lock": ["method": "POST", "path": "/api/sessions/{session_id}/model"]]]
}

/// A multiplexed box serving each profile its own catalog. A lock writes the session row's model, as
/// `SessionDB.update_session_runtime_lock` does. Tests change the fields between requests.
final class PickerServer: @unchecked Sendable {
    private let lock = NSLock()
    private var _catalogs: [String: [String: Any]]
    private var _sessionModels: [String: String] = [:]
    private var _statuses: [String: Int] = [:]
    private var _capabilities: [String: Any]? = pickerCapabilities()
    let keys: [String: String]

    init(catalogs: [String: [String: Any]], keys: [String: String]) { _catalogs = catalogs; self.keys = keys }

    func set(catalog: [String: Any], for profile: String) { lock.withLock { _catalogs[profile] = catalog } }
    func set(sessionModel: String, profile: String, session: String) { lock.withLock { _sessionModels["\(profile)/\(session)"] = sessionModel } }
    /// Status override for a path suffix such as `/api/model/options` or `/api/sessions/s1`.
    func set(status: Int?, for suffix: String) { lock.withLock { _statuses[suffix] = status } }
    func set(capabilities: [String: Any]?) { lock.withLock { _capabilities = capabilities } }

    var handler: MockHermesProtocol.Handler {
        { [self] request in
            let parts = request.url!.path.split(separator: "/").map(String.init)
            guard parts.count >= 3, parts[0] == "p" else { return (404, ["error": "no route"]) }
            let profile = parts[1], suffix = "/" + parts.dropFirst(2).joined(separator: "/")
            guard request.value(forHTTPHeaderField: "Authorization") == "Bearer \(keys[profile] ?? "-")" else { return (401, ["error": ["message": "bad key"]]) }
            let override: Int? = lock.withLock { _statuses[suffix] }
            if let override {
                return (override, ["error": ["message": "upstream failed for Bearer \(keys[profile] ?? "")", "code": "boom"]])
            }
            switch (request.httpMethod ?? "GET", suffix) {
            case ("GET", "/v1/capabilities"):
                let capabilities: [String: Any]? = lock.withLock { _capabilities }
                return capabilities.map { (200, $0) } ?? (404, ["error": "no route"])
            case ("GET", "/v1/skills"): return (200, ["object": "list", "data": [["name": "notes", "description": "Synthetic", "category": "x"]]])
            case ("GET", "/v1/toolsets"): return (200, ["object": "list", "data": [["name": "web", "label": "Web", "enabled": true]]])
            case ("GET", "/api/model/options"):
                let catalog: [String: Any]? = lock.withLock { _catalogs[profile] }
                return catalog.map { (200, $0) } ?? (500, ["error": ["message": "Failed to list model options."]])
            case ("POST", let path) where parts.count == 6 && path.hasSuffix("/model"):
                let body = (try? JSONSerialization.jsonObject(with: pickerRequestBody(request))) as? [String: Any] ?? [:]
                let model = body["model"] as? String ?? "", provider = body["provider"] as? String ?? ""
                lock.withLock { _sessionModels["\(profile)/\(parts[4])"] = model }
                return (200, ["object": "hermes.session.model_lock", "session_id": parts[4],
                              "runtime": ["provider": provider, "model": model, "route_source": "raw_request", "model_lock": "accepted"]])
            case ("GET", let path) where parts.count == 5 && path.hasPrefix("/api/sessions/"):
                let model: String = lock.withLock { _sessionModels["\(profile)/\(parts[4])"] } ?? profile
                return (200, ["object": "hermes.session", "session": ["id": parts[4], "model": model]])
            default: return (404, ["error": "no route"])
            }
        }
    }
}

func pickerRequestBody(_ request: URLRequest) -> Data {
    var data = request.httpBody ?? Data()
    if data.isEmpty, let stream = request.httpBodyStream {
        stream.open(); defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(buffer, count: count) }
    }
    return data
}

/// Jarvis on `grok-jarvis` (session s1) and Rapper on `grok-rapper` (session r1), each with its own key.
@MainActor func pickerStore(_ server: PickerServer, jarvisSession: String? = "s1") -> (store: AppStore, jarvis: Bot, rapper: Bot, host: String, storeURL: URL) {
    let (host, session) = MockHermesProtocol.serve(server.handler)
    let defaults = isolatedDefaults(); defaults.set("https://\(host)/v1", forKey: "hermesBaseURL")
    var keys = ["hermes": "default-key"]
    for (profile, key) in server.keys { keys["hermes.\(profile)"] = key }
    let url = temporaryStore()
    let store = AppStore(storeURL: url, autoConfigureHermes: false, keyStore: InMemoryKeyStore(keys), defaults: defaults, hermesSession: session)
    let jarvis = Bot(name: "Jarvis", backend: .hermes, hermesProfile: "grok-jarvis", hermesSessionID: jarvisSession)
    let rapper = Bot(name: "Rapper", backend: .hermes, hermesProfile: "grok-rapper", hermesSessionID: "r1")
    store.bots = [jarvis, rapper]
    return (store, jarvis, rapper, host, url)
}

func pickerServer(_ shape: CatalogShape = .v0205) -> PickerServer {
    PickerServer(catalogs: ["grok-jarvis": catalogPayload(shape), "grok-rapper": soloCatalogPayload()],
                 keys: ["grok-jarvis": "jarvis-key-77", "grok-rapper": "rapper-key-88"])
}
