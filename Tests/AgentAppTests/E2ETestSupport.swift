import Foundation
@testable import AgentApp

/// Synthetic Hermes gateway for `--e2e`: native session chat over SSE (held open while counting so a steer can
/// land), steer, fork, model options/lock, session rows and jobs. Shapes follow `gateway/platforms/api_server.py`
/// (v2026.8.19). One state object per unique host, so parallel tests never share anything.
final class E2EServer: URLProtocol, @unchecked Sendable {
    final class State: @unchecked Sendable {
        let lock = NSLock()
        var features: [String: Bool]
        var log: [(method: String, path: String, body: [String: Any]?)] = []
        var sessionModels: [String: String] = [:]
        var steeredRuns: Set<String> = []
        /// P13: the lock answer (a refusal echoes the caller's bearer key), ids `POST /api/sessions` reports as
        /// existing (409), and a catalog replacing the one-supplier default.
        var lockStatus = 200
        var existingSessions: Set<String> = []
        var catalog: [String: Any]?
        /// P17: a catalog per profile (`/p/<profile>/`), else `catalog`.
        var catalogs: [String: [String: Any]] = [:]
        var optionsStatus = 200
        /// P13 Part C: the `runtime{}` the stream reports (`.full` names the session's locked pair, else the catalog
        /// default), and a model that replaces it to fake a turn that ran on something else.
        var runtimeShape: RuntimeShape = .full
        var runtimeModel: String?
        var sessionProviders: [String: String] = [:]
        /// `--check-server`: per-profile bearer keys (nil = no auth), the `/health` version, the `/v1/skills` status
        /// (500 is 0.21.7/0.22.0's enumeration bug), deleted session ids, and a DELETE that keeps the row.
        var keys: [String: String]?
        var version = "0.22.0"
        var skillsStatus = 200
        var deletedSessions: Set<String> = []
        var deleteKeepsSession = false
        var multiplex = true
        private let steerSignal = NSCondition()
        init(features: [String: Bool]) { self.features = features }
        func with<T>(_ body: (State) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(self) }
        func markSteered(_ run: String) { with { _ = $0.steeredRuns.insert(run) }; steerSignal.lock(); steerSignal.broadcast(); steerSignal.unlock() }
        /// Blocks until `run` is steered (woken by `markSteered`, no polling) or `deadline` passes.
        func waitForSteer(of run: String, until deadline: Date) -> Bool {
            steerSignal.lock(); defer { steerSignal.unlock() }
            while !with({ $0.steeredRuns.contains(run) }) {
                if !steerSignal.wait(until: deadline) { return with { $0.steeredRuns.contains(run) } }
            }
            return true
        }
        func requests() -> [(method: String, path: String, body: [String: Any]?)] { with { $0.log } }
    }
    enum RuntimeShape { case full, empty, absent, wrongTypes }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var states: [String: State] = [:]

    static let allFeatures: [String: Bool] = ["session_chat_streaming": true, "run_steer": true, "session_fork": true, "model_options": true,
                                              "session_model_lock": true, "skills_api": false, "jobs": true]

