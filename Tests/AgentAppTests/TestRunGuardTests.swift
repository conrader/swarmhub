import Foundation
import Security
import Testing
@testable import AgentApp

/// The app's `TestRunGuard` reports here (found by this Objective-C name). Every report fails the run: an outside request,
/// a Keychain call, or production state (store.json, the standard defaults). Requests carrying the guard test's probe
/// header are only logged, so that test can show the guard caught them.
@objc(AgentAppTestRunSentinel) final class TestRunSentinelRecorder: NSObject, TestRunSentinel {
    static let outsideRequests = AwaitableLog<String>()
    static let probes = AwaitableLog<String>()

    static func outsideRequest(_ url: String, probe: String?) {
        if let probe { probes.append("\(probe) \(url)"); return }
        outsideRequests.append(url)
        FileHandle.standardError.write(Data("OUTSIDE REQUEST BLOCKED: \(url)\n".utf8))
        Issue.record("A test sent a request outside loopback: \(url)")
    }

    static func productionAccess(_ what: String, probe: String?) {
        if let probe { probes.append("\(probe) \(what)"); return }
        FileHandle.standardError.write(Data("PRODUCTION ACCESS REFUSED: \(what)\n".utf8))
        Issue.record("A test reached production state: \(what)")
    }
}

private func probeRequest(_ probe: String, _ url: String = "https://konrad.agenthut.net/p/grok-jarvis/v1/capabilities") -> URLRequest {
    var request = URLRequest(url: URL(string: url)!); request.setValue(probe, forHTTPHeaderField: TestRunGuard.probeHeader)
    request.setValue("Bearer fake", forHTTPHeaderField: "Authorization")
    return request
}

/// The leak the box's nginx log showed (P28): `GET /p/grok-jarvis/v1/capabilities` on konrad.agenthut.net. Through every
/// session the app builds by default, the request is failed locally and reported to the sentinel.
@Test func guardCatchesARequestToTheProductionBox() async throws {
    #expect(TestRunGuard.isTestRun)
    let grok = GrokSession.live() // its URLSession is invalidated when it goes away
    let sessions: [(String, URLSession)] = [("hermes", HermesURLSession.shared), ("shared", TestRunGuard.sharedSession),
                                            ("url-session-shared", URLSession.shared), ("websocket", WebSocketTransport.session),
                                            ("grok", grok.urlSession)]
    for (name, session) in sessions {
        let probe = "probe-\(name)-\(UUID().uuidString)"
        await #expect(throws: URLError.self) { _ = try await session.data(for: probeRequest(probe)) }
        try await TestRunSentinelRecorder.probes.wait { $0.contains("\(probe) https://konrad.agenthut.net/p/grok-jarvis/v1/capabilities") }
    }
    let probe = "probe-websocket-open-\(UUID().uuidString)"
    await #expect(throws: URLError.self) { try await WebSocketTransport().open(probeRequest(probe, "wss://konrad.agenthut.net/gateway")) }
    #expect(TestRunSentinelRecorder.probes.all.contains("\(probe) wss://konrad.agenthut.net/gateway"))
}

@Test func guardLetsLoopbackThroughAndCatchesEveryOtherHost() {
    for host in ["127.0.0.1", "localhost", "[::1]"] {
        #expect(!OutsideRequestGuard.canInit(with: URLRequest(url: URL(string: "http://\(host):8642/v1/models")!)))
    }
    for url in ["https://konrad.agenthut.net/v1/capabilities", "http://127.0.0.2/v1", "https://api.github.com/repos/x/y", "http://example.test/v1"] {
        #expect(OutsideRequestGuard.canInit(with: URLRequest(url: URL(string: url)!)))
    }
    #expect(HermesURLSession.shared.configuration.protocolClasses?.first == OutsideRequestGuard.self)
}

/// Opening a page or an app in a test run opens nothing and is reported to the sentinel (here with the probe marker,
/// so this deliberate call is only logged; any other test's call fails the run).
@MainActor @Test func externalLinkOpensNothingInATestRun() {
    let probe = "probe-open-\(UUID().uuidString)"
    #expect(!ExternalLink.open(URL(string: "https://login.example.test/authorize?state=guard")!, probe: probe))
    #expect(TestRunSentinelRecorder.probes.all.contains("\(probe) open https://login.example.test/authorize?state=guard"))
    let appProbe = "probe-open-app-\(UUID().uuidString)"
    ExternalLink.openApplication(at: URL(fileURLWithPath: "/System/Applications/Calculator.app"), probe: appProbe)
    #expect(TestRunSentinelRecorder.probes.all.contains("\(appProbe) open app /System/Applications/Calculator.app"))
}

