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
        var optionsStatus = 200
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
        if parts.first == "p", parts.count > 2 { parts.removeFirst(2) }
        let method = request.httpMethod ?? "GET", body = jsonBody(request)
        state.with { $0.log.append((method, url.path, body)) }
        switch (method, parts) {
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
            state.with { $0.sessionModels[path[2]] = model }
            send(200, ["runtime": ["model_lock": "accepted", "model": model, "provider": body?["provider"] as? String ?? ""]])
        case ("GET", ["api", "model", "options"]):
            let optionsStatus = state.with { $0.optionsStatus }
            guard optionsStatus == 200 else { return send(optionsStatus, ["error": "no route"]) }
            if let catalog = state.with({ $0.catalog }) { return send(200, catalog) }
            send(200, ["model": "model-a", "provider": "prov", "providers": [["slug": "prov", "name": "Prov", "models": ["model-a", "model-b"], "authenticated": true]]])
        case ("GET", ["api", "jobs"]): send(200, ["jobs": [["id": "job-1", "name": "Daily brief", "schedule": "0 8 * * *", "enabled": true]]])
        case ("POST", let path) where path.count == 4 && path[0...1] == ["v1", "runs"] && path[3] == "steer":
            guard state.with({ $0.features["run_steer"] == true }) else { return send(404, ["error": "no route"]) }
            state.markSteered(path[2])
            send(202, ["accepted": true])
        case ("POST", let path) where path.count == 5 && path[0...1] == ["api", "sessions"] && path[3...] == ["chat", "stream"]:
            stream(input: body?["input"] as? String ?? "", state: state)
        default: send(404, ["error": "no route"])
        }
    }

    /// "Count…" streams "1", then holds the run until it is steered (the ceiling only bounds a hang). Without `run_steer`
    /// no steer can come, so the count ends on its own after 5 s, ample time for the client to see "1" and try.
    /// Anything else answers its `exactly: E2E-…` token.
    private func stream(input: String, state: State) {
        let run = "run-\(UUID().uuidString.lowercased())"
        respond(200, contentType: "text/event-stream")
        client?.urlProtocol(self, didLoad: Self.event("run.started", ["run_id": run]))
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
