import AppKit
import Foundation
import Testing
@testable import AgentApp

// P21 items 10, 15, 16, 22, 23: when the setup window opens, no sample bots on a fresh install, headless safety,
// the flag list and the synthetic renders.

@MainActor @Test func needsSetupMatrix() {
    let fresh = isolatedDefaults()
    #expect(FirstRun.needsSetup(defaults: fresh, keyStore: InMemoryKeyStore(), bots: []))
    let byURL = isolatedDefaults(); byURL.set("https://my-box.example.com", forKey: "hermesBaseURL")
    #expect(!FirstRun.needsSetup(defaults: byURL, keyStore: InMemoryKeyStore(), bots: []))
    #expect(!FirstRun.needsSetup(defaults: isolatedDefaults(), keyStore: InMemoryKeyStore(["hermes": "k"]), bots: []))
    let skipped = isolatedDefaults(); FirstRun.record(.skipped, in: skipped)
    #expect(!FirstRun.needsSetup(defaults: skipped, keyStore: InMemoryKeyStore(), bots: []))
    #expect(!FirstRun.needsSetup(defaults: isolatedDefaults(), keyStore: InMemoryKeyStore(), bots: [Bot(name: "Ada", backend: .hermes, hermesProfile: "ada")]))
    #expect(FirstRun.needsSetup(defaults: isolatedDefaults(), keyStore: InMemoryKeyStore(), bots: [Bot(name: "Atlas", isDemo: true)]), "sample bots are not real agents")
}

@MainActor @Test func aFreshStoreStartsEmptyAndSettleOpensTheWindowOnce() {
    let defaults = isolatedDefaults()
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: defaults)
    #expect(store.bots.isEmpty && store.selectedBot == nil && store.selectedGroup == nil, "no sample bots, nothing selected")
    #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
    #expect(FirstRun.settle(store) && FirstRun.state(defaults) == nil, "the window opens; nothing is written until it closes")
    FirstRun.dismissed(defaults)
    #expect(FirstRun.state(defaults) == .skipped && !FirstRun.settle(store), "it never nags")
    store.loadSamples()
    #expect(store.bots.count == 5 && store.bots.allSatisfy(\.isDemo) && store.selectedBot?.isDemo == true)
}

@MainActor @Test func headlessStoresWriteNoSetupStateAndSettleMarksConfiguredInstallsDone() {
    let defaults = isolatedDefaults(); defaults.set("https://my-box.example.com", forKey: "hermesBaseURL")
    let url = temporaryStore()
    let first = AppStore(storeURL: url, autoConfigureHermes: false, keyStore: InMemoryKeyStore(["hermes": "k"]), defaults: defaults)
    first.bots.append(Bot(name: "Ada", backend: .hermes, hermesProfile: "ada")); first.save()
    _ = AppStore(storeURL: url, autoConfigureHermes: false, keyStore: InMemoryKeyStore(["hermes": "k"]), defaults: defaults)
    #expect(defaults.object(forKey: FirstRun.stateKey) == nil, "building AppStore (as --check-bots and --render-snapshot do) writes nothing")
    #expect(!FirstRun.settle(first) && FirstRun.state(defaults) == .done, "the UI layer marks a configured install done without a window")
}

@MainActor @Test func hiddenSampleBotsAreNotListedOnceABoxIsConfigured() {
    let defaults = isolatedDefaults()
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: defaults)
    let sample = Bot(name: "Atlas", isHidden: true, isDemo: true), quiet = Bot(name: "Quiet", backend: .hermes, isHidden: true)
    store.bots = [sample, quiet]
    #expect(store.hiddenChatBots.map(\.name) == ["Atlas", "Quiet"])
    defaults.set("https://my-box.example.com", forKey: "hermesBaseURL")
    #expect(store.hiddenChatBots.map(\.name) == ["Quiet"])
}

@MainActor @Test func historyOnlyAgentsOpenTheWizardWithTheirLine() {
    let defaults = isolatedDefaults(); defaults.set("https://my-box.example.com", forKey: "hermesBaseURL")
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: defaults)
    let jarvis = Bot(name: "Jarvis"); jarvis.grokSourceID = "synthetic"
    let prefill = store.setupPrefill(for: jarvis)
    #expect(prefill.address == "https://my-box.example.com" && prefill.agentName == "grok-jarvis" && prefill.startAtAddress)
    #expect(SetupFlow(prefill: prefill).input.extra == "grok-jarvis=")
    let fresh = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    #expect(fresh.setupPrefill() == SetupPrefill(), "a first run starts on Welcome")
}

