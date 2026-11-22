import Combine
import Foundation
import AppKit
import UserNotifications

@MainActor final class AppStore: ObservableObject {
    @Published var bots: [Bot] = []
    @Published var selectedBot: Bot?
    /// The running turn of each conversation, keyed by its id (`AppStore+TurnSlots.swift`), and how many may run at once.
    @Published var runningTurns: [UUID: ConversationTurn] = [:]; var turnLimits = TurnLimits()
    @Published var showInfo = true; @Published var showingNewBot = false; @Published var showingTemplateImport = false; @Published var showingCommandPalette = false
    @Published var showingHiddenBots = false; @Published var replyTo: ChatMessage?
    /// The pane the Settings window shows when it next opens or is already open; it clears it.
    @Published var settingsPane: SettingsLayout.Pane?
    /// The Grok Bot import sheet, and whether Grok Bot is on this Mac at all (existence checks only, run once, on first
    /// use; false hides every door).
    @Published var showingGrokImport = false
    var grokDestination: GrokDestination?
    var setupForGrok = false
    var grokStartsWithExport = false
    /// Bumping `setupGeneration` restarts the setup window; `--setup-preview` runs on a throwaway store, keys and
    /// settings (Settings are off).
    @Published var setupGeneration = 0; var isSetupPreview = false
    /// The port forwards this app opened to Herdr servers reached over SSH (`AppStore+Herdr.swift`).
    let herdrTunnels = HerdrTunnels()
    var personTimezoneObserver: AnyCancellable?
    var personSettingsModels: [String: HerdrPersonSettings] = [:]
    /// The helper agents each Herdr bot's agent has now, by bot (`AppStore+HerdrHelpers.swift`); the helper open in the
    /// detail column; the poll that reads them, and the failed reads in a row per server.
    @Published var herdrHelpers: [UUID: HerdrClient.Helpers] = [:]; @Published var openHerdrHelper: HerdrHelperSelection?
    var teamPolling: Task<Void, Never>?
    var teamRegistrations: [String: Task<Bool, Error>] = [:]
    var teamSynced: [String: ([HerdrClient.TeamMember], Date, Bool)] = [:]
    @Published var teamErrors: [String: String] = [:]
    var herdrHelperPoll: Task<Void, Never>?; var herdrHelperFailures: [String: Int] = [:]
    /// The bots whose running turn is on the bridge's event stream: the stream brings their helpers, so the poll leaves them out.
    var herdrStreaming: Set<UUID> = []
    /// What each Herdr bot's agent runs on, as last read from its server (`refreshHerdrAgentReading`): the Details
    /// panel and the chat header show it by name.
    @Published var herdrAgentReadings: [UUID: HerdrAgentReading] = [:]
    /// Whether each Herdr bot's agent is running, and ready for a message or still starting (`AppStore+HerdrWarm.swift`):
    /// the chat header says it. `herdrWarming`: the starts ahead of time that are on their way, by bot; a message to
    /// such a bot waits for its start. `herdrNoWarmStarts`: the servers and agent programs that refused such a start.
    @Published var herdrReadiness: [UUID: HerdrAgentReadiness] = [:] { didSet { if herdrReadiness != oldValue { herdrPromptsFollowReadiness() } } }
    /// Waiting terminal prompts, keyed by the bot or group conversation ID.
    @Published var herdrPrompts: [UUID: HerdrPrompt] = [:]
    var herdrPromptBook = HerdrPromptBook()
    var herdrWarming: [UUID: Task<Void, Never>] = [:]
    var localServiceSetupInProgress = false
    @Published var herdrNoWarmStarts: Set<String> = []
    /// Applied to every Herdr client the store makes; tests point it at a scripted server.
    var herdrClientSetup: (@Sendable (inout HerdrClient) -> Void)?
    /// Each Herdr server's Skills section, by server id (`HerdrSkillsModel`).
    var herdrSkillModels: [String: HerdrSkillsModel] = [:]
    /// Each Herdr server's library, and skillshare on every server (`HerdrSkillLibraryModel.swift`).
    var herdrLibraryModels: [String: HerdrLibraryModel] = [:]; var herdrLibraryServersModel: HerdrLibraryServersModel?
    /// One per Herdr server: its project servers and projects (`HerdrProjectsModel`).
    var herdrProjectModels: [String: HerdrProjectsModel] = [:]
    /// The setup wizard's ending (`AppStore+SetupHerdr.swift`): the bot whose composer takes the keyboard once, and the
    /// chat it ended in with the number of messages it had then, which says that the first reply takes longer.
    @Published var composerFocus: UUID?
    var herdrLanding: (bot: UUID, messages: Int)?
    /// Requests of a main bot's reply that the app is settling right now (`AppStore+HerdrBots.swift`): not offered meanwhile.
    var herdrSettling: Set<String> = []
    lazy var grokBotPresent: Bool = GrokLocator.live().isPresent
    /// The sidebar column is collapsed (the window has no title bar, so the toggle lives in the sidebar row and the headers).
    @Published var sidebarHidden = false
    @Published var infoTab = AgentInfoTab.overview
    @Published var editingBot: Bot?; @Published var errorMessage: String?
    /// A message the transcript should scroll to (Media tab).
    @Published var scrollTarget: UUID?
    /// A saved document on its way from the Media tab into a chat's composer.
    @Published var pendingComposerAttachment: PendingComposerAttachment?
    /// The one-time caption under the composer after the first steer.
    @Published var steerHint: String?
    /// Group chats; `selectedGroup` wins over `selectedBot` in the detail column.
    @Published var groups: [GroupChat] = []
    @Published var selectedGroup: GroupChat?
    @Published var showingNewGroup = false
    var migratedGroupNames: [String] = []
    private(set) lazy var attachmentEncoder = AttachmentEncoder(directory: fileURL.deletingLastPathComponent().appending(path: "attachments", directoryHint: .isDirectory))
    /// The clock (tests set it).
    var now: () -> Date = { .now }
    /// Waits before a user's turn that never left the Mac is sent again (none in tests unless a test sets them), and the
    /// pause itself (tests return at once).
    var sendRetryDelays: [Duration] = TestRunGuard.isTestRun ? [] : [.seconds(1), .seconds(3), .seconds(8), .seconds(15)]
    var sendRetrySleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    /// Unsent composer text per chat, read by the sidebar's "Draft:" line.
    let drafts = ComposerDrafts()
    private var composerIntakes: [UUID: AttachmentIntake] = [:]

