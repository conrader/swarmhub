import Foundation
import Observation
import SwarmHubCore

@MainActor @Observable
final class MobileStore {
    var profiles: [AgentProfile] = []
    var caches: [String: ChatCache] = [:]
    var capabilities: [String: ServerCapabilities] = [:]
    var approvals: [MobileApproval] = []
    var uncertainApprovals: Set<String> = []
    var decidingApprovals: Set<String> = []
    var activeAgents: Set<String> = []
    var loadingAgents: Set<String> = []
    var demo = false
    var booted = false
    var error: String?
    var notice: String?
    @ObservationIgnored private var repository: SQLiteRepository?
    @ObservationIgnored private var botPromptSync: BotPromptSyncStore?
    @ObservationIgnored private let credentials = KeychainCredentials()
    @ObservationIgnored private var clients: [String: any AgentClient] = [:]
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var draftTasks: [String: Task<Void, Never>] = [:]
    var storageReady: Bool { repository != nil }

    init() {
        if CaptureConfiguration.screen != nil { CaptureConfiguration.configure(self); return }
        do {
            let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("SwarmHub")
            repository = try SQLiteRepository(url: directory.appendingPathComponent("mobile.sqlite"))
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
            do { botPromptSync = try BotPromptSyncStore(fileURL: directory.appendingPathComponent("bot-prompt-sync.json")) }
            catch { notice = "Saved bot prompt settings could not be loaded. Chat is using local settings; the sync file was kept unchanged." }
        } catch { repository = nil; self.error = "Local storage is unavailable. Setup and chat are disabled until it is available." }
    }

    func load() async {
        guard !booted else { return }; defer { booted = true }
        do {
            profiles = try await repository?.profiles() ?? []
            for profile in profiles {
                var cached = try await repository?.cache(agentID: profile.id) ?? ChatCache()
                if cached.turn?.state == .sending || cached.turn?.state == .streaming { cached.turn?.state = .interrupted }
                caches[profile.id] = cached
            }
        } catch { repository = nil; self.error = "Saved history could not be loaded. Setup is disabled so the saved data cannot be overwritten." }
    }

    func useSamples() {
        guard profiles.isEmpty else { return }
        demo = true
        for (name, color) in [("Atlas", "blue"), ("Mira", "orange"), ("Patch", "green"), ("Scout", "purple")] {
            guard let address = try? ConnectionAddress("https://sample.invalid", profile: name.lowercased()) else { continue }
            let profile = AgentProfile(id: "sample-\(name.lowercased())", name: name, address: address, sessionID: "sample-session", color: color)
            profiles.append(profile)
            clients[profile.id] = CaptureConfiguration.screen == nil ? DemoClient() : DemoClient(history: CaptureConfiguration.messages(for: name))
            caches[profile.id] = ChatCache()
        }
    }

    func verify(address: String, profile: String, key: String) async throws -> (ConnectionAddress, ProfileVerification) {
        let connection = try ConnectionAddress(address, profile: profile)
        let result = try await HermesClient(address: connection, key: key).verify()
        return (connection, result)
    }

    func add(address: ConnectionAddress, verification: ProfileVerification, key: String, name: String) async throws {
        guard let repository else { throw CoreError.storage }
        let existing = profiles.first { $0.address == address && !demo }
        let profile = existing ?? AgentProfile(name: name.isEmpty ? verification.name : name, address: address)
        let previousKey = try credentials.read(profile.id)
        try credentials.write(key, account: profile.id)
        var next = demo ? [] : profiles
        if existing == nil { next.append(profile) }
        do { try await repository.saveProfiles(next) }
        catch {
            if let previousKey { try? credentials.write(previousKey, account: profile.id) }
            else { try? credentials.remove(profile.id) }
            throw CoreError.storage
        }
        if demo { stopLocalStreams(); clients = [:]; caches = [:]; approvals = [] }
        demo = false; profiles = next
        clients[profile.id] = nil
        capabilities[profile.id] = verification.capabilities
    }

    func client(_ id: String) throws -> any AgentClient {
        if let existing = clients[id] { return existing }
        guard let profile = profiles.first(where: { $0.id == id }), let key = try credentials.read(id), !key.isEmpty else { throw CoreError.missingKey }
        let local = BotPromptContext(name: profile.name)
        let context = botPromptSync?.context(for: BotPromptDocument.botKey(profile.address), fallback: local) ?? local
        let client = HermesClient(address: profile.address, key: key, promptContext: context); clients[id] = client; return client
    }

    /// Explicit edits only: mobile defaults are never published as local observations.
    func editBotPrompt(_ id: String, change: (inout BotPromptContext) -> Void) throws {
        guard !demo, let profile = profiles.first(where: { $0.id == id }), let botPromptSync else { throw CoreError.storage }
        try botPromptSync.edit(key: BotPromptDocument.botKey(profile.address), now: Int64(Date().timeIntervalSince1970 * 1_000),
                               fallback: BotPromptContext(name: profile.name), change)
        // A HermesClient captures its context at creation; the next turn must use the saved values.
        clients[id] = nil
    }

