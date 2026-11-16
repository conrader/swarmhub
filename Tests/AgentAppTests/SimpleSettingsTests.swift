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

@Test func theSimplePageHoldsExactlyTheEverydayControls() {
    // The brief's ten, plus the automatic-check toggle Konrad placed in About (2026-10-14) and the app icon beside the theme (2026-10-22).
    #expect(SettingsLayout.simpleIDs == ["connection.status", "connection.test", "connection.setup", "you.name", "appearance.theme",
                                         "appearance.appIcon", "appearance.accent", "notifications.master", "about.version", "about.autoCheck",
                                         "about.checkUpdates", "advanced.open"])
    for entry in SettingsLayout.entries where entry.home != .simple {
        guard case .advanced(let pane) = entry.home else { Issue.record("\(entry.id) has no pane"); continue }
        #expect(SettingsLayout.AdvancedPane.allCases.contains(pane))
    }
    #expect(SettingsLayout.AdvancedPane.allCases == [.servers, .alerts, .voice, .about])
    for pane in SettingsLayout.AdvancedPane.allCases { #expect(!SettingsLayout.ids(in: pane).isEmpty, "\(pane.rawValue) is reachable and not empty") }
    #expect(SettingsLayout.home(of: "servers.herdr") == .advanced(.servers) && SettingsLayout.home(of: "servers.grokBot") == .advanced(.servers))
    #expect(Set(SettingsLayout.entries.map(\.id)).count == SettingsLayout.entries.count, "every control has exactly one home")
    #expect(SettingsLayout.home(of: "about.autoDownload") == .advanced(.about))
}

/// Fails the test the moment a key is decrypted; attributes (`hasKey`) are fine.
private final class AttributesOnlyKeyStore: KeyStore, @unchecked Sendable {
    let lock = NSLock(); var armed = false; var reads = 0
    func key(for account: String) -> String { lock.withLock { if armed { reads += 1 } }; return "" }
    func setKey(_ value: String, for account: String) {}
    func hasKey(for account: String) -> Bool { account == "herdr" }
}

@MainActor @Test func groupNamesUseYourName() {
    let defaults = namedDefaults("Ola")
    let store = AppStore(storeURL: temporaryStore(), autoStart: false, keyStore: InMemoryKeyStore(), defaults: defaults)
    let a = Bot(name: "A", backend: .herdr), b = Bot(name: "B", backend: .herdr)
    store.bots = [a, b]
    #expect(store.userName == "Ola" && store.defaultGroupName([a.id, b.id]) == "Ola, A, B")
    let context = GroupRouting.context(for: .init(id: a.id, name: "A"), groupName: "G", members: [.init(id: a.id, name: "A")],
                                       messages: [ChatMessage(role: .user, content: "hi")], userName: store.userName)
    #expect(context.hasSuffix("\nOla: hi"))
    #expect(GroupRouting.context(for: .init(id: a.id, name: "A"), groupName: "G", members: [], messages: [ChatMessage(role: .user, content: "hi")]).hasSuffix("\nKonrad: hi"))
    #expect(UserIdentity.name(defaults: isolatedDefaults(), fullName: "Grace Hopper") == "Grace")
    #expect(UserIdentity.initial(of: "", fullName: "grace hopper") == "G" && UserIdentity.initial(of: " ola ") == "O")
}
