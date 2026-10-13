import Combine
import Foundation
import AppKit
import UserNotifications

@MainActor final class AppStore: ObservableObject {
    @Published var bots: [Bot] = []; @Published var selectedBot: Bot?; @Published var isStreaming = false
    @Published var approvals: [ApprovalRequest] = []
    @Published var subAgentTasks: [UUID: [SubAgentTask]] = [:]
    @Published var showInfo = true; @Published var showingNewBot = false; @Published var showingCommandPalette = false
    @Published var showingHiddenBots = false; @Published var replyTo: ChatMessage?
    @Published var routines: [UUID: [BotRoutine]] = [:]
    @Published var editingBot: Bot?; @Published var errorMessage: String?
    private var streamTask: Task<Void, Never>?; private let fileURL: URL
    private var streamingBotID: UUID?; private var streamingAssistant: ChatMessage?
    private var historyLoadTokens: [UUID: UUID] = [:]
    private var activeStreamToken: UUID?
    private var stopInProgressForStream: UUID?
    private var persistenceEnabled = true
    private let backendFactory: ((Bot) throws -> any AgentBackend)?
    private let didCancelLocalStream: (() -> Void)?

    init(demoMode: Bool = false, storeURL: URL? = nil, autoConfigureHermes: Bool = true, backendFactory: ((Bot) throws -> any AgentBackend)? = nil, didCancelLocalStream: (() -> Void)? = nil) {
        self.backendFactory = backendFactory
        self.didCancelLocalStream = didCancelLocalStream
        let directory = storeURL?.deletingLastPathComponent() ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appending(path: "AgentApp", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); fileURL = storeURL ?? directory.appending(path: "store.json")
        if demoMode {
            persistenceEnabled = false
            loadDemoData(includeActivity: true)
        } else if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                bots = try JSONDecoder().decode([Bot].self, from: Data(contentsOf: fileURL))
            } catch {
                persistenceEnabled = false
                let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
                let backup = fileURL.deletingLastPathComponent().appending(path: "store.json.corrupt-\(stamp)")
                do { try FileManager.default.moveItem(at: fileURL, to: backup) }
                catch { errorMessage = "Could not read or back up store.json: \(error.localizedDescription)" }
                if errorMessage == nil { errorMessage = "The saved store could not be decoded. It was moved to \(backup.lastPathComponent); saving is disabled for this launch." }
            }
            if Self.hasHermesConfiguration { bots.filter(\.isDemo).forEach { $0.isHidden = true } }
        } else if Self.hasHermesConfiguration {
            let bot = Bot(name: "Hermes", title: "Hermes Agent", description: "Default Hermes profile", backend: .hermes, avatarName: .faceCoral, hermesProfile: "default")
            bots = [bot]; save()
        } else {
            loadDemoData(persist: true)
        }
        selectedBot = bots.first
        if !demoMode, autoConfigureHermes, Self.hasHermesConfiguration { Task { await refreshHermesAgents() } }
    }

    static var hasHermesConfiguration: Bool { UserDefaults.standard.object(forKey: "hermesBaseURL") != nil || !KeychainStore.get(account: "hermes").isEmpty }

    func refreshHermesAgents() async {
        guard let baseURL = HermesBackend.validatedBaseURL(UserDefaults.standard.string(forKey: "hermesBaseURL") ?? AppConstants.defaultHermesURL) else { errorMessage = BackendError.invalidURL.localizedDescription; return }
        let names = (UserDefaults.standard.string(forKey: "hermesProfiles") ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        do {
            let profiles = try await HermesBackend(baseURL: baseURL, apiKey: KeychainStore.get(account: "hermes")).discoverProfiles(named: names)
            for profile in profiles where !bots.contains(where: { $0.backend == .hermes && ($0.hermesProfile ?? "default") == profile.id }) {
                bots.append(Bot(name: profile.name, title: "Hermes profile", description: "Hermes profile: \(profile.id)", backend: .hermes, avatarName: BotAvatarName.allCases[bots.count % BotAvatarName.allCases.count], hermesProfile: profile.id))
            }
            if selectedBot == nil { selectedBot = bots.first }
            save()
        } catch { errorMessage = error.localizedDescription }
    }

    func loadHermesHistory(for bot: Bot) {
        guard bot.backend == .hermes, !isStreaming else { return }
        let token = UUID(); historyLoadTokens[bot.id] = token
        let originalMessageIDs = bot.messages.map(\.id)
        let originalSessionID = bot.hermesSessionID
        Task {
            do {
                let activeBackend = try backend(for: bot)
                if try await activeBackend.sessionTransport() == .legacyChatCompletions { return }
                guard let sessionID = bot.hermesSessionID else { return }
                let rows = try await activeBackend.loadMessages(sessionID: sessionID)
                guard historyLoadTokens[bot.id] == token, !isStreaming, bot.hermesSessionID == originalSessionID, bot.messages.map(\.id) == originalMessageIDs else { return }
                guard let merged = Self.mergeHermesHistory(local: bot.messages, server: rows) else { return }
                bot.messages = merged; objectWillChange.send(); save()
            } catch { errorMessage = error.localizedDescription }
        }
    }
    static func mergeHermesHistory(local: [ChatMessage], server: [BackendMessage]) -> [ChatMessage]? {
        guard !server.isEmpty else { return local.isEmpty ? [] : nil }
        let remoteTurns = server.enumerated().filter { ["user", "assistant"].contains($0.element.role) }
        let localTurns = local.filter { [MessageRole.user, .assistant].contains($0.role) && $0.presentation == .text && !$0.content.isEmpty }
        if localTurns.isEmpty {
            return local + server.compactMap { Self.chatMessage($0) }
        }

        // Find the longest suffix of locally-known server-visible turns anywhere in the server
        // transcript. For established histories require a complete user -> assistant pair, and use
        // the latest matching window so repeated short turns cannot append an earlier duplicate tail.
        var matchedServerEnd: Int?
        let maximum = min(localTurns.count, remoteTurns.count)
        let minimum = localTurns.count >= 2 ? 2 : 1
        if maximum >= minimum {
            for count in stride(from: maximum, through: minimum, by: -1) {
                let suffix = localTurns.suffix(count)
                let includesFullPair = zip(suffix, suffix.dropFirst()).contains {
                    $0.role == .user && $1.role == .assistant
                }
                if localTurns.count >= 2 && !includesFullPair { continue }
                for start in stride(from: remoteTurns.count - count, through: 0, by: -1) {
                    let candidate = remoteTurns[start..<(start + count)]
                    if zip(suffix, candidate).allSatisfy({ local, remote in
                        local.role.rawValue == remote.element.role && local.content == remote.element.content
                    }) {
                        matchedServerEnd = candidate.last!.offset
                        break
                    }
                }
                if matchedServerEnd != nil { break }
            }
        }
        guard let end = matchedServerEnd else { return nil }
        let additions = server.dropFirst(end + 1).compactMap { Self.chatMessage($0) }
        return local + additions
    }

    private static func chatMessage(_ row: BackendMessage) -> ChatMessage? {
        guard let role = MessageRole(rawValue: row.role), !row.content.isEmpty else { return nil }
        return ChatMessage(id: row.id.flatMap(UUID.init(uuidString:)) ?? UUID(), role: role, content: row.content, createdAt: row.createdAt ?? .now)
    }

    func loadDemoData(persist: Bool = false, includeActivity: Bool = false) {
        let conversation = [
            ChatMessage(role: .user, content: "Can you review today’s launch plan and prepare the client update?"),
            ChatMessage(role: .assistant, content: "## Launch check-in\n\nThe release is **ready**. Two items are worth calling out:\n\n- Desktop QA passed on macOS 14 and 15\n- The support playbook needs one final approval\n\n```swift\nlet rollout = Release(stage: .ready, risk: .low)\n```"),
            ChatMessage(role: .assistant, content: "Draft ready", presentation: .draftEmail, metadata: ["to": "Maya Chen <maya@northstar.co>", "subject": "AgentApp launch update", "body": "Hi Maya,\n\nThe desktop rollout is ready for review. QA is complete and the remaining support item is queued for approval.\n\nBest,\nKonrad"]),
            ChatMessage(role: .assistant, content: "How would you like me to handle the rollout?", presentation: .options, metadata: ["options": "Ship today|Schedule for Monday|Open launch checklist"]),
            ChatMessage(role: .user, content: "Schedule it for Monday, please.", reactions: ["👍"], replyToID: nil),
            ChatMessage(role: .assistant, content: "Voice note", presentation: .voiceMemo, metadata: ["duration": "0:18"]),
            ChatMessage(role: .assistant, content: "Launch assets", presentation: .attachment, metadata: ["name": "launch-checklist.pdf", "size": "1.8 MB"]),
            ChatMessage(role: .assistant, content: "Useful links", presentation: .links, metadata: ["links": "Release board|QA report|Support plan"])
        ]
        bots = [
            Bot(name: "Atlas", title: "Operations lead", description: "Plans launches, coordinates work, and keeps projects moving.", avatarName: .faceCoral, memorySummary: "Knows the launch plan, client preferences, and weekly operating rhythm.", skills: ["Planning", "Email", "Project tracking"], messages: conversation),
            Bot(name: "Mira", title: "Research partner", description: "Finds evidence and turns it into clear decisions.", avatarName: .faceSky, unreadCount: 2, skills: ["Web research", "Synthesis"], messages: [ChatMessage(role: .assistant, content: "I finished the competitor landscape and highlighted the two strongest openings.")]),
            Bot(name: "Patch", title: "Engineering agent", description: "Builds, reviews, and tests product changes.", avatarName: .faceMint, skills: ["Code", "Testing"], messages: [ChatMessage(role: .assistant, content: "The CI run is green. I left a summary in the release branch.")]),
            Bot(name: "Scout", title: "Travel and logistics", description: "Handles itineraries, bookings, and practical details.", avatarName: .faceSun, unreadCount: 1, messages: [ChatMessage(role: .assistant, content: "I found three quiet hotels near the venue with flexible cancellation.")]),
            Bot(name: "Nova", title: "Creative studio", description: "Develops concepts, copy, and visual directions.", avatarName: .faceLilac, messages: [ChatMessage(role: .assistant, content: "The new onboarding directions are ready whenever you want to review them.")])
        ]
        bots.forEach { $0.isDemo = true }
        if includeActivity { loadDemoActivity() }
        if persist { save() }
    }
    private func loadDemoActivity() {
        if let id = bots.first?.id {
            approvals = [.init(id: UUID(), title: "Publish release notes", summary: "Atlas wants to publish the reviewed release notes to the client workspace.", draft: nil, botID: id)]
            routines[id] = [.init(name: "Morning brief", schedule: "Weekdays at 8:30", lastRun: "Today, 8:31"), .init(name: "Launch monitor", schedule: "When CI completes", lastRun: "Yesterday", isEnabled: false)]
        }
    }
    func addBot(name: String, persona: String, backend: BackendKind, avatarName: BotAvatarName) { let bot = Bot(name: name, persona: persona, backend: backend, avatarName: avatarName); bots.insert(bot, at: 0); selectedBot = bot; save() }
    func delete(_ bot: Bot) { bots.removeAll { $0.id == bot.id }; if selectedBot == bot { selectedBot = bots.first }; save() }
    func save() { guard persistenceEnabled, let data = try? JSONEncoder().encode(bots) else { return }; try? data.write(to: fileURL, options: .atomic) }
    func send(text: String) {
        guard !isStreaming, streamTask == nil, let bot = selectedBot, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let activeBackend: any AgentBackend
        do { activeBackend = try backend(for: bot) }
        catch { errorMessage = error.localizedDescription; return }
        historyLoadTokens[bot.id] = nil
        bot.messages.append(ChatMessage(role: .user, content: text, replyToID: replyTo?.id)); replyTo = nil; let assistant = ChatMessage(role: .assistant, content: "", isStreaming: true); bot.messages.append(assistant)
        objectWillChange.send(); save(); isStreaming = true; streamingBotID = bot.id; streamingAssistant = assistant
        let streamToken = UUID(); activeStreamToken = streamToken
        let history = bot.messages.filter { $0.id != assistant.id }.map { (role: $0.role.rawValue, content: $0.content) }
        streamTask = Task { [weak self] in
            guard let self else { return }
            var failed = false
            do {
                if bot.hermesSessionID == nil, try await activeBackend.sessionTransport() == .nativeSessions {
                    bot.hermesSessionID = try await activeBackend.createSession(title: bot.name, systemPrompt: bot.persona, id: "agentapp_\(bot.id.uuidString.lowercased())")
                    save()
                }
                let sessionID = bot.hermesSessionID ?? bot.id.uuidString
                let stream = try await activeBackend.send(.init(sessionID: sessionID, systemPrompt: bot.persona, messages: history))
                for try await event in stream { guard !Task.isCancelled else { break }; switch event {
                case .token(let token): assistant.content += token; objectWillChange.send()
                case .status(let value): if assistant.content.isEmpty { assistant.metadata["status"] = value }
                case .subAgent(let task):
                    subAgentTasks[bot.id, default: []].append(task)
                    bot.messages.append(ChatMessage(role: .assistant, content: task.title, presentation: .delegation, metadata: ["detail": task.detail, "status": task.status.rawValue]))
                case .approval(var request): request.botID = bot.id; request.profile = bot.hermesProfile ?? "default"; request.sessionID = sessionID; approvals.append(request)
                case .completed: break
                case .failed(let value): errorMessage = value; failed = true
                } }
            } catch is CancellationError {
                // User-initiated cancellation is not an error and must not notify.
            } catch { errorMessage = error.localizedDescription; failed = true }
            let cancelled = Task.isCancelled
            approvals.removeAll { $0.botID == bot.id && ($0.sessionID == nil || $0.sessionID == (bot.hermesSessionID ?? bot.id.uuidString)) }
            assistant.isStreaming = false
            if activeStreamToken == streamToken {
                isStreaming = false; streamTask = nil; activeStreamToken = nil; streamingBotID = nil; streamingAssistant = nil
            }
            save()
            if !cancelled && !failed && !assistant.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { notifyIfNeeded(bot: bot, message: assistant.content) }
        }
    }
    private func notifyIfNeeded(bot: Bot, message: String) {
        guard Bundle.main.bundleIdentifier != nil, bot.notificationsEnabled, UserDefaults.standard.bool(forKey: "notifications"), !NSApp.isActive else { return }
        let content = UNMutableNotificationContent(); content.title = bot.name; content.body = String(message.prefix(140)); content.sound = .default
        UNUserNotificationCenter.current().add(.init(identifier: UUID().uuidString, content: content, trigger: nil))
    }
    func stop() {
        guard isStreaming, let streamToken = activeStreamToken, stopInProgressForStream != streamToken else { return }
        stopInProgressForStream = streamToken
        let bot = streamingBotID.flatMap { id in bots.first { $0.id == id } }
        streamingAssistant?.isStreaming = false
        guard let bot, let activeBackend = try? backend(for: bot) else {
            streamTask?.cancel(); isStreaming = false
            if stopInProgressForStream == streamToken { stopInProgressForStream = nil }
            return
        }
        let taskToCancel = streamTask
        Task {
            do {
                // Capture the run before cancelling the SSE task, whose termination clears it.
                let target = try await activeBackend.stopTarget(sessionID: bot.hermesSessionID ?? bot.id.uuidString)
                taskToCancel?.cancel()
                didCancelLocalStream?()
                if activeStreamToken == streamToken { isStreaming = false }
                let outcome = try await activeBackend.requestStop(target)
                let feedback: String
                switch outcome {
                case .requested: feedback = "Stop requested from Hermes."
                case .disconnectedLegacy: feedback = "Stopped locally; this Hermes version has no run-control endpoint."
                case .noActiveRun: feedback = "Stopped locally before Hermes supplied a run ID."
                }
                bot.messages.append(ChatMessage(role: .system, content: feedback)); objectWillChange.send()
            } catch {
                taskToCancel?.cancel()
                if activeStreamToken == streamToken { isStreaming = false }
                errorMessage = "Hermes Stop failed: \(error.localizedDescription)"
            }
            if stopInProgressForStream == streamToken { stopInProgressForStream = nil }
            save()
        }
    }
    func decide(_ approval: ApprovalRequest, approved: Bool) {
        guard let botID = approval.botID, let bot = bots.first(where: { $0.id == botID }), let approvalBackend = try? backend(for: bot) else { return }
        Task {
            do {
                try await approvalBackend.resolveApproval(approval, approved: approved)
                approvals.removeAll { $0.id == approval.id }
                bot.messages.append(ChatMessage(role: .system, content: approved ? "Approved: \(approval.title)" : "Declined: \(approval.title)")); objectWillChange.send(); save()
            } catch { errorMessage = error.localizedDescription }
        }
    }
    func backend(for bot: Bot) throws -> any AgentBackend {
        if let backendFactory { return try backendFactory(bot) }
        switch bot.backend {
    case .mock: return MockBackend()
    case .hermes:
        guard let baseURL = HermesBackend.validatedBaseURL(UserDefaults.standard.string(forKey: "hermesBaseURL") ?? AppConstants.defaultHermesURL) else { throw BackendError.invalidURL }
        let profile = bot.hermesProfile ?? "default"
        let key = profile == "default" ? KeychainStore.get(account: "hermes") : KeychainStore.get(account: "hermes.\(profile)")
        return HermesBackend(baseURL: baseURL, apiKey: key, profile: profile)
    case .openClaw: return OpenClawBackend(gatewayURL: URL(string: UserDefaults.standard.string(forKey: "openClawURL") ?? ""))
    } }
}