    @discardableResult func syncBotPrompts(using transport: any BotPromptSyncTransport) async throws -> Bool {
        guard !demo, let botPromptSync else { throw CoreError.storage }
        let merged = try await botPromptSync.synchronize(using: transport)
        if merged { clients = [:] }
        return merged
    }

    func sessions(_ id: String) async throws -> [SessionSummary] {
        let client = try client(id)
        let flags = try await client.capabilities(); capabilities[id] = flags
        guard flags.sessions else { throw CoreError.unsupported("This mobile milestone requires native Hermes sessions. Legacy chat support is still planned.") }
        return try await client.sessions()
    }

    func chooseSession(_ session: String, agentID: String) async throws {
        guard !activeAgents.contains(agentID), caches[agentID]?.turn == nil else { throw CoreError.unsupported("Resolve the existing turn before switching conversations.") }
        guard (caches[agentID]?.draft ?? "").isEmpty else { throw CoreError.unsupported("Send or clear your draft before switching conversations.") }
        guard let index = profiles.firstIndex(where: { $0.id == agentID }) else { return }
        let previous = profiles[index].sessionID
        profiles[index].sessionID = session
        do {
            if !demo { try await repository?.saveProfiles(profiles) }
        } catch { profiles[index].sessionID = previous; throw error }
        caches[agentID] = ChatCache()
        try await persist(agentID)
        await refresh(agentID)
    }

    func newSession(_ id: String) async throws {
        guard !activeAgents.contains(id), caches[id]?.turn == nil else { throw CoreError.unsupported("Resolve the existing turn before starting another conversation.") }
        guard (caches[id]?.draft ?? "").isEmpty else { throw CoreError.unsupported("Send or clear your draft before starting another conversation.") }
        let session = try await client(id).createSession(title: "SwarmHub mobile conversation")
        try await chooseSession(session, agentID: id)
    }

    func refresh(_ id: String) async {
        guard !loadingAgents.contains(id), !activeAgents.contains(id), let profile = profiles.first(where: { $0.id == id }) else { return }
        loadingAgents.insert(id); defer { loadingAgents.remove(id) }
        do {
            let client = try client(id)
            capabilities[id] = try await client.capabilities()
            guard let sessionID = profile.sessionID else { return }
            let history = try await client.messages(sessionID: sessionID)
            var cache = caches[id] ?? ChatCache(); cache.messages = history
            if let runID = cache.turn?.runID {
                do {
                    let snapshot = try await client.run(runID: runID)
                    if let terminal = snapshot.state {
                        if terminal != .completed { if cache.draft.isEmpty { cache.draft = cache.turn?.input ?? "" }; notice = "The server reports this turn as \(terminal.rawValue). Your draft and server history are kept." }
                        cache.turn = nil
                        approvals.removeAll { $0.agentID == id }
                    } else if let approval = snapshot.approval { remember(approval, agentID: id) }
                } catch { notice = "History was refreshed. The interrupted turn’s outcome is still unconfirmed; it was not resent." }
            }
            caches[id] = cache; try await persist(id)
        } catch { self.error = safeMessage(error) }
    }

    func updateDraft(_ value: String, agentID: String) {
        var cache = caches[agentID] ?? ChatCache(); cache.draft = value; caches[agentID] = cache
        draftTasks[agentID]?.cancel()
        draftTasks[agentID] = Task {
            do { try await Task.sleep(for: .milliseconds(200)); try await persist(agentID) }
            catch is CancellationError {} catch { self.error = "The draft could not be saved." }
        }
    }

