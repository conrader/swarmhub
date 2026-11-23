import AppKit
import Foundation
import Testing
@testable import AgentApp

// P21 items 10, 15, 16, 22, 23: when the setup window opens, no sample bots on a fresh install, headless safety,
// the flag list and the synthetic renders.

@MainActor @Test func aFreshStoreStartsEmptyAndSettleOpensTheWindowOnce() {
    let defaults = isolatedDefaults()
    let store = AppStore(storeURL: temporaryStore(), autoStart: false, keyStore: InMemoryKeyStore(), defaults: defaults)
    #expect(store.bots.isEmpty && store.selectedBot == nil && store.selectedGroup == nil, "no sample bots, nothing selected")
    #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
    #expect(FirstRun.settle(store) && FirstRun.state(defaults) == nil, "the window opens; nothing is written until it closes")
    FirstRun.dismissed(defaults)
    #expect(FirstRun.state(defaults) == .skipped && !FirstRun.settle(store), "it never nags")
    store.loadSamples()
    #expect(store.bots.count == 5 && store.bots.allSatisfy(\.isDemo) && store.selectedBot?.isDemo == true)
}

@MainActor @Test func headlessStoresWriteNoSetupStateAndSettleMarksConfiguredInstallsDone() {
    let defaults = isolatedDefaults(); defaults.set("http://127.0.0.1:8787", forKey: HerdrServerList.legacyAddressKey)
    let url = temporaryStore()
    let first = AppStore(storeURL: url, autoStart: false, keyStore: InMemoryKeyStore(), defaults: defaults)
    first.bots.append(Bot(name: "Ada", backend: .herdr)); first.save()
    _ = AppStore(storeURL: url, autoStart: false, keyStore: InMemoryKeyStore(), defaults: defaults)
    #expect(defaults.object(forKey: FirstRun.stateKey) == nil, "building AppStore (as --check-bots and --render-snapshot do) writes nothing")
    #expect(!FirstRun.settle(first) && FirstRun.state(defaults) == .done, "the UI layer marks a configured install done without a window")
}

@MainActor @Test func hiddenSampleBotsAreNotListedOnceAServerIsSetUp() {
    let defaults = isolatedDefaults()
    let store = AppStore(storeURL: temporaryStore(), autoStart: false, keyStore: InMemoryKeyStore(), defaults: defaults)
    let sample = Bot(name: "Atlas", isHidden: true, isDemo: true), quiet = Bot(name: "Quiet", backend: .herdr, isHidden: true)
    store.bots = [sample, quiet]
    #expect(store.hiddenChatBots.map(\.name) == ["Atlas", "Quiet"])
    defaults.set("http://127.0.0.1:8787", forKey: HerdrServerList.legacyAddressKey)
    #expect(store.hiddenChatBots.map(\.name) == ["Quiet"])
}

@MainActor @Test func everyFlagIsListedAndRecognised() {
    let all = ["--render-snapshot", "--probe-attachment", "--migrate-store", "--grok-fetch", "--grok-probe", "--grok-parity", "--import-grok",
               "--ui-smoke", "--setup-preview", "--render-setup", "--agent-qa"]
    #expect(Set(HeadlessCommands.flags) == Set(all) && HeadlessCommands.flags.count == all.count)
    #expect(!HeadlessCommands.headless.contains("--ui-smoke") && !HeadlessCommands.headless.contains("--setup-preview"))
    #expect(HeadlessCommands.runIfRequested(arguments: ["AgentApp", "--setup-preview"]) == nil, "a launch argument, not a headless command")
    #expect(HeadlessCommands.runIfRequested(arguments: ["AgentApp"]) == nil)
    #expect(HeadlessCommands.runIfRequested(arguments: ["AgentApp", "--render-setup"]) == 64)
    #expect(SetupPreview.isRequested(["AgentApp", "--setup-preview"]) && UISmoke.reportPath(arguments: ["AgentApp", "--ui-smoke", "/tmp/r.json"]) != nil)
    #expect(UpdateConfiguration.unavailableReason(bundleURL: URL(fileURLWithPath: "/Applications/X.app"), info: [:], environment: [:], arguments: ["--setup-preview"]) != nil)
}