/// `ExternalLink` is the only file in Sources that opens a page, file or app; nothing else calls NSWorkspace's openers
/// or SwiftUI's `openURL` action, so no path around the test-run refusal exists.
@Test func onlyExternalLinkOpensThingsOutsideTheApp() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let files = try #require(FileManager.default.enumerator(at: root.appending(path: "Sources/AgentApp"), includingPropertiesForKeys: nil))
        .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" && $0.lastPathComponent != "ExternalLink.swift" }
    #expect(files.count > 50)
    for file in files {
        let text = try String(contentsOf: file, encoding: .utf8)
        for opener in ["NSWorkspace.shared.open(", "shared.openApplication(", "shared.activateFileViewerSelecting(", "\\.openURL", "/usr/bin/open"] {
            #expect(!text.contains(opener), "\(file.lastPathComponent) calls \(opener); use ExternalLink")
        }
    }
}

/// Without the probe header a report is a failing issue, attributed to the test that made the request.
@Test func anOutsideRequestFailsTheTest() {
    withKnownIssue { TestRunSentinelRecorder.outsideRequest("https://sentinel-self-test.invalid/v1/capabilities", probe: nil) }
    withKnownIssue { TestRunSentinelRecorder.productionAccess("Keychain read", probe: nil) }
}

/// The live Keychain is refused (and reported) in a test run: nothing reaches `SecItem*`, nothing is written.
@Test func liveKeychainCallsAreRefusedAndFailTheTest() throws {
    let live = SecKeychainBackend()
    withKnownIssue { #expect(live.read(service: KeyVault.v2Service, account: "hermes").status == errSecInteractionNotAllowed) }
    withKnownIssue { #expect(live.add("fake", service: KeyVault.v2Service, account: "guard-test") == errSecInteractionNotAllowed) }
    withKnownIssue { #expect(live.delete(service: KeyVault.v2Service, account: "guard-test") == errSecInteractionNotAllowed) }
    withKnownIssue { #expect(!live.exists(service: KeyVault.v2Service, account: "hermes")) }
    withKnownIssue { #expect(live.allAccounts(service: KeyVault.v2Service).isEmpty) }
    withKnownIssue { #expect(GrokKeychain().probe() == errSecInteractionNotAllowed) }
    withKnownIssue { #expect(throws: GrokKeychainError.interactionNotAllowed) { try GrokKeychain().readPassword() } }
    // The default key store (the shared vault) is the test-mode one: any use is reported.
    withKnownIssue { #expect(KeychainHermesKeyStore().key(for: "hermes.guard-test").isEmpty) }
}

/// An AppStore without an injected store file or settings is reported and gets throwaway ones, never the real ones.
@MainActor @Test func appStoreWithoutInjectedStateFailsTheTest() {
    withKnownIssue {
        let store = AppStore(autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
        #expect(store.fileURL.path.contains("AgentAppTests-unguarded-"))
    }
    withKnownIssue {
        let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore())
        #expect(store.defaults !== UserDefaults.standard)
    }
}

/// P32 11: the refused paths (an AppStore on the standard defaults, the test-mode key vault) and the setup preview get
/// settings in the temporary folder, so a run adds no `AgentAppTests-*.plist` (or `AgentApp-setup-preview-*.plist`) to
/// ~/Library/Preferences. Compares the files before and after.
@MainActor @Test func refusedSettingsLeaveNoPlistInLibraryPreferences() async throws {
    let preferences = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Preferences")
    func testPlists() -> Set<String> {
        Set(((try? FileManager.default.contentsOfDirectory(atPath: preferences.path)) ?? [])
            .filter { ($0.hasPrefix("AgentAppTests-") || $0.hasPrefix("AgentApp-setup-preview-")) && $0.hasSuffix(".plist") })
    }
    let before = testPlists()
    var refused: UserDefaults?
    withKnownIssue {
        let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore())
        refused = store.defaults
        #expect(store.defaults !== UserDefaults.standard)
    }
    let marker = "p32-\(UUID().uuidString)"
    refused?.set(marker, forKey: "p32.marker"); refused?.synchronize()
    KeyVault.shared.defaults.set(marker, forKey: "p32.marker"); KeyVault.shared.defaults.synchronize()
    let preview = SetupPreview.makeStore(); preview.defaults.set(marker, forKey: "p32.marker"); preview.defaults.synchronize()
    #expect(refused?.string(forKey: "p32.marker") == marker, "the scratch settings work")
    try await Task.sleep(for: .seconds(1)) // cfprefsd writes a suite's plist shortly after the change
    let added = testPlists().subtracting(before)
    #expect(added.isEmpty, "new in ~/Library/Preferences: \(added.sorted())")
}
