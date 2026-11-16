import AppKit
import Foundation
import Testing
@testable import AgentApp

// A Herdr-only install (the older backends hidden, no bot on one) is shown nothing of theirs and does nothing for
// them: no Reports row or inbox, no box list, no Grok Bot import, and the Reports file is never opened.

private let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// A report as an agent on a Hermes box filed it, waiting in the inbox.
private let waitingReport = #"{"reports":[{"source":"agent","id":"r1","title":"Installer blocked","createdAt":814252317,"connection":"https://box.example.com/v1","bot":"ada","botBackend":"hermes","kind":"bug","body":"The update could not complete.","boxFile":"present","skillVersions":{"swarmhub-messages":"1.1.0"},"hasBody":true,"state":"pending"}]}"#

@MainActor private func storeWithAReport(_ defaults: UserDefaults = isolatedDefaults()) throws -> AppStore {
    let url = temporaryStore()
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(waitingReport.utf8).write(to: url.deletingLastPathComponent().appending(path: "reports.json"))
    let first = AppStore(storeURL: url, autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: defaults)
    first.bots = [Bot(name: "Jarvis", backend: .herdr)]; first.save()
    return AppStore(storeURL: url, autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: defaults)
}

@MainActor private func sidebar(_ store: AppStore) async throws -> Data {
    let updater = AppUpdater(environment: ["SWARMHUB_DISABLE_UPDATES": "1"]), size = NSSize(width: SidebarMetrics.width.ideal, height: 460)
    return try #require(await HeadlessSetup.png(SidebarView(selection: .constant(store.bots.first)).frame(width: size.width, height: size.height), store: store, updater: updater, size: size))
}

@MainActor @Test func aHerdrOnlyInstallNeverOpensTheReportsInbox() async throws {
    let store = try storeWithAReport()
    #expect(!LegacySurface.isShown(store.defaults) && !store.hasOlderBackendBots && !store.olderBackendsInUse && !store.offersOlderBackendsSwitch)
    let hidden = try await sidebar(store)
    #expect(!store.reportsWereRead, "the sidebar shows no Reports row, and the Reports file is not even opened")
    // With the older backends shown the same file gives the row and its report.
    store.defaults.set(true, forKey: LegacySurface.key)
    #expect(store.olderBackendsInUse && store.offersOlderBackendsSwitch)
    let shown = try await sidebar(store)
    #expect(store.reportsWereRead && store.reportsCenter.inbox.visible.map(\.id) == ["r1"] && store.reportsCenter.inbox.pendingCount == 1)
    #expect(hidden != shown, "the Reports row is drawn only with the older backends shown")
}

@MainActor @Test func theOlderBackendsCountAsInUseOnlyWhereTheyAre() {
    let defaults = isolatedDefaults()
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: defaults)
    store.bots = [Bot(name: "Jarvis", backend: .herdr), Bot(name: "Atlas", isDemo: true)]
    #expect(!store.olderBackendsInUse && !store.offersOlderBackendsSwitch, "Herdr bots and samples are not theirs")
    defaults.set("https://box.example.com", forKey: "hermesBaseURL")
    #expect(!store.olderBackendsInUse && store.offersOlderBackendsSwitch, "a saved box address: nothing is done for it, but the switch is offered")
    defaults.removeObject(forKey: "hermesBaseURL")
    store.bots.append(Bot(name: "Ada", backend: .hermes, hermesProfile: "ada"))
    #expect(store.hasOlderBackendBots && store.olderBackendsInUse && store.offersOlderBackendsSwitch, "a bot that still runs on Hermes keeps working")
}

/// The surfaces that only serve the older backends are behind the switch where they are drawn.
@Test func theOlderBackendsSurfacesAreBehindTheSwitch() throws {
    func source(_ path: String) throws -> String { try String(contentsOf: repoRoot.appending(path: "Sources/AgentApp/\(path)"), encoding: .utf8) }
    let content = try source("ContentView.swift")
    #expect(content.contains("if legacy, store.showingReports {") && content.contains("} else if legacy, let selection = store.selectedBoxProfile") && content.contains("if legacy, let warning = store.botPromptSyncWarning {"))
    #expect(!content.replacingOccurrences(of: "if legacy, store.showingReports {", with: "").contains("store.showingReports {"), "the inbox has one way in")
    let sidebar = try source("Views/SidebarView.swift")
    #expect(sidebar.contains("if legacy {\n                        BoxNotConnectedSections()\n                        ReportsSidebarRow(center: store.reportsCenter)") && sidebar.contains("if legacy, store.grokBotPresent {"))
    #expect(sidebar.components(separatedBy: "store.reportsCenter").count == 2, "the sidebar touches the Reports inbox in one place")
    #expect(try source("AppCommands.swift").contains(#"if LegacySurface.isShown(store.defaults) { Button("Report a Problem…")"#))
    let polling = try source("Stores/AppStore+Routines.swift")
    #expect(polling.contains("if store.olderBackendsInUse {\n                    await store.pollRoutinesOnce()"))
    #expect(LegacySurface.panes.contains(.reports) && LegacySurface.panes.contains(.account) && !LegacySurface.panes(showingLegacy: false).contains(.reports))
}