/// Default suite: one setup screen through the renderer's own environment, and the repository refusal.
@MainActor @Test func renderSetupRendersTheWelcomeStepAndRefusesTheRepository() async throws {
    let store = SetupPreview.makeStore(); store.isSetupPreview = false
    let updater = AppUpdater(environment: ["SWARMHUB_DISABLE_UPDATES": "1"])
    let data = try #require(await HeadlessSetup.png(SetupView(preset: SetupFlow()), store: store, updater: updater, size: HeadlessSetup.size))
    let image = try #require(NSBitmapImageRep(data: data))
    #expect(image.pixelsWide > 0 && data.count > 4_000, "s1-welcome looks blank")
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    #expect(await HeadlessSetup.render(to: repo.appending(path: "setup-shots"), output: { _ in }) == 2, "refuses a folder inside the repository")
}

/// The wizard opens by itself while there is no bot at all: nothing set up, or a server with no bot on it.
@MainActor @Test func theWizardOpensWhileThereIsNoBot() {
    let keys = InMemoryKeyStore(), defaults = isolatedDefaults()
    let store = AppStore(storeURL: temporaryStore(), autoStart: false, keyStore: keys, defaults: defaults)
    #expect(FirstRun.settle(store), "a fresh install")
    store.saveHerdrServer(store.herdrServers[0], token: "t")
    #expect(store.herdrConfigured && FirstRun.settle(store), "a server that is set up, with no bot on it")
    store.bots = [Bot(name: "Atlas", isDemo: true)]
    #expect(FirstRun.settle(store), "sample bots are not bots")
    let jarvis = Bot(name: "Jarvis", backend: .herdr)
    store.bots = [jarvis]
    #expect(!FirstRun.settle(store) && FirstRun.state(defaults) == .done, "an install with a bot is marked done without a window")
    store.bots = []
    #expect(FirstRun.settle(store), "a finished setup whose bots were all removed opens the wizard again")
    FirstRun.dismissed(defaults, hasBots: false)
    #expect(FirstRun.state(defaults) == .skipped && !FirstRun.settle(store), "closed before the end: it does not come back by itself")
    store.bots = [jarvis]; FirstRun.record(.done, in: defaults)
    FirstRun.dismissed(defaults, hasBots: true)
    #expect(FirstRun.state(defaults) == .done, "closing the wizard on a working install changes nothing")
}

@MainActor @Test func previewStoresAreThrowaway() {
    let store = SetupPreview.makeStore()
    #expect(store.isSetupPreview && store.defaults !== UserDefaults.standard && store.keyStore is MemoryKeyStore)
    #expect(store.fileURL.path.hasPrefix(FileManager.default.temporaryDirectory.path) && store.bots.isEmpty)
    #expect(FirstRun.needsWizard(defaults: store.defaults, bots: store.bots))
}

@MainActor @Test(renderTestsOnly) func renderSetupWritesEveryStepFromASyntheticStore() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "AgentAppSetup-\(UUID().uuidString)")
    var lines: [String] = []
    #expect(await HeadlessSetup.render(to: directory, output: { lines.append($0) }) == 0, "\(lines)")
    let expected = HeadlessHerdrShots.names + ["empty-state"]
    var sizes: [String: Int] = [:]
    for name in expected {
        let data = try Data(contentsOf: directory.appending(path: "\(name).png"))
        let image = try #require(NSBitmapImageRep(data: data))
        #expect(image.pixelsWide > 0 && data.count > 4_000, "\(name) looks blank"); sizes[name] = data.count
    }
    #expect(sizes["herdr-w1-where"] != sizes["herdr-w3-main-bot"], "the steps differ")
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    #expect(await HeadlessSetup.render(to: repo.appending(path: "setup-shots"), output: { _ in }) == 2, "refuses a folder inside the repository")
}
