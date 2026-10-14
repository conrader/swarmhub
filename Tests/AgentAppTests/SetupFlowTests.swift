import AppKit
import Foundation
import Testing
@testable import AgentApp

// P21 Part C: the setup window's steps, the inert hosting placeholder and its guards.

private let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

@Test func backCancelAndSkipFollowTheTransitionTable() {
    var flow = SetupFlow()
    #expect(flow.step == .welcome && flow.canSkip && !flow.canGoBack)
    flow.apply(.newHosted); #expect(flow.step == .hosting && flow.canGoBack && !flow.canSkip)
    flow.apply(.back); #expect(flow.step == .welcome)
    flow.apply(.connectExisting); #expect(flow.step == .address && flow.canGoBack)
    flow.apply(.test(.init(outcome: .unreachable))); #expect(flow.step == .address, "a failed Test stays on the address step")
    let box = URL(string: "https://my-box.example.com")!
    let found = SetupCheckResult(outcome: .connected(place: "my-box.example.com", count: 2), baseURL: box,
                                 probes: [.init(id: "default", status: .available(.init(id: "default", name: "Hermes", model: "m"))),
                                          .init(id: "research", status: .available(.init(id: "research", name: "Research", model: "research")))])
    flow.apply(.test(found)); #expect(flow.step == .choose && flow.canGoBack)
    flow.preselect(alreadyAdded: ["default"]); #expect(flow.chosen == ["research"] && flow.canAdd)
    flow.apply(.back); #expect(flow.step == .address)
    flow.apply(.test(found)); flow.apply(.add(count: 1, first: "Research"))
    #expect(flow.step == .done && !flow.canGoBack && flow.addedCount == 1)
    flow.apply(.back); #expect(flow.step == .done, "nothing goes back from Done")
}

@Test func prefillStartsOnTheAddressAndAMoveNeedsConfirmation() {
    let prefill = SetupPrefill(address: "https://old.example.com", agentName: "grok-jarvis", startAtAddress: true)
    var flow = SetupFlow(prefill: prefill)
    #expect(flow.step == .address && flow.input.address == "https://old.example.com" && flow.input.key.isEmpty && flow.input.extra == "grok-jarvis=")
    let found = SetupCheckResult(outcome: .connected(place: "new.example.com", count: 1), baseURL: URL(string: "https://new.example.com")!,
                                 probes: [.init(id: "default", status: .available(.init(id: "default", name: "Hermes", model: "m")))])
    flow.apply(.test(found)); flow.preselect(alreadyAdded: [])
    #expect(flow.movesAddress && !flow.canAdd)
    flow.confirmMove = true; #expect(flow.canAdd)
    var same = SetupFlow(prefill: .init(address: "https://new.example.com/", startAtAddress: true))
    same.apply(.test(found)); same.preselect(alreadyAdded: [])
    #expect(!same.movesAddress && same.canAdd)
}

@Test func openClawIsPointedToSettingsAndCannotBeChosenHere() {
    #expect(!OpenClawBackend.isImplemented && !SetupFlow.offersSoftwareChoice)
    #expect(SetupFlow.Step.allCases == [.welcome, .hosting, .address, .choose, .done], "no software step until it has an OpenClaw connect screen (P12 connects in Settings)")
    #expect(SetupCopy.softwareNames == [SetupCopy.softwareLine] && SetupCopy.softwareLine.contains("OpenClaw: add it later in Settings → Advanced."))
}

@Test func hostingIsAnInertPlaceholder() {
    #expect(!ManagedHosting.isAvailable && ManagedHosting.providerName == "Managed hosting")
    #expect(ManagedHosting.detail.contains("nothing is created, sent or charged"))
    var flow = SetupFlow(); flow.apply(.newHosted); flow.apply(.connectExisting)
    #expect(flow.step == .address, "the coming-soon screen leads only back or to connecting a box")
}

/// Counts every request made through its session.
private final class CountingProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var count = 0
    static let lock = NSLock()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.lock.withLock { Self.count += 1 }; client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}

@MainActor @Test func theHostingScreenMakesNoRequest() async throws {
    let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [CountingProtocol.self]
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults(),
                         hermesSession: URLSession(configuration: configuration))
    var flow = SetupFlow(); flow.apply(.newHosted)
    let before = CountingProtocol.lock.withLock { CountingProtocol.count }
    let png = await SnapshotRenderer.png(SetupView(preset: flow).environmentObject(store).defaultAppStorage(store.defaults), size: NSSize(width: 580, height: 480))
    #expect(png != nil)
    #expect(CountingProtocol.lock.withLock { CountingProtocol.count } == before, "S-host makes zero requests")
    #expect(store.defaults.string(forKey: "hermesBaseURL") == nil && store.bots.isEmpty)
}

@Test func theNewSetupFilesHoldNoHostingOrNetworkCode() throws {
    let directory = repoRoot.appending(path: "Sources/AgentApp/Setup")
    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0 == "ManagedHosting.swift" || ($0.hasPrefix("Setup") && $0.hasSuffix(".swift")) }
    #expect(names.contains("ManagedHosting.swift") && names.contains("SetupCopy.swift") && names.contains("SetupView.swift"))
    // "Ermes" is checked case-sensitively below, since "Hermes" contains "ermes".
    let forbidden = ["URLSession", "URL(", "getermes", "signup", "sign up", "billing", "checkout", "provision"]
    for name in names {
        let code = try String(contentsOf: directory.appending(path: name), encoding: .utf8)
            .split(separator: "\n").map { line in line.components(separatedBy: "//").first ?? "" }.joined(separator: "\n")
        for word in forbidden { #expect(!code.localizedCaseInsensitiveContains(word), "\(name) contains \(word)") }
        #expect(!code.contains("Ermes"), "\(name) names a hosting vendor")
    }
}