    func attachmentIntake(for conversationID: UUID) -> AttachmentIntake {
        if let intake = composerIntakes[conversationID] { return intake }
        let intake = AttachmentIntake()
        composerIntakes[conversationID] = intake
        return intake
    }

    func discardComposerAttachments(for conversationID: UUID) {
        if let intake = composerIntakes.removeValue(forKey: conversationID) { intake.discard(store: self) }
    }

    func confirmHerdrAttachments(_ bots: [Bot]) async -> Bool {
        let servers = Set(bots.filter { $0.backend == .herdr && !$0.isReadOnlyArchive }.map { herdrServer(for: $0).id })
        do {
            for id in servers {
                guard let server = herdrServer(id: id), try await herdrClient(for: server).workspace().attachments == true else {
                    throw BackendError.unavailable("This host cannot receive attachments. Update its workspace and Herdr Core, then try again.")
                }
            }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
    /// Where each chat was left and whether it is away from the newest message.
    let chatScroll = ChatScrollModel()
    let keyStore: any KeyStore; let defaults: UserDefaults
    /// Turn bookkeeping, the token autosave interval and the connectivity events (injectable).
    let turns = TurnBook(); var autosaveInterval: Duration = .seconds(2); var connectivity: (any ConnectivitySource)?
    /// The execution ledger (`runtime.sqlite`, opened by `journal()`).
    var runtime: (any RuntimeStoring)?
    let fileURL: URL
    private var writerLease: StoreWriterLease?
    var storeRevision: Data?
    var restoreUndoRevision: Data?
    /// Pins, sections and folds of the sidebar (`AppStore+SidebarSections.swift`).
    @Published var sidebar = SidebarOrganisation()
    var removedBots: [String: Set<String>] = [:]
    var deletedGroupIDs: [UUID] = []
    var pendingHerdrEndings: [HerdrAgentEnding] = []
    var busyHerdrEndings: Set<HerdrAgentEnding> = []
    /// A set-aside store (`store.json.corrupt-*`, a backup) this launch offers to restore (`AppStore+StoreRestore.swift`).
    @Published var storeRestoreOffer: StoreRestore.Offer?; @Published var storeRestoreNote: String?
    /// This launch moved an unreadable store.json aside.
    private(set) var unreadableStoreSetAside = false
    private(set) lazy var grokHistory = GrokHistoryStore(directory: fileURL.deletingLastPathComponent().appending(path: "grok-history", directoryHint: .isDirectory))
    /// Prepended to every session id the app creates (chat, group).
    var sessionNamespace = ""
    private(set) var persistenceEnabled = true
    let backendFactory: ((Bot) throws -> any AgentBackend)?
    let didCancelLocalStream: (() -> Void)?
    /// The launch work of a real window runs (`startLaunchWork`): off in tests, headless commands and the demo.
    var launchWorkEnabled = false

    /// `autoStart`: the launch work a real window does. Tests and headless commands pass false.
    /// `readOnly`: opening the store for `--render-snapshot` leaves the store file and settings untouched.
    init(demoMode: Bool = false, storeURL: URL? = nil, autoStart: Bool = true, readOnly: Bool = false, exclusiveWriter: Bool = false, backendFactory: ((Bot) throws -> any AgentBackend)? = nil, didCancelLocalStream: (() -> Void)? = nil, keyStore: any KeyStore = KeychainKeyStore(), defaults: UserDefaults = .standard, connectivity: (any ConnectivitySource)? = nil) {
        // A test run never opens the real store.json or the standard defaults; either is reported and replaced.
        var storeURL = storeURL, defaults = defaults
        if storeURL == nil, TestRunGuard.refuses("AppStore without storeURL (the real store.json)") {
            storeURL = FileManager.default.temporaryDirectory.appending(path: "AgentAppTests-unguarded-\(UUID().uuidString)/store.json")
        }
        if defaults === UserDefaults.standard, TestRunGuard.refuses("AppStore on UserDefaults.standard") { defaults = TestRunGuard.scratchDefaults("unguarded-\(UUID().uuidString)") }
        self.keyStore = keyStore; self.defaults = defaults; self.connectivity = connectivity
        self.backendFactory = backendFactory
        self.didCancelLocalStream = didCancelLocalStream
        let directory = storeURL?.deletingLastPathComponent() ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appending(path: "AgentApp", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); fileURL = storeURL ?? directory.appending(path: "store.json")
        var liveStoreIsHealthy = false
        if !readOnly, !demoMode, storeURL == nil || exclusiveWriter {
            do { writerLease = try StoreWriterLease(store: fileURL) }
            catch {
                persistenceEnabled = false
                errorMessage = "SwarmHub could not acquire its store. Close the other SwarmHub window or import and reopen."
                return
            }
        }
        if readOnly { persistenceEnabled = false }
        if demoMode {
            persistenceEnabled = false
            loadDemoData(includeActivity: true)
        } else if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let data = try Data(contentsOf: fileURL)
                storeRevision = data
                let file = try StoreFile.decode(data)
                if !readOnly, file.bots.contains(where: \.needsRetiredBackendMigration) {
                    do { try data.write(to: fileURL.appendingPathExtension("before-herdr-only-\(UUID().uuidString)"), options: .atomic) }
                    catch {
                        persistenceEnabled = false
                        errorMessage = "Could not save a pre-migration copy. The saved store was kept."
                    }
                }
                adoptStoreFile(file)
                if !readOnly { recoverRestoreUndoIfAvailable(data) }
                if !migratedGroupNames.isEmpty, persistenceEnabled { save() }
                liveStoreIsHealthy = true
            } catch {
                persistenceEnabled = false
                if readOnly {
                    errorMessage = "Could not read store.json: \(error.localizedDescription)"
                } else {
                    let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
                    let backup = fileURL.appendingPathExtension("corrupt-\(stamp)-\(UUID().uuidString)")
                    do { try FileManager.default.moveItem(at: fileURL, to: backup); unreadableStoreSetAside = true; storeRevision = nil }
                    catch { errorMessage = "Could not read or back up store.json: \(error.localizedDescription)" }
                    if unreadableStoreSetAside { errorMessage = "The saved store could not be decoded. It was moved to \(backup.lastPathComponent)." }
                }
            }
            if herdrConfigured { bots.filter(\.isDemo).forEach { $0.isHidden = true } }
        }
        if !demoMode, !readOnly {
            if !liveStoreIsHealthy {
                storeRestoreOffer = StoreRestore.offer(
                    store: fileURL, resolvedThrough: defaults.object(forKey: StoreRestore.decisionKey(for: fileURL)) as? Date,
                    declined: Set(defaults.stringArray(forKey: StoreRestore.declinedKey) ?? []),
                    hideSamples: herdrConfigured)
                if storeRestoreOffer != nil { persistenceEnabled = false }
                else if unreadableStoreSetAside { persistenceEnabled = true }
            }
        }
        // A fresh install starts empty; the setup window or "Look around with sample agents" fills it.
        if !demoMode, !readOnly, persistenceEnabled { migrateSampleBots(); restoreLedger() }
        selectVisibleChat()
        launchWorkEnabled = !demoMode && autoStart
        if connectivity != nil { listenForConnectivity() }
    }

