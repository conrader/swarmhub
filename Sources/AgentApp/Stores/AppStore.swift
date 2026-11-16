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
    /// The Advanced pane the Settings window shows when it next opens or is already open; it clears it.
    @Published var settingsPane: SettingsLayout.AdvancedPane?
    /// The Grok Bot import sheet, and whether Grok Bot is on this Mac at all (existence checks only, run once, on first
    /// use; false hides every door).
    @Published var showingGrokImport = false
    /// Bumping `setupGeneration` restarts the setup window; `--setup-preview` runs on a throwaway store, keys and
    /// settings (Settings are off).
    @Published var setupGeneration = 0; var isSetupPreview = false
    /// The port forwards this app opened to Herdr servers reached over SSH (`AppStore+Herdr.swift`).
    let herdrTunnels = HerdrTunnels()
    /// The helper agents each Herdr bot's agent has now, by bot (`AppStore+HerdrHelpers.swift`); the helper open in the
    /// detail column; the poll that reads them, and the failed reads in a row per server.
    @Published var herdrHelpers: [UUID: HerdrClient.Helpers] = [:]; @Published var openHerdrHelper: HerdrHelperSelection?
    var herdrHelperPoll: Task<Void, Never>?; var herdrHelperFailures: [String: Int] = [:]
    /// The bots whose running turn is on the bridge's event stream: the stream brings their helpers, so the poll leaves them out.
    var herdrStreaming: Set<UUID> = []
    /// What each Herdr bot's agent runs on, as last read from its server (`refreshHerdrAgentReading`): the Details
    /// panel and the chat header show it by name.
    @Published var herdrAgentReadings: [UUID: HerdrAgentReading] = [:]
    /// Each Herdr server's Skills section, by server id (`HerdrSkillsModel`).
    var herdrSkillModels: [String: HerdrSkillsModel] = [:]
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
    /// Where each chat was left and whether it is away from the newest message.
    let chatScroll = ChatScrollModel()
    /// Folded ```swarmhub lines the user opened (memory only).
    let technicalFolds = TechnicalFolds()
    let keyStore: any KeyStore; let defaults: UserDefaults
    /// Turn bookkeeping, the token autosave interval and the connectivity events (injectable).
    let turns = TurnBook(); var autosaveInterval: Duration = .seconds(2); var connectivity: (any ConnectivitySource)?
    /// The execution ledger (`runtime.sqlite`, opened by `journal()`).
    var runtime: (any RuntimeStoring)?
    let fileURL: URL
    /// A set-aside store (`store.json.corrupt-*`, a backup) this launch offers to restore (`AppStore+StoreRestore.swift`).
    @Published var storeRestoreOffer: StoreRestore.Offer?; @Published var storeRestoreNote: String?
    /// This launch moved an unreadable store.json aside (so saving is off until Restore or Start fresh).
    private(set) var unreadableStoreSetAside = false
    /// The line that says bots of an older version were removed and where the backup is (`LegacyStore`); shown until dismissed.
    @Published var legacyNotice: String?
    private(set) lazy var grokHistory = GrokHistoryStore(directory: fileURL.deletingLastPathComponent().appending(path: "grok-history", directoryHint: .isDirectory))
    /// Prepended to every session id the app creates (chat, group).
    var sessionNamespace = ""
    private(set) var persistenceEnabled = true
    let backendFactory: ((Bot) throws -> any AgentBackend)?
    let didCancelLocalStream: (() -> Void)?
    /// The launch work of a real window runs (`startLaunchWork`): off in tests, headless commands and the demo.
    var launchWorkEnabled = false

    /// `autoStart`: the launch work a real window does. Tests and headless commands pass false.
    /// `readOnly`: the store is read and never written (`--render-snapshot`): no save, no backup, no one-time
    /// migration, no setting. Bots of an older version are then only left out of what is shown.
    init(demoMode: Bool = false, storeURL: URL? = nil, autoStart: Bool = true, readOnly: Bool = false, backendFactory: ((Bot) throws -> any AgentBackend)? = nil, didCancelLocalStream: (() -> Void)? = nil, keyStore: any KeyStore = KeychainKeyStore(), defaults: UserDefaults = .standard, connectivity: (any ConnectivitySource)? = nil) {
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
        if readOnly { persistenceEnabled = false }
        if demoMode {
            persistenceEnabled = false
            loadDemoData(includeActivity: true)
        } else if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let original = try Data(contentsOf: fileURL)
                let file = try StoreFile.decode(original)
                // The backup comes before anything this launch may write.
                let backup = backUpOlderStore(file, original: original)
                adoptStoreFile(file)
                if let backup { removeLegacyBots(file.removedBots, backup: backup) }
            } catch {
                persistenceEnabled = false
                let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
                let backup = fileURL.deletingLastPathComponent().appending(path: "store.json.corrupt-\(stamp)")
                do { try FileManager.default.moveItem(at: fileURL, to: backup); unreadableStoreSetAside = true }
                catch { errorMessage = "Could not read or back up store.json: \(error.localizedDescription)" }
                if errorMessage == nil { errorMessage = "The saved store could not be decoded. It was moved to \(backup.lastPathComponent); saving is disabled for this launch." }
            }
            if herdrConfigured { bots.filter(\.isDemo).forEach { $0.isHidden = true } }
            // A store set aside unreadable is offered back, never replaced.
            storeRestoreOffer = StoreRestore.offer(directory: directory, store: fileURL, current: persistenceEnabled ? bots : [], declined: declinedRestores)
        } else if let offer = StoreRestore.offer(directory: directory, store: fileURL, current: [], declined: declinedRestores) {
            storeRestoreOffer = offer
        }
        // A fresh install starts empty; the setup window or "Look around with sample agents" fills it.
        if !demoMode, !readOnly { legacyNotice = defaults.string(forKey: LegacyStore.noticeKey); migrateSampleBots(); restoreLedger() }
        selectVisibleChat()
        launchWorkEnabled = !demoMode && autoStart
        if connectivity != nil { listenForConnectivity() }
    }

    /// The decoded store becomes this window's state (launch, and the restore of a set-aside store).
    func adoptStoreFile(_ file: StoreFile) {
        bots = file.bots; groups = file.groups
        chatScroll.restore(file.scrollPositions)
        turns.roundsAtLaunch = Set(groups.filter { $0.round != nil }.map(\.id))
        if !migrateArchivedGroups().isEmpty { save() }
    }

    /// A store an older build wrote (`LegacyStore`): the file is copied, byte for byte as it was read, to a dated backup
    /// beside it, before this launch writes anything. Returns the backup, or nil for a store this build wrote itself.
    /// Without a backup nothing is written: saving is off for the launch.
    func backUpOlderStore(_ file: StoreFile, original: Data) -> URL? {
        guard file.isOlder, persistenceEnabled else { return nil }
        do { return try LegacyStore.writeBackup(original, store: fileURL, now: now()) }
        catch { persistenceEnabled = false; errorMessage = LegacyStore.backupFailed; return nil }
    }

    /// After the backup: the store is saved as this build keeps it, so the next launch finds nothing to back up. Bots
    /// of a removed backend are gone from it with what only belonged to them (their place in groups, a group that had
    /// no other member, their settings); bots that run on Herdr are not touched. When bots were removed the person is
    /// told once, in one line that stays until it is dismissed.
    func removeLegacyBots(_ removed: [LegacyStore.RemovedBot], backup: URL) {
        guard !removed.isEmpty else { save(); return }
        let gone = Set(removed.map(\.id)), kept = Set(bots.map(\.id))
        let touched = Set(groups.filter { !gone.isDisjoint(with: $0.memberIDs) }.map(\.id))
        for group in groups { group.memberIDs.removeAll { gone.contains($0) } }
        // A group that lost a member and has no bot left to answer in it goes with them.
        groups.removeAll { touched.contains($0.id) && kept.isDisjoint(with: $0.memberIDs) }
        if selectedGroup.map({ selected in !groups.contains { $0 === selected } }) == true { selectedGroup = nil }
        for id in gone { forgetBotSettings(id) }
        let notice = LegacyStore.notice(removed: removed.count, backup: backup)
        defaults.set(notice, forKey: LegacyStore.noticeKey); legacyNotice = notice
        save()
    }

    func dismissLegacyNotice() { defaults.removeObject(forKey: LegacyStore.noticeKey); legacyNotice = nil }

    /// A restored store is this launch's store again, saved as store.json.
    func adoptRestoredStore(_ file: StoreFile, original: Data) {
        persistenceEnabled = true; unreadableStoreSetAside = false
        let backup = backUpOlderStore(file, original: original)
        adoptStoreFile(file)
        if let backup { removeLegacyBots(file.removedBots, backup: backup) }
        if herdrConfigured { bots.filter(\.isDemo).forEach { $0.isHidden = true } }
    }
    /// Start fresh after an unreadable store.json was moved aside: this window saves again, as a fresh install would.
    /// Never while a store.json is there (the move failed, or another window wrote one): saving would replace it.
    func resumeSavingAfterSetAside() {
        guard !persistenceEnabled, unreadableStoreSetAside, !FileManager.default.fileExists(atPath: fileURL.path) else { return }
        persistenceEnabled = true; unreadableStoreSetAside = false
        if errorMessage?.hasPrefix("The saved store could not be decoded.") == true { errorMessage = nil }
    }
    func addBot(name: String, persona: String, backend: BackendKind, avatarName: BotAvatarName?, avatar: AvatarChoice = .unpicked) { let bot = Bot(name: name, persona: persona, backend: backend, avatarName: avatarName); avatar.apply(to: bot); bots.insert(bot, at: 0); selectedBot = bot; rememberSelection(bot: bot); save() }
    /// A template becomes a Herdr bot on the first server: its name, title, description, instructions and avatar.
    @discardableResult func importTemplate(_ plan: TemplateImportPlan) -> Bot {
        let manifest = plan.manifest
        let bot = Bot(name: manifest.name, title: manifest.title, description: manifest.description, persona: manifest.instructions, backend: .herdr, avatarName: plan.avatarName)
        setHerdrServer(herdrServers[0].id, for: bot)
        bots.insert(bot, at: 0); selectedBot = bot; rememberSelection(bot: bot); save(); return bot
    }
    func delete(_ bot: Bot) { grokHistory.remove(bot.id); bots.removeAll { $0.id == bot.id }; groups.forEach { $0.memberIDs.removeAll { $0 == bot.id } }; if selectedBot == bot { if selectedGroup == nil { selectVisibleChat() } else { selectedBot = nil } }; save() }
    /// Writes store.json; a failed write is reported once per streak instead of being swallowed.
    var storeFile: StoreFile { StoreFile(bots: bots, groups: groups, scrollPositions: chatScroll.stored) }

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
    /// Sends into the selected bot's chat. While that chat's turn streams, the text steers it when the agent takes
    /// steers; otherwise it waits as the chat's next message, and the turn is never stopped. Other chats never block
    /// it; when the turn limit is reached the message waits as the chat's next message.
    @discardableResult func send(text: String, attachments: [ChatAttachment] = []) -> Bool {
        guard let bot = selectedBot, !bot.isReadOnlyArchive, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty else { return false }
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
        guard !bot.isReadOnlyArchive, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty else { return false }
        guard isIdle(conversation) else { return false }
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
        conversation.messages.append(user)
        if let reason = full ?? (hasWaitingTurn(in: conversation) ? TurnWaitCopy.behind : nil) { return waitForTurn(user, in: conversation, reason: reason) }
        startChatTurn(bot: bot, conversation: conversation, user: user, images: images, backend: activeBackend)
        return true
    }
    /// Starts the turn answering `user`, a row of `conversation`. The reply goes right under it and the turn sends the
    /// chat only up to it: messages queued after it wait below and go in their own turns.
    func startChatTurn(bot: Bot, conversation: any Conversation, user: ChatMessage, images: [String] = [], backend activeBackend: any AgentBackend) {
        let assistant = ChatMessage(role: .assistant, content: "", isStreaming: true, turnState: .incomplete)
        if let index = conversation.messages.firstIndex(where: { $0 === user }) { conversation.messages.insert(assistant, at: index + 1) } else { conversation.messages.append(assistant) }
        let turn = beginTurn(in: conversation, bot: bot, assistant: assistant)
        objectWillChange.send(); save()
        let streamToken = turn.token
        let history = chatHistory(conversation, upTo: conversation.messages.contains { $0 === user } ? user : nil, excluding: assistant)
        turn.task = Task { [weak self] in
            await self?.runChatTurn(bot: bot, conversation: conversation, assistant: assistant, history: history, images: images, systemPrompt: bot.outboundPersona,
                                    backend: activeBackend, token: streamToken)
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
