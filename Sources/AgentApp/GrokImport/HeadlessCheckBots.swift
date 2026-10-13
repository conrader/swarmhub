import Foundation
import Security

/// `AgentApp --check-bots [--chat "<bot name>" "<text>"]`: read-only probe of every Hermes bot in the
/// real store (`/v1/models`, `/v1/capabilities`), optionally followed by one real turn to one bot
/// through `AppStore.send(text:)`, the path the composer uses. Never prints a key.
extension HeadlessCommands {
    struct BotCheck: Equatable {
        enum Key: Equatable { case present, missing, locked }
        var name: String
        var profile: String
        var key: Key
        var modelID: String? = nil
        var modelMatches = false
        var sessionChatStreaming: Bool? = nil
        var jobs: Bool? = nil
        /// Read-only `GET /api/jobs` summary (routines); never counts as a failure.
        var routines: String? = nil
        var problem: String? = nil
        var ok: Bool { key == .present && problem == nil && modelMatches }
    }

    static func line(_ check: BotCheck) -> String {
        let key: String
        switch check.key {
        case .present: key = "present"
        case .missing: key = "missing"
        case .locked: key = "present but unreadable without a Keychain prompt"
        }
        let models: String
        if let id = check.modelID { models = "\(id) (\(check.modelMatches ? "match" : "MISMATCH"))" }
        else { models = "- (\(check.problem ?? "not checked"))" }
        func flag(_ value: Bool?) -> String { value.map { String($0) } ?? "n/a" }
        var text = "\(check.name) | \(check.profile) | key: \(key) | models: \(models) | caps: session_chat_streaming=\(flag(check.sessionChatStreaming)), jobs=\(flag(check.jobs))"
        if let routines = check.routines { text += " | routines: \(routines)" }
        if check.modelID != nil, let problem = check.problem { text += " | error: \(problem)" }
        return text
    }

    /// A named profile is served only when `/p/<profile>/v1/models` names that profile; with
    /// multiplexing off the gateway answers as the default agent instead.
    static func modelMatches(_ id: String, profile: String) -> Bool { profile == "default" || id == profile }

    /// The `jobs` feature flag, or any advertised `jobs*` flag when the exact key is absent.
    static func jobsFlag(_ features: [String: Any]) -> Bool? {
        if let value = features["jobs"] as? Bool { return value }
        return features.keys.sorted().filter { $0.hasPrefix("jobs") }.compactMap { features[$0] as? Bool }.first
    }

    static func checkBot(_ bot: Bot, store: AppStore) async -> BotCheck {
        let profile = bot.hermesProfile ?? "default"
        let account = AppStore.keyAccount(forProfile: profile)
        var check = BotCheck(name: bot.name, profile: profile, key: .missing)
        let backend: HermesBackend
        do {
            guard let built = try store.backend(for: bot) as? HermesBackend else { check.problem = "not a Hermes backend"; return check }
            backend = built
        } catch { check.problem = error.localizedDescription; return check }
        if !backend.apiKey.isEmpty { check.key = .present }
        else if store.keyStore.hasKey(for: account) { check.key = .locked; check.problem = "Keychain access needs approval"; return check }
        else if profile != "default" { check.problem = "no key"; return check }
        do {
            let models = try await backend.jsonRequest(path: "v1/models")
            guard let id = (models["data"] as? [[String: Any]])?.first?["id"] as? String else { check.problem = "server listed no models"; return check }
            check.modelID = id; check.modelMatches = modelMatches(id, profile: profile)
            let features = (try await backend.jsonRequest(path: "v1/capabilities"))["features"] as? [String: Any] ?? [:]
            check.sessionChatStreaming = features["session_chat_streaming"] as? Bool
            check.jobs = jobsFlag(features)
            check.routines = await routinesSummary(HermesJobsClient(backend: backend))
        } catch {
            let reason = error.localizedDescription
            check.problem = backend.apiKey.isEmpty ? reason : reason.replacingOccurrences(of: backend.apiKey, with: "[key]")
        }
        return check
    }