@MainActor @Test func everyFlagIsListedAndRecognised() {
    let old = ["--check-bots", "--render-snapshot", "--probe-attachment", "--migrate-store", "--e2e", "--grok-fetch", "--grok-probe",
               "--grok-parity", "--import-grok", "--import-keys", "--ui-smoke"]
    let added = ["--setup-preview", "--render-setup", "--check-server", "--check-openclaw", "--capture-events", "--check-reports"] // P21, P21, P13 check-server, P12, P27, P36
    #expect(Set(HeadlessCommands.flags) == Set(old + added) && HeadlessCommands.flags.count == old.count + added.count)
    #expect(!HeadlessCommands.headless.contains("--ui-smoke") && !HeadlessCommands.headless.contains("--setup-preview"))
    #expect(HeadlessCommands.runIfRequested(arguments: ["AgentApp", "--setup-preview"]) == nil, "a launch argument, not a headless command")
    #expect(HeadlessCommands.runIfRequested(arguments: ["AgentApp"]) == nil)
    #expect(HeadlessCommands.runIfRequested(arguments: ["AgentApp", "--render-setup"]) == 64)
    #expect(SetupPreview.isRequested(["AgentApp", "--setup-preview"]) && UISmoke.reportPath(arguments: ["AgentApp", "--ui-smoke", "/tmp/r.json"]) != nil)
    #expect(UpdateConfiguration.unavailableReason(bundleURL: URL(fileURLWithPath: "/Applications/X.app"), info: [:], environment: [:], arguments: ["--setup-preview"]) != nil)
}

@MainActor @Test func previewStoresAreThrowaway() {
    let store = SetupPreview.makeStore()
    #expect(store.isSetupPreview && store.defaults !== UserDefaults.standard && store.keyStore is MemoryKeyStore)
    #expect(store.fileURL.path.hasPrefix(FileManager.default.temporaryDirectory.path) && store.bots.isEmpty)
    #expect(FirstRun.needsSetup(defaults: store.defaults, keyStore: store.keyStore, bots: store.bots))
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

@MainActor @Test(renderTestsOnly) func renderSetupWritesEveryStepFromASyntheticStore() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "AgentAppSetup-\(UUID().uuidString)")
    var lines: [String] = []
    #expect(await HeadlessSetup.render(to: directory, output: { lines.append($0) }) == 0, "\(lines)")
    let expected = ["s1-welcome", "s-host", "s3-empty", "s3-filled", "s3-error-bad-address", "s3-error-not-encrypted", "s3-error-unreachable",
                    "s3-error-key-rejected", "s3-error-main-only", "s3-error-bad-line", "s4-choose", "s5-done", "settings-simple",
                    "empty-state", "editor-folded", "editor-advanced"] + HeadlessInspector.names + HeadlessP32Shots.names + HeadlessCodingShots.names + HeadlessAccountsShots.names + HeadlessP34Shots.names + HeadlessP35Shots.names + HeadlessP36Shots.names + HeadlessP37Shots.names + HeadlessP31DEShots.names + HeadlessP38Shots.names + HeadlessP38DShots.names + HeadlessP40Shots.names + HeadlessP43Shots.names
    var sizes: [String: Int] = [:]
    for name in expected {
        let data = try Data(contentsOf: directory.appending(path: "\(name).png"))
        let image = try #require(NSBitmapImageRep(data: data))
        #expect(image.pixelsWide > 0 && data.count > 4_000, "\(name) looks blank"); sizes[name] = data.count
    }
    // P21b: the right panel folded and with Advanced open differ.
    #expect(sizes["inspector-folded"] != sizes["inspector-advanced"] && sizes["group-folded"] != sizes["group-advanced"])
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    #expect(await HeadlessSetup.render(to: repo.appending(path: "setup-shots"), output: { _ in }) == 2, "refuses a folder inside the repository")
}
