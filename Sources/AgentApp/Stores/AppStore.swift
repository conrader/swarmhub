import Combine
import Foundation
import AppKit
import UserNotifications


@MainActor final class AppStore: ObservableObject {
    @Published var bots: [Bot] = []; @Published var selectedBot: Bot?; @Published var isStreaming = false
    @Published var approvals: [ApprovalRequest] = []
    @Published var subAgentTasks: [UUID: [SubAgentTask]] = [:]
    @Published var showInfo = true; @Published var showingNewBot = false; @Published var showingTemplateImport = false; @Published var showingCommandPalette = false
    @Published var showingHiddenBots = false; @Published var replyTo: ChatMessage?
    @Published var editingBot: Bot?; @Published var errorMessage: String?
    /// Profiles whose `/p/<profile>/` prefix the server ignored (multiplexing off). Never routed to.
    @Published var prefixIgnoredHermesProfiles: Set<String> = []
    /// P4 chat: per-bot `/v1/capabilities` flags, the open thread of the selected bot, whether the running
    /// turn takes steer messages, and a message the transcript should scroll to (Media tab).
    @Published var botFeatures: [UUID: Set<String>] = [:]; @Published var openThreadID: UUID?
    @Published var steerAvailable = false; @Published var scrollTarget: UUID?
    /// P5 group chats; `selectedGroup` wins over `selectedBot` in the detail column.
    @Published var groups: [GroupChat] = []; @Published var selectedGroup: GroupChat?; @Published var showingNewGroup = false
    var groupRun: GroupRun?; var migratedGroupNames: [String] = []
    private(set) lazy var attachmentEncoder = AttachmentEncoder(directory: fileURL.deletingLastPathComponent().appending(path: "attachments", directoryHint: .isDirectory))
    let botInfo = BotInfoCache()
    let routines = RoutinesCache(); var routinePollTask: Task<Void, Never>?
    let keyStore: any HermesKeyStore; let defaults: UserDefaults; let hermesSession: URLSession
    var streamTask: Task<Void, Never>?; let fileURL: URL
    private(set) lazy var grokHistory = GrokHistoryStore(directory: fileURL.deletingLastPathComponent().appending(path: "grok-history", directoryHint: .isDirectory))
    var streamingBotID: UUID?; var streamingAssistant: ChatMessage?; var streamingConversation: (any Conversation)?
    var historyLoadTokens: [UUID: UUID] = [:]
    /// Prepended to every session id the app creates (chat, thread, group); `--e2e` sets `torvli-selftest-`.
    var sessionNamespace = ""
    var activeStreamToken: UUID?
    private var stopInProgressForStream: UUID?
    private(set) var persistenceEnabled = true
    let backendFactory: ((Bot) throws -> any AgentBackend)?
    private let didCancelLocalStream: (() -> Void)?
    let reviewerTimeout: Duration

