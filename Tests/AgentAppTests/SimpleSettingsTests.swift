import Foundation
import Testing
@testable import AgentApp

// Settings: the layout table (one home for every control), and your name wherever the app says it.

@Test func everySettingHasOneHomeInOnePane() {
    // One Settings: General is what most people open it for, and each other pane is one thing. No "Advanced" behind it.
    #expect(SettingsLayout.Pane.allCases == [.general, .ais, .servers, .vault, .updates, .whatsNew, .about])
    #expect(SettingsLayout.ids(in: .general) == [
        "you.name", "you.about", "you.timeZone", "you.location", "appearance.theme", "appearance.accent", "appearance.appIcon",
        "appearance.avatarMotion", "turnLimits.perConnection", "turnLimits.total", "notifications.master",
    ])
    for pane in SettingsLayout.Pane.allCases { #expect(!SettingsLayout.ids(in: pane).isEmpty, "\(pane.rawValue) is reachable and not empty") }
    #expect(SettingsLayout.home(of: "servers.herdr") == .servers && SettingsLayout.home(of: "servers.projects") == .servers && SettingsLayout.home(of: "servers.grokBot") == .servers)
    #expect(Set(SettingsLayout.entries.map(\.id)).count == SettingsLayout.entries.count, "every control has exactly one home")
    #expect(SettingsLayout.home(of: "updates.autoInstall") == .updates && SettingsLayout.home(of: "updates.servers") == .updates, "everything about updates is in Software Update")
    #expect(SettingsLayout.home(of: "about.version") == .about && SettingsLayout.home(of: "about.checkUpdates") == .about && SettingsLayout.home(of: "nothing") == nil)
    // Where something is, in the words the app's own sentences use.
    #expect(SettingsLayout.path(.servers, "Projects") == "Settings → Servers → Projects" && SettingsLayout.path(.updates) == "Settings → Software Update")
    // What a bot runs on has one home, its Details; the editor's Advanced part no longer repeats it.
    #expect(!SettingsLayout.editorAdvanced.contains("editor.herdrAgent") && SettingsLayout.editorAdvanced.contains("editor.herdrProjects"))
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

@Test func releaseHistoryIncludesPackagedNotesInVersionOrder() throws {
    let notes = ReleaseNote.bundled
    #expect(notes.contains { $0.id == "0.8.6" && $0.body.contains("Updates") })
    #expect(notes.contains { $0.id == "0.4.1" })
    #expect(notes.map(\.version) == notes.map(\.version).sorted(by: >))
    #expect(notes.allSatisfy { !$0.body.isEmpty })
}