    /// The decoded store becomes this window's state (launch, and the restore of a set-aside store).
    func adoptStoreFile(_ file: StoreFile) {
        bots = file.bots; groups = file.groups; removedBots = file.removedBots ?? [:]; deletedGroupIDs = file.deletedGroupIDs ?? []
        pendingHerdrEndings = file.pendingHerdrEndings ?? []
        chatScroll.restore(file.scrollPositions)
        sidebar = file.sidebar ?? SidebarOrganisation(); sidebar.prune(keeping: Set(bots.map(\.id) + groups.map(\.id)))
        turns.roundsAtLaunch = Set(groups.filter { $0.round != nil }.map(\.id))
        migrateArchivedGroups()
    }

    /// A restored store is this launch's store again, saved as store.json.
    func adoptRestoredStore(_ file: StoreFile) {
        persistenceEnabled = true; unreadableStoreSetAside = false
        adoptStoreFile(file)
        if herdrConfigured { bots.filter(\.isDemo).forEach { $0.isHidden = true } }
    }
    /// A recovery choice can conflict with another launch that has already saved a store.
    var writerLeaseAvailable: Bool { writerLease != nil }
    func pauseSavingForRecovery() { persistenceEnabled = false }

    func resumeSavingAfterRecovery() {
        guard !FileManager.default.fileExists(atPath: fileURL.path) else { return }
        persistenceEnabled = true; unreadableStoreSetAside = false
        if errorMessage?.hasPrefix("The saved store could not be decoded.") == true { errorMessage = nil }
    }
    func addBot(name: String, persona: String, backend: BackendKind, avatarName: BotAvatarName?, avatar: AvatarChoice = .unpicked, template: String? = nil, model: String = HerdrModelChoice.recommended) {
        guard storeRestoreOffer == nil else { return }
        let bot = Bot(name: name, persona: persona, backend: backend, avatarName: avatarName)
        avatar.apply(to: bot)
        bot.offersReleaseNotesExample = backend == .herdr
        if backend == .herdr {
            if let template {
                setHerdrTemplate(template, for: bot)
            } else if let main = herdrMainBot(on: herdrServer(for: bot)) {
                setHerdrTemplate(herdrTemplate(for: main) ?? "", for: bot)
            }
            setHerdrModel(model, for: bot)
        }
        bots.insert(bot, at: 0)
        selectedBot = bot
        rememberSelection(bot: bot)
        save()
    }
    /// A template becomes a Herdr bot on the first server: its name, title, description, instructions and avatar.
    @discardableResult func importTemplate(_ plan: TemplateImportPlan) -> Bot {
        let manifest = plan.manifest
        let bot = Bot(name: manifest.name, title: manifest.title, description: manifest.description, persona: manifest.instructions, backend: .herdr, avatarName: plan.avatarName)
        setHerdrServer(herdrServers[0].id, for: bot)
        bots.insert(bot, at: 0); selectedBot = bot; rememberSelection(bot: bot); save(); return bot
    }
    /// Removes the bot and its chat from this Mac, and ends its agent on its server (`AppStore+HerdrRemoval.swift`).
    func delete(_ bot: Bot) {
        guard storeRestoreOffer == nil else { return }
        let oldBots = bots, oldMembers = groups.map(\.memberIDs), oldRemoved = removedBots
        let oldEndings = pendingHerdrEndings
        let endings = herdrEndingsForRemoval(of: bot)
        pendingHerdrEndings.append(contentsOf: endings.filter { !oldEndings.contains($0) })
        if bot.backend == .herdr, !bot.isReadOnlyArchive, !bot.isDemo {
            removedBots[herdrServer(for: bot).id, default: []].insert(bot.id.uuidString.lowercased())
        }
        bots.removeAll { $0.id == bot.id }; groups.forEach { $0.memberIDs.removeAll { $0 == bot.id } }
        if selectedBot == bot { if selectedGroup == nil { selectVisibleChat() } else { selectedBot = nil } }
        if persistenceEnabled {
            save()
            if turns.saveFailing {
                bots = oldBots; removedBots = oldRemoved; pendingHerdrEndings = oldEndings
                for (group, ids) in zip(groups, oldMembers) { group.memberIDs = ids }
                selectVisibleChat()
                return
            }
        }
        grokHistory.remove(bot.id)
        discardComposerAttachments(for: bot.id)
        if !endings.isEmpty { herdrAgentRemoved(bot, endings: endings) }
    }
    /// Writes store.json; a failed write is reported once per streak instead of being swallowed.
    var storeFile: StoreFile {
        var file = StoreFile(bots: bots, groups: groups, scrollPositions: chatScroll.stored)
        file.sidebar = sidebar.isEmpty ? nil : sidebar
        file.removedBots = removedBots.isEmpty ? nil : removedBots
        file.deletedGroupIDs = deletedGroupIDs.isEmpty ? nil : deletedGroupIDs
        file.pendingHerdrEndings = pendingHerdrEndings.isEmpty ? nil : pendingHerdrEndings
        return file
    }