    init(demoMode: Bool = false, storeURL: URL? = nil, autoConfigureHermes: Bool = true, backendFactory: ((Bot) throws -> any AgentBackend)? = nil, didCancelLocalStream: (() -> Void)? = nil, reviewerTimeout: Duration = .seconds(15), keyStore: any HermesKeyStore = KeychainHermesKeyStore(), defaults: UserDefaults = .standard, hermesSession: URLSession = .shared) {
        self.keyStore = keyStore; self.defaults = defaults; self.hermesSession = hermesSession
        self.backendFactory = backendFactory
        self.didCancelLocalStream = didCancelLocalStream
        self.reviewerTimeout = reviewerTimeout
        let directory = storeURL?.deletingLastPathComponent() ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appending(path: "AgentApp", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); fileURL = storeURL ?? directory.appending(path: "store.json")
        if demoMode {
            persistenceEnabled = false
            loadDemoData(includeActivity: true)
        } else if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let file = try StoreFile.decode(Data(contentsOf: fileURL)); bots = file.bots; groups = file.groups
                if !migrateArchivedGroups().isEmpty { save() }
                var migratedLegacyApprovalRules = false
                for bot in bots {
                    let legacyRules = bot.approvalRules.filter {
                        $0.actionPattern == "read*" && $0.commandPattern == "*" && $0.outcome == .allow
                    }
                    guard !legacyRules.isEmpty else { continue }
                    let legacyRuleIDs = Set(legacyRules.map(\.id))
                    bot.approvalRules.removeAll { legacyRuleIDs.contains($0.id) }
                    for rule in legacyRules {
                        bot.approvalAudit.append(.init(
                            approvalID: rule.id,
                            actionKind: rule.actionPattern,
                            outcome: .denied,
                            decidedBy: "system:migration",
                            reason: "Migration removed legacy broad read*/* automatic-allow rule."
                        ))
                    }
                    if bot.approvalAudit.count > 500 { bot.approvalAudit.removeFirst(bot.approvalAudit.count - 500) }
                    migratedLegacyApprovalRules = true
                }
                if migratedLegacyApprovalRules { save() }
            } catch {
                persistenceEnabled = false
                let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
                let backup = fileURL.deletingLastPathComponent().appending(path: "store.json.corrupt-\(stamp)")
                do { try FileManager.default.moveItem(at: fileURL, to: backup) }
                catch { errorMessage = "Could not read or back up store.json: \(error.localizedDescription)" }
                if errorMessage == nil { errorMessage = "The saved store could not be decoded. It was moved to \(backup.lastPathComponent); saving is disabled for this launch." }
            }
            if hermesConfigured { bots.filter(\.isDemo).forEach { $0.isHidden = true } }
        } else if hermesConfigured {
            let bot = Bot(name: "Hermes", title: "Hermes Agent", description: "Default Hermes profile", backend: .hermes, avatarName: .faceCoral, hermesProfile: "default")
            bots = [bot]; save()
        } else {
            loadDemoData(persist: true)
        }
        selectedBot = bots.first
        if !demoMode, autoConfigureHermes, hermesConfigured, launchProbesGlobalHermes { Task { await refreshHermesAgents() } }
        botInfo.autoLoad = !demoMode && autoConfigureHermes; routines.autoLoad = botInfo.autoLoad
    }

    static var hasHermesConfiguration: Bool { UserDefaults.standard.object(forKey: "hermesBaseURL") != nil || !KeychainStore.get(account: "hermes").isEmpty }

    func addBot(name: String, persona: String, backend: BackendKind, avatarName: BotAvatarName, approvalMode: ApprovalMode = .ask, approvalRules: [ApprovalRule] = ApprovalRule.sensibleDefaults, reviewerBotID: UUID? = nil) { let bot = Bot(name: name, persona: persona, backend: backend, avatarName: avatarName, approvalMode: approvalMode, approvalRules: approvalRules, reviewerBotID: reviewerBotID); bots.insert(bot, at: 0); selectedBot = bot; save() }
    @discardableResult func importTemplate(_ plan: TemplateImportPlan) -> Bot {
        let manifest = plan.manifest
        let memories = manifest.memories.map { "\($0.name): \($0.value)" }
        let bot = Bot(
            name: manifest.name, title: manifest.title, description: manifest.description,
            persona: manifest.instructions, backend: hermesConfigured ? .hermes : .mock,
            avatarName: plan.avatarName, memorySummary: memories.joined(separator: "\n"),
            skills: manifest.skills.map(\.name), importedMemories: memories,
            importedSkills: manifest.skills, requestedConnectorIDs: plan.mappedConnectorIDs,
            gettingStartedSkill: manifest.gettingStartedSkill, routines: plan.routines,
            hermesProfile: hermesConfigured ? (plan.hermesProfile ?? "default") : nil
        )
        // Imported data remains inert: connectors require grants, cron routines and the
        // first-conversation skill remain disabled, and no server mutation occurs here.
        bot.routines.indices.forEach { bot.routines[$0].isEnabled = false }
        bot.gettingStartedSkill?.isEnabled = false
        bots.insert(bot, at: 0); selectedBot = bot; save(); return bot
    }
    func delete(_ bot: Bot) { grokHistory.remove(bot.id); bots.removeAll { $0.id == bot.id }; groups.forEach { $0.memberIDs.removeAll { $0 == bot.id } }; if selectedBot == bot { selectedBot = bots.first }; save() }
    func save() { guard persistenceEnabled, let data = try? JSONEncoder().encode(StoreFile(bots: bots, groups: groups)) else { return }; try? data.write(to: fileURL, options: .atomic) }
    /// Sends into the open thread or the main chat. While a turn streams, the text steers it when the
    /// server has `run_steer`; otherwise sending stays disabled until the turn ends.
    @discardableResult func send(text: String, attachments: [ChatAttachment] = []) -> Bool {
        guard let bot = selectedBot, !bot.isReadOnlyArchive, !bot.isGrokHistoryOnly, !needsKey(bot), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty else { return false }
        guard !isStreaming, streamTask == nil else { return steer(text: text, attachments: attachments, bot: bot) }
        let activeBackend: any AgentBackend; let images: [String]
        do { activeBackend = try backend(for: bot); images = try attachments.filter { $0.kind == .image }.map(attachmentEncoder.dataURL(for:)) }
        catch { errorMessage = error.localizedDescription; return false }
        let conversation: any Conversation = openThread(in: bot) ?? bot
        historyLoadTokens[bot.id] = nil
        conversation.messages.append(ChatMessage(role: .user, content: text, replyToID: replyTo?.id, attachments: attachments)); replyTo = nil; let assistant = ChatMessage(role: .assistant, content: "", isStreaming: true); conversation.messages.append(assistant)
        objectWillChange.send(); save(); isStreaming = true; streamingBotID = bot.id; streamingAssistant = assistant; streamingConversation = conversation
        let streamToken = UUID(); activeStreamToken = streamToken
        let history = conversation.messages.filter { $0.id != assistant.id && !$0.isSteer }.map { (role: $0.role.rawValue, content: $0.outgoingText) }
        streamTask = Task { [weak self] in
            guard let self else { return }
            var failed = false
            do {
                if conversation.hermesSessionID == nil, conversation === bot, try await activeBackend.sessionTransport() == .nativeSessions {
                    conversation.hermesSessionID = try await activeBackend.createSession(title: bot.name, systemPrompt: bot.persona, id: "\(sessionNamespace)agentapp_\(bot.id.uuidString.lowercased())")
                    save()
                }
                let sessionID = conversation.hermesSessionID ?? bot.id.uuidString
                let stream = try await activeBackend.send(.init(sessionID: sessionID, systemPrompt: bot.persona, messages: history, images: images))
                if activeStreamToken == streamToken { steerAvailable = (try? await activeBackend.features())?.contains("run_steer") == true }
                for try await event in stream { guard !Task.isCancelled else { break }; switch event {
                case .token(let token): assistant.content += token; objectWillChange.send()
                case .status(let value): if assistant.content.isEmpty { assistant.metadata["status"] = value }
                case .subAgent(let task):
                    subAgentTasks[bot.id, default: []].append(task)
                    conversation.messages.append(ChatMessage(role: .assistant, content: task.title, presentation: .delegation, metadata: ["detail": task.detail, "status": task.status.rawValue]))
                case .approval(var request):
                    request.botID = bot.id; request.profile = bot.hermesProfile ?? "default"; request.sessionID = sessionID
                    await routeApproval(request, for: bot, backend: activeBackend)
                case .completed: break
                case .failed(let value): errorMessage = value; failed = true
                } }
            } catch is CancellationError {
                // User-initiated cancellation is not an error and must not notify.
            } catch let error as URLError where error.code == .cancelled && Task.isCancelled {
                // URLSession reports cancellation this way when Stop lands during setup/first turn.
            } catch { errorMessage = error.localizedDescription; failed = true }
            let cancelled = Task.isCancelled
            let abandoned = approvals.filter { $0.botID == bot.id && ($0.sessionID == nil || $0.sessionID == (conversation.hermesSessionID ?? bot.id.uuidString)) }
            for approval in abandoned {
                appendAudit(to: bot, approval: approval, outcome: .denied, decidedBy: "system", reason: cancelled ? "Run stopped; pending approval was cancelled." : "Run ended; pending approval was cancelled.")
            }
            approvals.removeAll { abandoned.map(\.id).contains($0.id) }
            assistant.isStreaming = false
            if activeStreamToken == streamToken {
                isStreaming = false; streamTask = nil; activeStreamToken = nil; streamingBotID = nil; streamingAssistant = nil; streamingConversation = nil; steerAvailable = false
            }
            save()
            if !cancelled && !failed && !assistant.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { notifyIfNeeded(bot: bot, message: assistant.content) }
        }
        return true
    }
    var isIdle: Bool { streamTask == nil }
    func notifyIfNeeded(bot: Bot, message: String) {
        guard Bundle.main.bundleIdentifier != nil, bot.notificationsEnabled, UserDefaults.standard.bool(forKey: "notifications"), let app = NSApp, !app.isActive else { return }
        let content = UNMutableNotificationContent(); content.title = bot.name; content.body = String(message.prefix(140)); content.sound = .default
        UNUserNotificationCenter.current().add(.init(identifier: UUID().uuidString, content: content, trigger: nil))
    }
    func stop() {
        guard isStreaming, let streamToken = activeStreamToken, stopInProgressForStream != streamToken else { return }
        stopInProgressForStream = streamToken; groupRun?.stopped = true
        let bot = streamingBotID.flatMap { id in bots.first { $0.id == id } }
        streamingAssistant?.isStreaming = false; steerAvailable = false
        guard let bot, let activeBackend = try? backend(for: bot) else {
            streamTask?.cancel(); isStreaming = false
            if stopInProgressForStream == streamToken { stopInProgressForStream = nil }
            return
        }
        let taskToCancel = streamTask
        let stoppedAssistantID = streamingAssistant?.id
        let conversation: any Conversation = streamingConversation ?? bot
        Task {
            do {
                // Capture the run before cancelling the SSE task, whose termination clears it.
                let target = try await activeBackend.stopTarget(sessionID: conversation.hermesSessionID ?? bot.id.uuidString)
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
                let message = ChatMessage(role: .system, content: feedback)
                if let stoppedAssistantID, let index = conversation.messages.firstIndex(where: { $0.id == stoppedAssistantID }) {
                    conversation.messages.insert(message, at: index + 1)
                } else { conversation.messages.append(message) }
                objectWillChange.send()
            } catch {
                taskToCancel?.cancel()
                let message = ChatMessage(role: .system, content: "Hermes Stop failed: \(error.localizedDescription)")
                if let stoppedAssistantID, let index = conversation.messages.firstIndex(where: { $0.id == stoppedAssistantID }) {
                    conversation.messages.insert(message, at: index + 1)
                } else { conversation.messages.append(message) }
                objectWillChange.send()
                if activeStreamToken == streamToken {
                    isStreaming = false
                    errorMessage = "Hermes Stop failed: \(error.localizedDescription)"
                }
            }
            if stopInProgressForStream == streamToken { stopInProgressForStream = nil }
            save()
        }
    }
    func backend(for bot: Bot) throws -> any AgentBackend {
        if bot.backend == .hermes, let profile = bot.hermesProfile, prefixIgnoredHermesProfiles.contains(profile) { throw BackendError.unavailable("\(profile): \(HermesBackend.multiplexOffMessage)") }
        if bot.isGrokHistoryOnly { throw BackendError.unavailable("History only — not connected to a Hermes profile yet.") }
        if let backendFactory { return try backendFactory(bot) }
        switch bot.backend {
    case .mock: return MockBackend()
    case .hermes:
        guard let baseURL = HermesBackend.validatedBaseURL(bot.hermesBaseURL ?? defaults.string(forKey: "hermesBaseURL") ?? AppConstants.defaultHermesURL) else { throw BackendError.invalidURL }
        let profile = bot.hermesProfile ?? "default"
        let key = keyStore.key(for: profile == "default" ? "hermes" : "hermes.\(profile)")
        return HermesBackend(baseURL: baseURL, apiKey: key, profile: profile, session: hermesSession)
    case .openClaw: return OpenClawBackend(gatewayURL: URL(string: UserDefaults.standard.string(forKey: "openClawURL") ?? ""))
    } }
}