    func send(_ id: String) async {
        guard !activeAgents.contains(id), !loadingAgents.contains(id), caches[id]?.turn == nil,
              let profile = profiles.first(where: { $0.id == id }), let sessionID = profile.sessionID else { return }
        let input = (caches[id]?.draft ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        do {
            let client = try client(id)
            guard capabilities[id]?.sessions == true else { throw CoreError.unsupported("Load the server’s native session capabilities before sending.") }
            var cache = caches[id] ?? ChatCache()
            cache.turn = PendingTurn(sessionID: sessionID, input: input); cache.draft = ""
            caches[id] = cache
            draftTasks[id]?.cancel()
            do { try await persist(id) }
            catch { cache.turn = nil; cache.draft = input; caches[id] = cache; throw error }
            activeAgents.insert(id)
            tasks[id] = Task { await consume(client.stream(sessionID: sessionID, text: input), agentID: id) }
        } catch { self.error = safeMessage(error) }
    }

    private func consume(_ stream: AsyncThrowingStream<ChatEvent, Error>, agentID id: String) async {
        defer { activeAgents.remove(id); tasks[id] = nil }
        var lastProgressSave = Date.distantPast
        do {
            for try await event in stream {
                guard var cache = caches[id], var turn = cache.turn else { continue }
                switch event {
                case .started(let runID): turn.runID = runID; turn.state = .streaming
                case .delta(let text): turn.output += text
                case .snapshot(let text): turn.output = text
                case .status(let text): notice = text
                case .approval(let approval): remember(approval, agentID: id)
                case .terminal(let state): turn.state = state
                }
                cache.turn = turn; caches[id] = cache
                // Persist run identity and progress, so a killed app can reconcile instead of resending.
                if case .delta = event {
                    if Date().timeIntervalSince(lastProgressSave) >= 0.2 { try await persist(id); lastProgressSave = .now }
                } else { try await persist(id); lastProgressSave = .now }
            }
            guard let turn = caches[id]?.turn else { return }
            guard [.completed, .cancelled, .failed].contains(turn.state) else { throw CoreError.interruptedStream }
            let history = try await client(id).messages(sessionID: turn.sessionID)
            var cache = caches[id] ?? ChatCache(); cache.messages = history; cache.turn = nil
            if turn.state != .completed { if cache.draft.isEmpty { cache.draft = turn.input }; notice = "The server reports this turn as \(turn.state.rawValue). Your draft and server history are kept." }
            caches[id] = cache; approvals.removeAll { $0.agentID == id }; try await persist(id)
        } catch {
            caches[id]?.turn?.state = .interrupted
            try? await persist(id)
            if !Task.isCancelled { self.error = safeMessage(error) }
        }
    }

    func stop(_ id: String) async {
        guard let runID = caches[id]?.turn?.runID else { return }
        do { try await client(id).stop(runID: runID); notice = "Stop requested. Waiting for the server’s final state." }
        catch { self.error = safeMessage(error) }
    }

    func resolve(_ item: MobileApproval, approved: Bool) async throws {
        guard approvals.contains(where: { $0.id == item.id }) else { throw CoreError.unsupported("This request is no longer pending.") }
        guard !decidingApprovals.contains(item.id), !uncertainApprovals.contains(item.id) else { throw CoreError.unsupported("Check this request’s server status before trying another decision.") }
        decidingApprovals.insert(item.id); defer { decidingApprovals.remove(item.id) }
        do { try await client(item.agentID).resolve(item.request, approved: approved) }
        catch { uncertainApprovals.insert(item.id); throw error }
        approvals.removeAll { $0.id == item.id }
        notice = approved ? "The server accepted the approval." : "The server accepted the decline."
    }

    func checkApproval(_ item: MobileApproval) async throws {
        let snapshot = try await client(item.agentID).run(runID: item.request.runID)
        if snapshot.approval?.id == item.request.id { uncertainApprovals.remove(item.id); return }
        if snapshot.approval != nil || ["running", "stopping", "completed", "cancelled", "failed"].contains(snapshot.status) {
            approvals.removeAll { $0.id == item.id }; uncertainApprovals.remove(item.id)
            notice = "This request is no longer pending on the server."
        } else { throw CoreError.unsupported("The server could not confirm this approval request. Check it on desktop.") }
    }

    func background() async {
        stopLocalStreams()
        for id in caches.keys {
            draftTasks[id]?.cancel()
            if caches[id]?.turn?.state == .sending || caches[id]?.turn?.state == .streaming { caches[id]?.turn?.state = .interrupted }
            do { try await persist(id) } catch { self.error = "A draft or partial reply could not be saved." }
        }
    }

    func disconnect(_ id: String) async throws {
        guard let repository, !demo else { return }
        let previousKey = try credentials.read(id)
        try credentials.remove(id)
        do { try await repository.remove(agentID: id) }
        catch { if let previousKey { try? credentials.write(previousKey, account: id) }; throw error }
        tasks[id]?.cancel(); clients[id] = nil; caches[id] = nil; profiles.removeAll { $0.id == id }; approvals.removeAll { $0.agentID == id }
    }

    private func persist(_ id: String) async throws {
        if demo { return }
        guard profiles.contains(where: { $0.id == id }) else { return }
        guard let repository else { throw CoreError.storage }
        try await repository.saveCache(caches[id] ?? ChatCache(), agentID: id)
    }
    private func remember(_ approval: ApprovalItem, agentID: String) {
        let item = MobileApproval(agentID: agentID, request: approval)
        if !approvals.contains(where: { $0.id == item.id }) { approvals.append(item) }
    }
    private func stopLocalStreams() { tasks.values.forEach { $0.cancel() } }
    private func safeMessage(_ error: Error) -> String {
        if let core = error as? CoreError { return core.localizedDescription }
        if error is CredentialError { return error.localizedDescription }
        return "Could not reach the server. Saved history and drafts are kept; check the connection before retrying."
    }
}

struct MobileApproval: Identifiable, Equatable {
    let agentID: String
    let request: ApprovalItem
    var id: String { "\(agentID):\(request.id)" }
}