    func writeStore() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(storeFile)
        guard try currentStoreRevision() == storeRevision else {
            throw BackendError.unavailable("The store changed on disk. Reopen SwarmHub before saving.")
        }
        if data != storeRevision {
            try data.write(to: fileURL, options: .atomic)
            storeRevision = data
        }
    }

    func currentStoreRevision() throws -> Data? {
        do { return try Data(contentsOf: fileURL) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
    }

    func save() {
        guard persistenceEnabled else { return }
        do {
            try writeStore()
            turns.saveFailing = false
        } catch {
            if !turns.saveFailing { errorMessage = "Could not save your chats: \(error.localizedDescription)" }
            turns.saveFailing = true
        }
    }
    /// Sends into the selected bot's chat. While that chat's turn streams, the text steers it when the agent takes
    /// steers; otherwise it waits as the chat's next message, and the turn is never stopped. Other chats never block
    /// it; when the turn limit is reached the message waits as the chat's next message.
    @discardableResult func send(text: String, attachments: [ChatAttachment] = []) -> Bool {
        guard storeRestoreOffer == nil, let bot = selectedBot, !bot.isReadOnlyArchive, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty else { return false }
        if bot.backend == .herdr, !validateHerdrDraft(text, attachments: attachments, bot: bot) { return false }
        guard isIdle(bot) else { return steer(text: text, attachments: attachments, bot: bot) }
        guard send(text: text, attachments: attachments, bot: bot, conversation: bot, replyToID: replyTo?.id, waitWhenFull: true) else { return false }
        replyTo = nil
        return true
    }
    /// A new turn in `conversation` (the bot's chat), whatever is selected; never steers. Refused while that chat has
    /// a turn; at the turn limit it is refused, or waits as the chat's next message (`waitWhenFull`, the composer), as
    /// does a message sent while earlier ones still wait there.
    @discardableResult func send(text: String, attachments: [ChatAttachment] = [], bot: Bot, conversation: any Conversation, replyToID: UUID?, waitWhenFull: Bool = false,
                                 metadata: [String: String] = [:]) -> Bool {
        guard storeRestoreOffer == nil, !bot.isReadOnlyArchive, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty else { return false }
        guard isIdle(conversation) else { return false }
        if bot.backend == .herdr, !validateHerdrDraft(text, attachments: attachments, bot: bot) { return false }
        let full = turnCapacityProblem(for: [bot])
        if let full, !waitWhenFull { errorMessage = full; return false }
        let user = ChatMessage(role: .user, content: text, metadata: metadata, replyToID: replyToID, attachments: attachments)
        let activeBackend: any AgentBackend; let images: [String]
        do {
            try validateArtifactAccess(user, botID: bot.id)
            activeBackend = try backend(for: bot); images = try attachments.filter { $0.kind == .image }.map(attachmentEncoder.dataURL(for:))
        } catch { errorMessage = error.localizedDescription; return false }
        steerHint = nil
        captureAttachments(user, readers: [bot.id])
        if conversation === bot { bot.offersReleaseNotesExample = false }
        conversation.messages.append(user)
        if let reason = full ?? (hasWaitingTurn(in: conversation) ? TurnWaitCopy.behind : nil) { return waitForTurn(user, in: conversation, reason: reason) }
        startChatTurn(bot: bot, conversation: conversation, user: user, images: images, backend: activeBackend)
        return true
    }
    func validateHerdrDraft(_ text: String, attachments: [ChatAttachment], bot: Bot? = nil) -> Bool {
        do {
            try HerdrClient.validateMessage(text)
            try HerdrClient.TaskFile.validate(attachments.map(attachmentEncoder.taskFile(for:)))
            if let bot, bot.messages.allSatisfy({ $0.role != .assistant }), let backend = try? herdrBackend(for: bot) {
                try HerdrClient.validateMessage(text, limit: HerdrClient.firstMessageBudget(
                    instructions: backend.launchInstructions, hasFiles: !attachments.isEmpty))
            }
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    /// Starts the turn answering `user`, a row of `conversation`. The reply goes right under it and the turn sends the
    /// chat only up to it: messages queued after it wait below and go in their own turns.
    func startChatTurn(bot: Bot, conversation: any Conversation, user: ChatMessage, images: [String] = [], backend activeBackend: any AgentBackend) {
        let herdr = activeBackend is HerdrBackend
        let files: [HerdrClient.TaskFile]
        do { files = herdr ? try user.attachments.map(attachmentEncoder.taskFile(for:)) : [] }
        catch { errorMessage = error.localizedDescription; return }
        let assistant = ChatMessage(role: .assistant, content: "", isStreaming: true, turnState: .incomplete)
        if let index = conversation.messages.firstIndex(where: { $0 === user }) { conversation.messages.insert(assistant, at: index + 1) } else { conversation.messages.append(assistant) }
        let turn = beginTurn(in: conversation, bot: bot, assistant: assistant)
        objectWillChange.send(); save()
        let streamToken = turn.token
        let history = chatHistory(conversation, upTo: conversation.messages.contains { $0 === user } ? user : nil, excluding: assistant, inlineFiles: !herdr)
        turn.task = Task { [weak self] in
            await self?.runChatTurn(bot: bot, conversation: conversation, assistant: assistant, history: history, images: herdr ? [] : images, systemPrompt: bot.outboundPersona,
                                    backend: activeBackend, token: streamToken, files: files)
        }
    }
    func notifyIfNeeded(bot: Bot, message: String) {
        guard !SilentReply.isSilent(message), Bundle.main.bundleIdentifier != nil, bot.notificationsEnabled, UserDefaults.standard.bool(forKey: "notifications"), let app = NSApp, !app.isActive else { return }
        let content = UNMutableNotificationContent(); content.title = bot.name; content.body = String(message.prefix(140)); content.sound = .default
        UNUserNotificationCenter.current().add(.init(identifier: UUID().uuidString, content: content, trigger: nil))
    }
    func backend(for bot: Bot) throws -> any AgentBackend {
        if let backendFactory { return try backendFactory(bot) }
        switch bot.backend {
        case .mock: return MockBackend()
        case .herdr: return try herdrBackend(for: bot)
        }
    }
}