    /// "3 (1 paused)", "no jobs API" or "error: …" — list only; nothing is created, run or changed.
    static func routinesSummary(_ client: HermesJobsClient) async -> String {
        do {
            let jobs = try await client.list()
            let paused = jobs.filter(\.isPaused).count
            return "\(jobs.count)" + (paused > 0 ? " (\(paused) paused)" : "")
        } catch HermesJobsError.noJobsAPI { return "no jobs API" }
        catch { return "error: " + BotInfoCache.describe(error, key: client.backend.apiKey) }
    }

    static func checkBots(store: AppStore, chat: (name: String, text: String)?, chatTimeout: Duration = .seconds(300), output: (String) -> Void) async -> Int32 {
        let bots = store.bots.filter { $0.backend == .hermes && !$0.isReadOnlyArchive }
        var failures = 0
        for bot in bots {
            let check = await checkBot(bot, store: store)
            if !check.ok { failures += 1 }
            output(line(check))
        }
        output("Checked \(bots.count) Hermes bots: \(bots.count - failures) OK, \(failures) failed")
        guard let chat else { return failures == 0 ? 0 : 1 }
        return await chatOnce(store: store, botName: chat.name, text: chat.text, timeout: chatTimeout, output: output)
    }

    /// Sends one turn via `AppStore.send(text:)` (session creation and transport choice included)
    /// and prints the reply's first 200 characters and the session id.
    static func chatOnce(store: AppStore, botName: String, text: String, timeout: Duration, output: (String) -> Void) async -> Int32 {
        let matches = store.bots.filter { $0.backend == .hermes && !$0.isReadOnlyArchive && $0.name.caseInsensitiveCompare(botName) == .orderedSame }
        guard matches.count == 1, let bot = matches.first else { output("Chat failed: \(matches.isEmpty ? "no" : "more than one") Hermes bot named \(botName)"); return 1 }
        store.selectedBot = bot; store.errorMessage = nil
        let before = Set(bot.messages.map(\.id))
        guard store.send(text: text) else { output("Chat failed: \(store.errorMessage ?? (store.needsKey(bot) ? "no readable key for \(bot.hermesProfile ?? "default")" : "the message was not sent"))"); return 1 }
        let clock = ContinuousClock(); let deadline = clock.now.advanced(by: timeout)
        while !store.isIdle && clock.now < deadline { try? await Task.sleep(for: .milliseconds(100)) }
        if !store.isIdle { store.stop(); output("Chat failed: no reply within \(timeout)"); return 1 }
        let reply = bot.messages.last { !before.contains($0.id) && $0.role == .assistant }?.content.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let session = bot.hermesSessionID ?? "\(bot.id.uuidString) (legacy, no server session)"
        if let error = store.errorMessage { output("Chat failed: \(error) | session \(session)"); return 1 }
        guard !reply.isEmpty else { output("Chat failed: empty reply | session \(session)"); return 1 }
        output("Chat \(bot.name) | session \(session) | reply: \(String(reply.prefix(200)))")
        return 0
    }

    /// Runs `--check-bots` on the main run loop so the synchronous app entry point can wait for it.
    /// Keychain UI is disabled first: a key the current build may not read is reported, never prompted for.
    static func runCheckBots(arguments: [String]) -> Int32 {
        var chat: (name: String, text: String)?
        if let chatIndex = arguments.firstIndex(of: "--chat") {
            guard arguments.indices.contains(chatIndex + 2) else { print("Usage: AgentApp --check-bots [--chat \"<bot name>\" \"<text>\"]"); return 64 }
            chat = (arguments[chatIndex + 1], arguments[chatIndex + 2])
        }
        SecKeychainSetUserInteractionAllowed(false)
        let store = AppStore(autoConfigureHermes: false)
        let box = ExitCodeBox()
        Task { @MainActor in box.code = await checkBots(store: store, chat: chat, output: { print($0); fflush(stdout) }) }
        while box.code == nil { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1)) }
        return box.code!
    }
}

@MainActor private final class ExitCodeBox { var code: Int32? }
