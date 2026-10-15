import Foundation
import Testing
@testable import AgentApp

// P21 Part A/B: the simple Settings page, the layout table, plain words and the agent editor's simple part.

private let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let banned = ["profile", "gateway", "base URL", "multiplex", "endpoint", "API key", "token", "backend", "session", "cron", "host",
                      "Keychain", "credential", "bot", "bots"]

private func containsWord(_ text: String, _ word: String) -> Bool {
    text.range(of: "\\b\(NSRegularExpression.escapedPattern(for: word))\\b", options: [.regularExpression, .caseInsensitive]) != nil
}

@Test func everyBaselineControlHasExactlyOneHome() {
    let ids = SettingsLayout.entries.map(\.id)
    #expect(Set(ids).count == ids.count, "no control is listed twice")
    #expect(Set(ids) == Set(SettingsLayout.baseline + SettingsLayout.added), "none lost, none invented")
    #expect(ids.filter { $0 == "about.version" }.count == 1 && ids.filter { $0 == "about.checkUpdates" }.count == 1)
    #expect(SettingsLayout.home(of: "about.version") == .simple && SettingsLayout.home(of: "about.checkUpdates") == .simple)
}

@Test func theSimplePageHoldsExactlyTheEverydayControls() {
    // The brief's ten, plus the automatic-check toggle Konrad placed in About (2026-10-14).
    #expect(SettingsLayout.simpleIDs == ["connection.status", "connection.test", "connection.setup", "you.name", "appearance.theme",
                                         "appearance.accent", "notifications.master", "about.version", "about.autoCheck",
                                         "about.checkUpdates", "advanced.open"])
    for entry in SettingsLayout.entries where entry.home != .simple {
        guard case .advanced(let pane) = entry.home else { Issue.record("\(entry.id) has no pane"); continue }
        #expect(SettingsLayout.AdvancedPane.allCases.contains(pane))
    }
    #expect(SettingsLayout.AdvancedPane.allCases.count == 10, "P38 C added Voice")
    for pane in SettingsLayout.AdvancedPane.allCases { #expect(!SettingsLayout.ids(in: pane).isEmpty, "\(pane.rawValue) is reachable and not empty") }
    #expect(SettingsLayout.home(of: "servers.reenterKey") == .advanced(.servers) && SettingsLayout.home(of: "servers.grokBot") == .advanced(.servers))
    #expect(SettingsLayout.home(of: "about.autoDownload") == .advanced(.about))
}