    static func serve(features: [String: Bool] = allFeatures) -> (host: String, state: State, session: URLSession) {
        let host = "e2e-\(UUID().uuidString.lowercased()).test"
        let state = State(features: features)
        lock.lock(); states[host] = state; lock.unlock()
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [E2EServer.self]
        return (host, state, URLSession(configuration: configuration))
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.lock.lock(); let state = Self.states[request.url?.host ?? ""]; Self.lock.unlock()
        guard let state, let url = request.url else { return send(404, ["error": "no route"]) }
        var parts = url.path.split(separator: "/").map(String.init)
        let profile = parts.first == "p" && parts.count > 2 ? parts[1] : "default"
        if parts.first == "p", parts.count > 2 { parts.removeFirst(2) }
        let method = request.httpMethod ?? "GET", body = jsonBody(request)
        state.with { $0.log.append((method, url.path, body)) }
        if parts != ["health"], let keys = state.with({ $0.keys }), request.value(forHTTPHeaderField: "Authorization") != "Bearer \(keys[profile] ?? "-")" {
            return send(401, ["error": ["message": "Invalid API key", "code": "invalid_api_key"]])
        }
        switch (method, parts) {
        case ("GET", ["health"]): send(200, ["status": "ok", "platform": "hermes-agent", "version": state.with { $0.version }])
        case ("GET", ["v1", "models"]): send(200, ["object": "list", "data": [["id": profile == "default" || !state.with({ $0.multiplex }) ? "hermes-agent" : profile, "object": "model"]]])
        case ("GET", ["v1", "skills"]):
            let status = state.with { $0.skillsStatus }
            guard status == 200 else { return send(status, ["error": ["message": "Failed to enumerate skills", "code": "skills_error"]]) }
            send(200, ["data": [["name": "notes", "description": "Take notes"]]])
        case ("GET", ["v1", "toolsets"]): send(200, ["data": [["name": "web", "enabled": true, "tools": ["web_search"]], ["name": "files", "enabled": false]]])
        case ("GET", ["api", "sessions"]): send(200, ["object": "list", "data": [["id": "s-1", "title": "One"]]])
        case ("DELETE", let path) where path.count == 3 && path[0...1] == ["api", "sessions"]:
            state.with { if !$0.deleteKeepsSession { $0.deletedSessions.insert(path[2]) } }
            send(200, ["object": "hermes.session.deleted", "id": path[2], "deleted": true])
        case ("GET", let path) where path.count == 3 && path[0...1] == ["api", "sessions"] && state.with({ $0.deletedSessions.contains(path[2]) }):
            send(404, ["error": ["message": "Session not found", "code": "session_not_found"]])
        case ("GET", ["v1", "capabilities"]): send(200, ["features": state.with { $0.features }, "model": "hermes-agent"])
        case ("POST", ["api", "sessions"]):
            let id = body?["id"] as? String ?? UUID().uuidString
            guard !state.with({ $0.existingSessions.contains(id) }) else { return send(409, ["error": ["message": "Session already exists", "code": "session_exists"]]) }
            send(201, ["session": ["id": id]])
        case ("GET", let path) where path.count == 4 && path[0...1] == ["api", "sessions"] && path[3] == "messages": send(200, ["data": []])
        case ("GET", let path) where path.count == 3 && path[0...1] == ["api", "sessions"]:
            send(200, ["session": ["id": path[2], "model": state.with { $0.sessionModels[path[2]] } ?? "hermes-agent"]])
        case ("POST", let path) where path.count == 4 && path[0...1] == ["api", "sessions"] && path[3] == "fork":
            guard state.with({ $0.features["session_fork"] == true }) else { return send(404, ["error": "no route"]) }
            send(200, ["session": ["id": body?["id"] as? String ?? "fork"]])
        case ("POST", let path) where path.count == 4 && path[0...1] == ["api", "sessions"] && path[3] == "model":
            let model = body?["model"] as? String ?? "", status = state.with { $0.lockStatus }
            guard status == 200 else {
                return send(status, ["error": ["message": "cannot route for \(request.value(forHTTPHeaderField: "Authorization") ?? "")", "code": "model_lock_unavailable"]])
            }
            state.with { $0.sessionModels[path[2]] = model; $0.sessionProviders[path[2]] = body?["provider"] as? String ?? "" }
            send(200, ["runtime": ["model_lock": "accepted", "model": model, "provider": body?["provider"] as? String ?? ""]])
        case ("GET", ["api", "model", "options"]):
            let optionsStatus = state.with { $0.optionsStatus }
            guard optionsStatus == 200 else { return send(optionsStatus, ["error": "no route"]) }
            if let catalog = state.with({ $0.catalogs[profile] ?? $0.catalog }) { return send(200, catalog) }
            send(200, ["model": "model-a", "provider": "prov", "providers": [["slug": "prov", "name": "Prov", "models": ["model-a", "model-b"], "authenticated": true]]])
        case ("GET", ["api", "jobs"]): send(200, ["jobs": [["id": "job-1", "name": "Daily brief", "schedule": "0 8 * * *", "enabled": true]]])
        case ("POST", let path) where path.count == 4 && path[0...1] == ["v1", "runs"] && path[3] == "steer":
            guard state.with({ $0.features["run_steer"] == true }) else { return send(404, ["error": "no route"]) }
            state.markSteered(path[2])
            send(202, ["accepted": true])
        case ("POST", let path) where path.count == 5 && path[0...1] == ["api", "sessions"] && path[3...] == ["chat", "stream"]:
            stream(input: body?["input"] as? String ?? "", runtime: Self.runtime(session: path[2], state: state), state: state)
        default: send(404, ["error": "no route"])
        }
    }

