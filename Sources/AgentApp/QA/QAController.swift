#if DEBUG
import AppKit
import Combine
import Foundation

@MainActor final class QAController: ObservableObject {
    struct Scope {
        let id: String; let run: String; let scenario: String; let resource: String; let bot: Bot; let started: Date
        var turns = 0; var actions = 0; var busy = false; var closed = false
        var approvalDenied = false
        var intents: [String: ComposioValue] = [:]; var acknowledged: Set<String> = []
    }
    let store: AppStore
    let directory: URL
    let recorder: QARecorder
    @Published var status = "Waiting for a sandboxed real Hermes QA gateway"
    private var server: QALocalServer?
    private var scopes: [String: Scope] = [:]
    private var leases: [String: ComposioValue] = [:]
    private var issuedLeases: Set<String> = []
    private var runs: [String: (started: Date, turns: Int, actions: Int)] = [:]
    private var capabilities: Set<String> = []
    private var handling: Set<String> = []
    private var sinkRegistration: ComposioValue?
    private var receivedText: [UUID: String] = [:]
    private let transport: @Sendable (ComposioValue) async throws -> ComposioValue

    init(directory: URL, transport: @escaping @Sendable (ComposioValue) async throws -> ComposioValue = { try await QAMode.boundary.control($0) }) throws {
        self.directory = directory
        self.transport = transport
        recorder = try QARecorder(directory: directory)
        let defaults = UserDefaults(suiteName: directory.appending(path: "preferences").path)!
        // No shared key vault, discovery, migration, automation ticker, production connected apps, or launch work.
        store = AppStore(storeURL: directory.appending(path: "store.json"), autoConfigureHermes: false,
                         keyStore: QAKeyStore(), defaults: defaults)
        store.sessionNamespace = "QA-"
        store.qaEventRecorder = { [weak self] id, event in
            switch event {
            case .token(let text): self?.receivedText[id, default: ""] += text
            case .replace(let text): self?.receivedText[id] = text
            default: break
            }
        }
    }
    func start() throws {
        let token = try QAMode.secret()
        try QAMode.writePrivate(Data(token.utf8), to: directory.appending(path: "token"))
        let server = try QALocalServer(token: token) { [weak self] route, body in
            guard let self else { throw QAError.blocked }; return try await self.handle(route, body)
        }
        self.server = server
        server.start { [weak self] port in
            guard let self else { return }
            let descriptor: ComposioValue = .object(["schema": .string(QAPolicy.schema), "port": .number(Double(port)),
                "token_file": .string(self.directory.appending(path: "token").path), "data_directory": .string(self.directory.path)])
            try QAMode.writePrivate(try JSONEncoder().encode(descriptor), to: self.directory.appending(path: "endpoint.json"))
            self.sinkRegistration = .object(["host": .string("127.0.0.1"), "port": .number(Double(port)),
                "token": .string(token), "route": .string("/qa/v1/record")])
            print("QA endpoint descriptor: \(self.directory.appending(path: "endpoint.json").path)")
            self.status = "QA TEST MODE · 127.0.0.1:\(port) · isolated data: \(self.directory.path)"
        }
    }
    private func remote(_ route: String, _ body: ComposioValue) async throws -> ComposioValue {
        var object = body.object ?? [:]
        object["route"] = .string(route); object["test_mode"] = .bool(true)
        return try await transport(.object(object))
    }
    private func journal(_ value: ComposioValue) throws {
        // Immutable, fsynced acceptance records. Uncertain IDs are never executed again.
        try QAMode.writePrivate(try JSONEncoder().encode(value), to: directory.appending(path: "intent-\(UUID().uuidString).json"))
    }
    func handle(_ route: String, _ body: ComposioValue) async throws -> ComposioValue {
        if route == "attest" {
            try QAPolicy.fields(body, allowed: ["schema", "nonce"], required: ["schema", "nonce"])
            guard body["schema"] == .string(QAPolicy.schema), let nonce = body["nonce"].string, QAPolicy.identifier(nonce.replacingOccurrences(of: "_", with: "-")) else { throw QAError.refused }
            // Never claim safety from a prompt, a local flag, or an ordinary /v1/capabilities response.
            var request = body.object!
            // Registration crosses only the authenticated local QA gateway; it is never journaled or returned.
            if let sinkRegistration { request["recorder"] = sinkRegistration }
            let value = try await remote("attest", .object(request))
            try QAPolicy.attestation(value, nonce: nonce)
            guard let lease = value["lease"].string, issuedLeases.count < 20_000, issuedLeases.insert(lease).inserted else { throw QAError.refused }
            leases = leases.filter { if case .number(let expiry) = $0.value["expires_at"] { return expiry > Date().timeIntervalSince1970 }; return false }
            guard leases.count < 64 else { throw QAError.refused }
            leases[lease] = value
            capabilities = Set(value["capabilities"].array?.compactMap(\.string) ?? []).intersection(QAPolicy.operations.union(["observe", "cleanup"]))
            var reply = value.object!
            let build = AppBuildInfo.current()
            reply["build"] = .string(build.summary)
            reply["commit"] = .string(build.sourceSHA ?? ProcessInfo.processInfo.environment["SWARMHUB_QA_SOURCE_COMMIT"] ?? "unavailable")
            reply["source_dirty"] = .bool(build.dirty || ProcessInfo.processInfo.environment["SWARMHUB_QA_SOURCE_DIRTY"] == "true")
            reply["capabilities"] = .strings(capabilities.sorted())
            return .object(reply)
        }
        if route == "action" {
            // Reject arbitrary content BEFORE even the read-only gateway authorization request.
            let step = body["step"]
            _ = try QAPolicy.step(step)
            guard let actionID = body["action_id"].string, QAPolicy.identifier(actionID),
                  body["marker"] == .string(QAPolicy.marker) else { throw QAError.refused }
            if step.object?["prompt"] != nil {
                guard let resource = body["resource"].string,
                      body["text"] == .string(try QAPolicy.text(step, resource: resource)) else { throw QAError.refused }
            } else if body.object?["text"] != nil { throw QAError.refused }
        }
        let common: Set<String> = ["schema", "run_id", "scenario_id", "resource", "lease"]
        let extras: [String: Set<String>] = [
            "begin": ["max_turns", "max_seconds", "max_run_turns", "max_run_seconds", "marker"],
            "action": ["action_id", "step", "marker", "text"],
            "record": ["tool", "payload", "attempt_id", "marker"]]
        guard QAHTTP.routes.contains(route) else { throw QAError.refused }
        try QAPolicy.fields(body, allowed: common.union(extras[route] ?? []), required: common)
        guard body["schema"] == .string(QAPolicy.schema), let run = body["run_id"].string, QAPolicy.identifier(run),
              let scenario = body["scenario_id"].string, scenario.range(of: #"\A(?:A(?:0[1-9]|1[0-8])|F(?:0[1-9]|1[0-9]|2[0-5])|B(?:0[1-9]|10)|U(?:0[1-9]|1[0-2]))\z"#, options: .regularExpression) != nil,
              let resource = body["resource"].string, QAPolicy.name(resource), resource == "QA-\(run)-\(scenario) [QA-TEST]",
              let lease = body["lease"].string, let proof = leases.removeValue(forKey: lease),
              case .number(let expiry) = proof["expires_at"], expiry > Date().timeIntervalSince1970 else { throw QAError.refused }
        let key = run + "/" + scenario
        // MainActor is reentrant at awaits. Serialize scope handlers before any remote suspension.
        if route != "record" {
            guard handling.insert(key).inserted else { throw QAError.refused }
        }
        defer { if route != "record" { handling.remove(key) } }
        if route == "begin" {
            guard scopes[key] == nil, body["marker"] == .string(QAPolicy.marker),
                  body["max_turns"] == .number(3), body["max_seconds"] == .number(120),
                  body["max_run_turns"] == .number(24), body["max_run_seconds"] == .number(900), scopes.count < 65 else { throw QAError.refused }
            if runs[run] == nil { runs[run] = (.now, 0, 0) }
            guard Date().timeIntervalSince(runs[run]!.started) < 900 else { throw QAError.refused }
            let id = "QA-" + UUID().uuidString
            let bot = Bot(name: resource, persona: "[QA-TEST] Isolated synthetic QA scope. All tool results are simulated; never claim delivery.", backend: .hermes, hermesProfile: "default")
            let base = try QAMode.boundary.nativeURL(scope: id)
            bot.hermesBaseURL = base.absoluteString
            // Record ownership before the first remote mutation, including uncertain begin outcomes.
            scopes[key] = Scope(id: id, run: run, scenario: scenario, resource: resource, bot: bot, started: .now, busy: true)
            var journalBody = body.object!; journalBody["lease"] = nil
            try journal(.object(["scope": .string(id), "intent": .object(journalBody), "state": .string("begin-accepted")]))
            var remoteBody = body.object!; remoteBody["scope_id"] = .string(id)
            let accepted = try await remote("begin", .object(remoteBody))
            guard accepted["acknowledged"] == .bool(true), accepted["scope_id"] == .string(id) else { throw QAError.blocked }
            QAMode.boundary.grant(scope: id, lease: lease, expiry: expiry, resource: resource, run: run, scenario: scenario)
            let backend = try store.backend(for: bot)
            guard try await backend.sessionTransport() == .nativeSessions else { throw QAError.blocked }
            let session = try await backend.createSession(title: resource, systemPrompt: bot.persona, id: id)
            guard session == id else { QAMode.boundary.revoke(id); throw QAError.refused }
            bot.hermesSessionID = session
            scopes[key]?.busy = false
            store.bots.append(bot); store.open(bot); store.save()
            return .object(["resource": .string(resource), "scope_id": .string(id), "acknowledged": .bool(true)])
        }
        guard let scope = scopes[key], scope.resource == resource, !scope.closed || route == "cleanup",
              route == "cleanup" || route == "record" || !scope.busy else { throw QAError.refused }
        // The server repeats these checks atomically at EACH native request, including async app work.
        var remoteBody = body.object!; remoteBody["scope_id"] = .string(scope.id)
        if route == "cleanup" {
            let result = try await remote("cleanup", .object(remoteBody))
            guard result["active_qa_work"] == .number(0), result["remote_verified"] == .bool(true) else { throw QAError.blocked }
            store.stop(scope.bot); _ = store.stopAutomations(in: scope.bot)
            QAMode.boundary.revoke(scope.id); scopes[key]?.closed = true
            return result
        }
        if route == "record" {
            guard body["marker"] == .string(QAPolicy.marker), let tool = body["tool"].string,
                  let attempt = body["attempt_id"].string else { throw QAError.refused }
            // Recording never sends and needs no remote call (avoids deadlock inside a real Hermes tool call).
            return try recorder.record(resource: resource, tool: tool, payload: body["payload"], attempt: attempt)
        }
        guard Date().timeIntervalSince(scope.started) < 120, let budget = runs[run], Date().timeIntervalSince(budget.started) < 900 else { throw QAError.refused }
        let authorization = try await remote("authorize", .object(remoteBody))
        guard authorization["acknowledged"] == .bool(true), authorization["scope_id"] == .string(scope.id) else { throw QAError.blocked }
        let actionID = body["action_id"].string ?? route
        QAMode.boundary.grant(scope: scope.id, lease: lease, expiry: expiry, resource: resource, run: run, scenario: scenario, action: route == "action" ? actionID : nil)
        if route == "observe" {
            var observed = try await remote("observe", .object(remoteBody)).object ?? [:]
            // Remote raw trace is evidence only with exact immutable ownership; never substitute model assertions.
            for (field, wanted) in ["schema": QAPolicy.schema, "run_id": run, "scenario_id": scenario, "resource": resource, "session_id": scope.id] {
                guard observed[field] == .string(wanted) else { throw QAError.refused }
            }
            let idle = store.isIdle(scope.bot)
            observed["capture_complete"] = .bool(idle && observed["capture_complete"] == .bool(true))
            var state = observed["state"]?.object ?? [:]
            let answers = scope.bot.messages.filter { $0.role == .assistant && $0.turnState == .finished }
            state["answer_has_marker"] = .bool(answers.last?.content.contains(QAPolicy.marker) == true)
            state["answer_in_origin"] = .bool(!answers.isEmpty && scope.bot.hermesSessionID == scope.id)
            // Replay actual app stream deltas against the displayed final row. Missing capture stays missing.
            if !answers.isEmpty, answers.allSatisfy({ receivedText[$0.id] != nil }) {
                state["partial_preserved"] = .bool(answers.allSatisfy { receivedText[$0.id] == $0.content })
            } else { state["partial_preserved"] = nil }
            observed["state"] = .object(state)
            observed["app_messages"] = .array(scope.bot.messages.map { message in .object([
                "id": .string(message.id.uuidString), "role": .string(message.role.rawValue), "content": .string(message.content),
                "test_mode": .bool(message.metadata["test_mode"] == "true"), "streaming": .bool(message.isStreaming)]) })
            observed["screenshots"] = .strings(observed["capture_complete"] == .bool(true) ? try screenshot(scope: scope) : [])
            return .object(observed)
        }
        if route == "checkpoint" || route == "restart.prepare" {
            guard let budget = runs[run], budget.actions < 120 else { throw QAError.refused }
            runs[run]?.actions += 1
            return try await checkpoint(scope, body: .object(remoteBody), restart: route == "restart.prepare")
        }
        guard route == "action", body["marker"] == .string(QAPolicy.marker), QAPolicy.identifier(actionID),
              capabilities.contains(try QAPolicy.step(body["step"])) else { throw QAError.refused }
        let step = body["step"], op = try QAPolicy.step(step)
        if let previous = scopes[key]?.intents[actionID] {
            guard previous == step, scopes[key]?.acknowledged.contains(actionID) == true else { throw QAError.blocked }
            return .object(["acknowledged": .bool(true), "action_id": .string(actionID)])
        }
        guard let currentBudget = runs[run], currentBudget.actions < 120 else { throw QAError.refused }
        var text: String?
        if step.object?["prompt"] != nil {
            text = try QAPolicy.text(step, resource: resource)
            guard body["text"] == .string(text!) else { throw QAError.refused }
        } else if body.object?["text"] != nil { throw QAError.refused }
        let isTurn = ["chat.send", "approval.request", "routine.run"].contains(op)
        if isTurn { guard scope.turns < 3, currentBudget.turns < 24 else { throw QAError.refused } }
        // Reserve before suspension to prevent reentrant concurrent mutations.
        scopes[key]?.busy = true; scopes[key]?.intents[actionID] = step; scopes[key]?.actions += 1
        runs[run]?.actions += 1
        if isTurn { scopes[key]?.turns += 1; runs[run]?.turns += 1 }
        defer { scopes[key]?.busy = false }
        try journal(.object(["scope": .string(scope.id), "action_id": .string(actionID), "step": step, "state": .string("accepted")]))
        switch op {
        case "chat.send", "approval.request":
            guard store.isIdle(scope.bot), store.send(text: text!, bot: scope.bot, conversation: scope.bot, replyToID: nil,
                metadata: ["test_mode": "true", "qa_run": run, "qa_scenario": scenario, "qa_scope": scope.id]) else { throw QAError.blocked }
        case "chat.stop": store.stop(scope.bot)
        case "approval.decide":
            let pending = store.approvals.filter { $0.botID == scope.bot.id && $0.sessionID == scope.id }
            guard pending.count == 1, let approval = pending.first, approval.actionKind == "qa_approval",
                  approval.command == "qa_approval [QA-TEST]", approval.requestID != nil else { throw QAError.blocked }
            let approved = step["value"] == .string("approve")
            // There is one fixed noop intent per scope. A new request ID cannot reverse its denial.
            guard !approved || !scope.approvalDenied else { throw QAError.refused }
            if !approved { scopes[key]?.approvalDenied = true }
            // The normal UI decision path; remote gateway binds request id to the immutable noop intent.
            store.decide(approval, approved: approved)
        case "routine.create":
            guard scope.bot.routineRunMarks.isEmpty else { throw QAError.refused }
            let routine = BotRoutine(name: resource, schedule: "1m", prompt: text!, isEnabled: false)
            guard await store.createRoutineOnServer(routine, for: scope.bot) == nil else { throw QAError.blocked }
        case "routine.run", "routine.pause", "routine.delete":
            guard await store.refreshRoutines(for: scope.bot), let jobs = store.routines.state(for: scope.bot.id).jobs.value,
                  jobs.count == 1, let job = jobs.first, job.name == resource, scope.bot.routineRunMarks[job.id] != nil else { throw QAError.blocked }
            if op == "routine.run" { await store.runRoutineNow(job, for: scope.bot) }
            else if op == "routine.pause" { await store.setRoutine(job, enabled: false, for: scope.bot) }
            else { await store.deleteRoutine(job, for: scope.bot) }
            guard store.routines.state(for: scope.bot.id).error == nil else { throw QAError.blocked }
        case "checkpoint", "restart.prepare": _ = try await checkpoint(scope, body: .object(remoteBody), restart: op == "restart.prepare")
        default: throw QAError.refused
        }
        try journal(.object(["scope": .string(scope.id), "action_id": .string(actionID), "state": .string("acknowledged")]))
        scopes[key]?.acknowledged.insert(actionID)
        return .object(["acknowledged": .bool(true), "action_id": .string(actionID)])
    }
    private func checkpoint(_ scope: Scope, body: ComposioValue, restart: Bool) async throws -> ComposioValue {
        // Preparation drains remotely before local checkpointing. It never kills a process or replays accepted work.
        if restart {
            let result = try await remote("restart.prepare", body)
            guard result["active_qa_work"] == .number(0), result["remote_verified"] == .bool(true) else { throw QAError.blocked }
            store.stop(scope.bot); QAMode.boundary.revoke(scope.id)
        }
        let id = "QA-" + UUID().uuidString
        let snapshot = StoreFile(bots: [scope.bot], groups: [])
        try QAMode.writePrivate(try JSONEncoder().encode(snapshot), to: directory.appending(path: id + ".checkpoint.json"))
        try journal(.object(["scope": .string(scope.id), "checkpoint": .string(id), "restart_prepared": .bool(restart)]))
        if restart { scopes[scope.run + "/" + scope.scenario]?.closed = true }
        return .object(["acknowledged": .bool(true), "checkpoint_id": .string(id), "restart_prepared": .bool(restart)])
    }
    private func screenshot(scope: Scope) throws -> [String] {
        guard store.selectedBot?.id == scope.bot.id,
              let view = NSApp.windows.first(where: { $0.isVisible && $0.title.contains("QA TEST MODE") })?.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return [] }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return [] }
        let id = "QA-" + UUID().uuidString + ".png"
        try QAMode.writePrivate(data, to: directory.appending(path: id))
        return [id]
    }
}
#endif
