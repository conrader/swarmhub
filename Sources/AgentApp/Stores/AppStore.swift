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
    /// P10d: the Grok Bot import sheet, and whether Grok Bot is on this Mac at all (Tier 1: existence checks only,
    /// run once, on first use; false hides every door).
    @Published var showingGrokImport = false
    /// P21: what the setup window opens with (bumping `setupGeneration` restarts it), and `--setup-preview` (throwaway
    /// store, keys and settings; Settings are off).
    @Published var setupPrefill = SetupPrefill(); @Published var setupGeneration = 0; var isSetupPreview = false
    /// P25: the Gateway this setup-window run saved at Test; forgotten again unless Add keeps it.
    var setupCreatedGatewayID: String?
    lazy var grokBotPresent: Bool = GrokLocator.live().isPresent
    /// P14: the sidebar column is collapsed (the window has no title bar, so the toggle lives in the sidebar row and the headers).
    @Published var sidebarHidden = false
    @Published var infoTab = AgentInfoTab.overview
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
    /// P13 app-wide model defaults (store.json, this install only); empty until set in Settings → Models.
    @Published var modelDefaults = ModelDefaults()
    /// P22 bot manager: open management exchanges per manager bot, a request for a chat's composer, "Add" offers from a
    /// `bots` list, the clock the exchange window uses, and the new-profile probe's retries (~10 s).
    var managementExchanges: [UUID: ManagementExchange] = [:]; @Published var composerFill: ComposerFill?
    @Published var botOffers: [UUID: [BotOffer]] = [:]; var now: () -> Date = { .now }
    var botProbeAttempts = 4; var botProbeDelay: Duration = .milliseconds(2500)
    /// Tests: the manager text template instead of the bundled resource.
    var managerTemplateOverride: String?
    /// P20: unsent composer text per chat, read by the sidebar's "Draft:" line.
    let drafts = ComposerDrafts()
    let routines = RoutinesCache(); var routinePollTask: Task<Void, Never>?
    let keyStore: any HermesKeyStore; let defaults: UserDefaults; let hermesSession: URLSession
    /// P16: turn bookkeeping, the token autosave interval, the connectivity events and the reconcile timing (injectable).
    let turns = TurnBook(); var autosaveInterval: Duration = .seconds(2); var connectivity: (any ConnectivitySource)?
    var reconcileTiming = ReconcileTiming.standard
    var streamTask: Task<Void, Never>?; let fileURL: URL
    private(set) lazy var grokHistory = GrokHistoryStore(directory: fileURL.deletingLastPathComponent().appending(path: "grok-history", directoryHint: .isDirectory))
    var streamingBotID: UUID?; var streamingAssistant: ChatMessage?; var streamingConversation: (any Conversation)?
    var historyLoadTokens: [UUID: UUID] = [:]
    /// Prepended to every session id the app creates (chat, thread, group); `--e2e` sets `AppConstants.selfTestPrefix`.
    var sessionNamespace = ""
    var activeStreamToken: UUID?
    private var stopInProgressForStream: UUID?
    private(set) var persistenceEnabled = true
    let backendFactory: ((Bot) throws -> any AgentBackend)?
    /// P12: saved OpenClaw Gateways (no secrets) and the hub, created on first use so nothing connects at launch.
    @Published var openClawGateways: [OpenClawGateway] = []
    var injectedOpenClawHub: OpenClawHub?; var openClawWakeObserver: NSObjectProtocol?
    private(set) lazy var openClawHub: OpenClawHub = makeOpenClawHub()
    private let didCancelLocalStream: (() -> Void)?
    let reviewerTimeout: Duration

    init(demoMode: Bool = false, storeURL: URL? = nil, autoConfigureHermes: Bool = true, backendFactory: ((Bot) throws -> any AgentBackend)? = nil, didCancelLocalStream: (() -> Void)? = nil, reviewerTimeout: Duration = .seconds(15), keyStore: any HermesKeyStore = KeychainHermesKeyStore(), defaults: UserDefaults = .standard, hermesSession: URLSession = HermesURLSession.shared, connectivity: (any ConnectivitySource)? = nil, openClawHub: OpenClawHub? = nil) {
        self.keyStore = keyStore; self.defaults = defaults; self.hermesSession = hermesSession; self.connectivity = connectivity
        injectedOpenClawHub = openClawHub
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
                let file = try StoreFile.decode(Data(contentsOf: fileURL)); bots = file.bots; groups = file.groups; modelDefaults = file.modelDefaults ?? .init()
                turns.roundsAtLaunch = Set(groups.filter { $0.round != nil }.map(\.id))
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
            let bot = Bot(name: "Hermes", title: "Hermes Agent", description: "Default Hermes profile", backend: .hermes, hermesProfile: "default")
            bots = [bot]; save()
        }
        // P21 D3: a fresh install starts empty; the setup window or "Look around with sample agents" fills it.
        if !demoMode { migrateManagerRole(); loadOpenClawGateways() }
        if !demoMode, autoConfigureHermes { Task { await recoverLockedKeys() } }
        selectVisibleChat()
        if !demoMode, autoConfigureHermes, hermesConfigured, launchProbesGlobalHermes { Task { await refreshHermesAgents() } }
        botInfo.autoLoad = !demoMode && autoConfigureHermes; routines.autoLoad = botInfo.autoLoad
        if connectivity != nil { listenForConnectivity() }
    }

    func addBot(name: String, persona: String, backend: BackendKind, avatarName: BotAvatarName?, avatar: AvatarChoice = .unpicked, approvalMode: ApprovalMode = .ask, approvalRules: [ApprovalRule] = ApprovalRule.sensibleDefaults, reviewerBotID: UUID? = nil, openClaw: OpenClawBinding? = nil) { let bot = Bot(name: name, persona: persona, backend: backend, avatarName: avatarName, approvalMode: approvalMode, approvalRules: approvalRules, reviewerBotID: reviewerBotID); bot.openClaw = backend == .openClaw ? openClaw : nil; avatar.apply(to: bot); bots.insert(bot, at: 0); selectedBot = bot; rememberSelection(bot: bot); save() }
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
        bots.insert(bot, at: 0); selectedBot = bot; rememberSelection(bot: bot); save(); return bot
    }
    func delete(_ bot: Bot) { grokHistory.remove(bot.id); bots.removeAll { $0.id == bot.id }; groups.forEach { $0.memberIDs.removeAll { $0 == bot.id } }; if selectedBot == bot { if selectedGroup == nil { selectVisibleChat() } else { selectedBot = nil } }; save() }
    /// Writes store.json; a failed write is reported once per streak (P16) instead of being swallowed.
    func save() {
        guard persistenceEnabled else { return }
        do {
            try JSONEncoder().encode(storeFile).write(to: fileURL, options: .atomic)
            turns.saveFailing = false
        } catch {
            if !turns.saveFailing { errorMessage = "Could not save your chats: \(error.localizedDescription)" }
            turns.saveFailing = true
        }
    }
    /// Sends into the open thread or the main chat. While a turn streams, the text steers it when the
    /// server has `run_steer`; otherwise sending stays disabled until the turn ends.
    @discardableResult func send(text: String, attachments: [ChatAttachment] = []) -> Bool {
        guard let bot = selectedBot, !bot.isReadOnlyArchive, !bot.isGrokHistoryOnly, !needsKey(bot), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty else { return false }
        if let blocked = openClawBlock(bot) { errorMessage = blocked; return false }
        guard !isStreaming, streamTask == nil else { return steer(text: text, attachments: attachments, bot: bot) }
        let activeBackend: any AgentBackend; let images: [String]
        do { activeBackend = try backend(for: bot); images = try attachments.filter { $0.kind == .image }.map(attachmentEncoder.dataURL(for:)) }
        catch { errorMessage = error.localizedDescription; return false }
        let conversation: any Conversation = openThread(in: bot) ?? bot
        historyLoadTokens[bot.id] = nil
        conversation.messages.append(ChatMessage(role: .user, content: text, replyToID: replyTo?.id, attachments: attachments)); replyTo = nil; let assistant = ChatMessage(role: .assistant, content: "", isStreaming: true, turnState: .incomplete); conversation.messages.append(assistant)
        objectWillChange.send(); save(); isStreaming = true; streamingBotID = bot.id; streamingAssistant = assistant; streamingConversation = conversation
        let streamToken = UUID(); activeStreamToken = streamToken
        let systemPrompt = managementPrompt(for: bot, text: text, conversation: conversation)
        let history = chatHistory(conversation, excluding: assistant)
        streamTask = Task { [weak self] in
            await self?.runChatTurn(bot: bot, conversation: conversation, assistant: assistant, history: history, images: images, systemPrompt: systemPrompt, backend: activeBackend, token: streamToken)
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
        // P16: the row is `stopped` at once and never extended; a Retry still reading the box keeps its `notSent` row.
        if let row = streamingAssistant, row.turnState != .notSent { row.turnState = .stopped; row.metadata[TurnKey.why] = "stopped" }
        guard let bot, let activeBackend = try? backend(for: bot) else {
            streamTask?.cancel(); isStreaming = false
            if stopInProgressForStream == streamToken { stopInProgressForStream = nil }
            return
        }
        let taskToCancel = streamTask
        let stoppedAssistantID = streamingAssistant?.id
        let conversation: any Conversation = streamingConversation ?? bot
        let server = bot.backend.shortName // "Hermes" texts stay byte-identical (P12)
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
                case .requested: feedback = "Stop requested from \(server)."
                case .disconnectedLegacy: feedback = bot.backend == .openClaw ? "Stopped locally; this OpenClaw Gateway does not offer chat.abort." : "Stopped locally; this Hermes version has no run-control endpoint."
                case .noActiveRun: feedback = "Stopped locally before \(server) supplied a run ID."
                }
                let message = ChatMessage(role: .system, content: feedback)
                if let stoppedAssistantID, let index = conversation.messages.firstIndex(where: { $0.id == stoppedAssistantID }) {
                    conversation.messages.insert(message, at: index + 1)
                } else { conversation.messages.append(message) }
                objectWillChange.send()
            } catch {
                taskToCancel?.cancel()
                let message = ChatMessage(role: .system, content: "\(server) Stop failed: \(error.localizedDescription)")
                if let stoppedAssistantID, let index = conversation.messages.firstIndex(where: { $0.id == stoppedAssistantID }) {
                    conversation.messages.insert(message, at: index + 1)
                } else { conversation.messages.append(message) }
                objectWillChange.send()
                if activeStreamToken == streamToken {
                    isStreaming = false
                    errorMessage = "\(server) Stop failed: \(error.localizedDescription)"
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
        let key = keyStore.key(for: Self.keyAccount(forProfile: profile))
        if key.isEmpty, keyStore.needsReentry(Self.keyAccount(forProfile: profile)) { throw BackendError.unavailable(KeychainStore.reenterMessage) }
        return HermesBackend(baseURL: baseURL, apiKey: key, profile: profile, session: hermesSession)
    case .openClaw:
        guard let binding = bot.openClaw, let gateway = gateway(id: binding.gatewayID) else { throw BackendError.unavailable(OpenClawBackend.unboundMessage) }
        return OpenClawBackend(gateway: gateway, binding: binding, hub: openClawHub)
    } }
}