    /// "Count…" streams "1", then holds the run until it is steered (the ceiling only bounds a hang). Without `run_steer`
    /// no steer can come, so the count ends on its own after 5 s, ample time for the client to see "1" and try.
    /// Anything else answers its `exactly: E2E-…` token.
    /// `{provider, model, route_source, requested, model_lock}` as `run.started` carries it (both versions).
    private static func runtime(session: String, state: State) -> [String: Any]? {
        state.with { state in
            let catalog = state.catalog ?? ["model": "model-a", "provider": "prov"]
            let model = state.runtimeModel ?? state.sessionModels[session] ?? catalog["model"] as? String ?? ""
            let provider = state.sessionProviders[session] ?? catalog["provider"] as? String ?? ""
            switch state.runtimeShape {
            case .full: return ["provider": provider, "model": model, "route_source": state.sessionModels[session] == nil ? "default" : "session_lock",
                                "requested": NSNull(), "model_lock": state.sessionModels[session] == nil ? "none" : "accepted"]
            case .empty: return [:]
            case .absent: return nil
            case .wrongTypes: return ["provider": 7, "model": ["id": model]]
            }
        }
    }

    private func stream(input: String, runtime: [String: Any]?, state: State) {
        let run = "run-\(UUID().uuidString.lowercased())"
        respond(200, contentType: "text/event-stream")
        var started: [String: Any] = ["run_id": run]; started["runtime"] = runtime
        client?.urlProtocol(self, didLoad: Self.event("run.started", started))
        guard input.contains("Count slowly") else {
            let token = input.range(of: #"E2E-[A-Z]+"#, options: .regularExpression).map { String(input[$0]) } ?? "?"
            client?.urlProtocol(self, didLoad: Self.event("assistant.delta", ["run_id": run, "delta": token]) + Self.event("run.completed", ["run_id": run]))
            client?.urlProtocolDidFinishLoading(self); return
        }
        client?.urlProtocol(self, didLoad: Self.event("assistant.delta", ["run_id": run, "delta": "1\n"]))
        DispatchQueue.global().async { [self] in
            let canSteer = state.with { $0.features["run_steer"] == true }
            let hold = canSteer ? Double(waitCeiling.components.seconds) : 5
            let steered = state.waitForSteer(of: run, until: Date(timeIntervalSinceNow: hold))
            client?.urlProtocol(self, didLoad: Self.event("assistant.delta", ["run_id": run, "delta": steered ? "E2E-STEER" : "2\n3"]) + Self.event("run.completed", ["run_id": run]))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    private static func event(_ name: String, _ payload: [String: Any]) -> Data {
        Data("event: \(name)\ndata: \(String(data: try! JSONSerialization.data(withJSONObject: payload), encoding: .utf8)!)\n\n".utf8)
    }
    private func respond(_ status: Int, contentType: String) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": contentType])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }
    private func send(_ status: Int, _ object: Any) {
        respond(status, contentType: "application/json")
        client?.urlProtocol(self, didLoad: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// A store whose real `HermesBackend`s talk to `E2EServer`, holding Jarvis, DMT and Achilles on `grok-*` profiles.
@MainActor func e2eStore(features: [String: Bool] = E2EServer.allFeatures) -> (store: AppStore, bots: HeadlessE2E.Participants, state: E2EServer.State) {
    let server = E2EServer.serve(features: features)
    let defaults = isolatedDefaults(); defaults.set("https://\(server.host)", forKey: "hermesBaseURL")
    let keys = InMemoryKeyStore(["hermes": "k", "hermes.grok-jarvis": "k", "hermes.grok-dmt": "k", "hermes.grok-achilles": "k"])
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: keys, defaults: defaults, hermesSession: server.session)
    let bots = HeadlessE2E.Participants(jarvis: Bot(name: "Jarvis \(AppConstants.selfTestPrefix)test", backend: .hermes, hermesProfile: "grok-jarvis"),
                                        dmt: Bot(name: "DMT", backend: .hermes, hermesProfile: "grok-dmt"),
                                        achilles: Bot(name: "Achilles", backend: .hermes, hermesProfile: "grok-achilles"))
    store.bots = [bots.jarvis, bots.dmt, bots.achilles]; store.groups = []
    return (store, bots, server.state)
}

extension HeadlessE2E.Timing {
    static let fast = HeadlessE2E.Timing(turn: waitCeiling, steerStart: waitCeiling, request: waitCeiling, poll: .milliseconds(10))
}