@Test func simpleAndSetupCopyUsePlainWords() {
    for text in SimpleCopy.all + SetupCopy.all + InspectorCopy.all {
        // P25 D6: OpenClaw's own name for the key may appear once, in the S3-OC key caption only.
        let checked = text == SetupCopy.openClawKeyCaption ? text.replacingOccurrences(of: SetupCopy.openClawTermForKey, with: "") : text
        for word in banned { #expect(!containsWord(checked, word), "“\(text)” contains \(word)") }
        if !SetupCopy.softwareNames.contains(text) {
            #expect(!containsWord(text, "Hermes") && !containsWord(text, "OpenClaw"), "“\(text)” names the software outside the S1 line, S2 cards and S3-OC")
        }
    }
    #expect((SetupCopy.all).filter { $0.contains(SetupCopy.openClawTermForKey) } == [SetupCopy.openClawKeyCaption], "the Gateway's term appears once")
    // "OpenClaw" is allowed only in the S1 line, the S2 cards and the S3-OC screen.
    #expect(Set(SetupCopy.all.filter { containsWord($0, "OpenClaw") }).isSubset(of: Set(SetupCopy.softwareNames)))
    #expect(Set(SetupCopy.softwareNames).isSubset(of: Set(SetupCopy.all)) && SetupCopy.softwareLine == "Works with Hermes and OpenClaw.")
    #expect(!(SimpleCopy.all + SetupCopy.all + InspectorCopy.all).contains { $0.contains("Mock") })
    #expect(SimpleCopy.connected(to: "this Mac", agents: 2).hasPrefix("Connected") && !SimpleCopy.all.contains { $0.localizedCaseInsensitiveContains("key saved") })
}

@Test func simpleViewsTakeTheirWordsFromTheCopyEnums() throws {
    let files = ["Sources/AgentApp/Views/SettingsSimplePane.swift", "Sources/AgentApp/Views/BotEditorView.swift",
                 "Sources/AgentApp/Setup/SetupView.swift", "Sources/AgentApp/Setup/SetupSteps.swift", "Sources/AgentApp/Setup/SetupEmptyState.swift",
                 "Sources/AgentApp/Setup/SetupOpenClawSteps.swift"]
                + inspectorSimpleFiles
    let literal = try NSRegularExpression(pattern: #"(\b(Text|Button|Label|TextField|SecureField|Toggle|Picker|DatePicker|Section|Menu|DisclosureGroup)|\.help)\(\s*""#)
    for file in files {
        let text = try String(contentsOf: repoRoot.appending(path: file), encoding: .utf8)
        let hits = literal.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
        #expect(hits == 0, "\(file) passes a string literal to a control")
    }
    let editor = try String(contentsOf: repoRoot.appending(path: "Sources/AgentApp/Views/BotEditorView.swift"), encoding: .utf8)
    #expect(!editor.contains("BackendKind.allCases"), "the backend picker (and Mock) lives only in the Advanced section")
}

/// Fails the test the moment a key is decrypted; attributes (`hasKey`) are fine.
private final class AttributesOnlyKeyStore: HermesKeyStore, @unchecked Sendable {
    let lock = NSLock(); var armed = false; var reads = 0
    func key(for account: String) -> String { lock.withLock { if armed { reads += 1 } }; return "" }
    func setKey(_ value: String, for account: String) {}
    func hasKey(for account: String) -> Bool { account == "hermes" }
}

@MainActor @Test func theStatusLineReadsAttributesOnly() {
    let keys = AttributesOnlyKeyStore(), defaults = isolatedDefaults()
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: keys, defaults: defaults)
    store.bots = [Bot(name: "Ada", backend: .hermes, hermesProfile: "default"), Bot(name: "Sample", isDemo: true)]
    keys.armed = true
    #expect(store.connectionStatusLine == SimpleCopy.connected(to: "this Mac", agents: 1))
    #expect(!store.anyKeyNeedsReentry && store.boxConfigured)
    #expect(keys.reads == 0, "the simple page never decrypts a key")
    let empty = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    #expect(empty.connectionStatusLine == SimpleCopy.notConnected)
    defaults.set("https://my-box.example.com", forKey: "hermesBaseURL")
    #expect(store.connectionStatusLine == SimpleCopy.connected(to: "my-box.example.com", agents: 1))
}

@MainActor @Test func savingWithoutAdvancedKeepsEveryAdvancedField() {
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let reviewer = Bot(name: "Reviewer", backend: .hermes, hermesProfile: "reviewer")
    let bot = Bot(name: "Ada", title: "Custom title", description: "Custom description", persona: "Be brief.", backend: .openClaw,
                  approvalMode: .reviewer, approvalRules: [.init(name: "Only ls", actionPattern: "command", commandPattern: "ls", outcome: .allow)],
                  reviewerBotID: reviewer.id)
    bot.modelSettings = .init(conversation: .choice(ModelChoice(provider: "synthetic", model: "synthetic-model")!))
    bot.notificationsEnabled = false; bot.isHidden = true
    store.bots = [bot, reviewer]
    let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
    let before = try? encoder.encode(bot)
    BotEditorFields(bot: bot).apply(to: bot, store: store, avatarTouched: false)
    #expect(try! encoder.encode(bot) == before, "open + Save changes nothing")
    var edited = BotEditorFields(bot: bot); edited.name = "Ada Lovelace"; edited.persona = ""
    edited.apply(to: bot, store: store, avatarTouched: false)
    #expect(bot.name == "Ada Lovelace" && bot.persona.isEmpty && bot.title == "Custom title" && bot.backend == .openClaw)
    #expect(bot.approvalRules.map(\.name) == ["Only ls"] && bot.reviewerBotID == reviewer.id && bot.modelSettings?.conversation != .inherit)
}

@Test func theSimpleEditorHasFiveThingsAndANewAgentFollowsTheBox() {
    #expect(SettingsLayout.editorSimple == ["editor.avatar", "editor.name", "editor.instructions", "editor.notification", "editor.save"])
    #expect(!SettingsLayout.editorSimple.contains("editor.backend") && SettingsLayout.editorAdvanced.contains("editor.backend"))
    #expect(Set(SettingsLayout.editorSimple).isDisjoint(with: SettingsLayout.editorAdvanced))
    #expect(BotEditorFields.newAgent(hermesConfigured: true).backend == .hermes)
    #expect(BotEditorFields.newAgent(hermesConfigured: false).backend == .mock)
}

@MainActor @Test func groupNamesUseYourName() {
    let defaults = namedDefaults("Ola")
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: defaults)
    let a = Bot(name: "A", backend: .hermes, hermesProfile: "a"), b = Bot(name: "B", backend: .hermes, hermesProfile: "b")
    store.bots = [a, b]
    #expect(store.userName == "Ola" && store.defaultGroupName([a.id, b.id]) == "Ola, A, B")
    let context = GroupRouting.context(for: .init(id: a.id, name: "A"), groupName: "G", members: [.init(id: a.id, name: "A")],
                                       messages: [ChatMessage(role: .user, content: "hi")], userName: store.userName)
    #expect(context.hasSuffix("\nOla: hi"))
    #expect(GroupRouting.context(for: .init(id: a.id, name: "A"), groupName: "G", members: [], messages: [ChatMessage(role: .user, content: "hi")]).hasSuffix("\nKonrad: hi"))
    #expect(UserIdentity.name(defaults: isolatedDefaults(), fullName: "Grace Hopper") == "Grace")
    #expect(UserIdentity.initial(of: "", fullName: "grace hopper") == "G" && UserIdentity.initial(of: " ola ") == "O")
}
