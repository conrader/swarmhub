import Foundation
import Testing
@testable import AgentApp

// Staged installs (split from StagedInstallTests.swift, uxfix3): the temporary sessions a transfer or a status refresh
// creates are namespaced, deleted afterwards, and a cleanup that failed is retried before any new one.

@Test func stagingDiagnosticsRequireThisTransfersPrefixAndNeverEstablishAcceptance() throws {
    let source = try stagedSource(); defer { try? FileManager.default.removeItem(at: source) }
    let package = try stagedPackage(source)
    let bytes = try JSONSerialization.data(withJSONObject: ["exit_code": 65, "output": try stagedStatus(package)])
    let output = "SWARMHUB_UPDATER_RESULT:other_" + String(decoding: bytes, as: UTF8.self)
    #expect(StagedTransfer.failure(output, prefix: "this_", previous: nil) == nil)
    #expect(!StagedTransfer.completed(output, prefix: "this_"))
}

@Test @MainActor func transferAndRefreshNamespaceEveryCreatedSessionAndCleanupFindsThem() async throws {
    let source = try stagedSource(); defer { try? FileManager.default.removeItem(at: source) }
    for namespace in ["QA-", AppConstants.selfTestPrefix] {
        let (store, bot, host) = stagedStore(source: source, status: try stagedStatus(stagedPackage(source)))
        store.sessionNamespace = namespace
        #expect(store.installSkills(for: bot))
        try await waitUntil { !store.anyTurnRunning }
        await store.refreshStagedSkills(for: bot, onDemand: true)
        let requests = ChatParityServer.requests(host)
        let created = requests.compactMap { $0.method == "POST" ? $0.body?["id"] as? String : nil }
        #expect(!created.isEmpty && created.allSatisfy { $0.hasPrefix(namespace) })
        let temporary = created.filter { $0.contains("agentapp_update_") }
        #expect(temporary.contains { $0.contains("agentapp_update_bytes_") })
        #expect(temporary.contains { $0.contains("agentapp_update_status_") })
        for id in temporary { #expect(requests.contains { $0.method == "DELETE" && $0.path == "/api/sessions/" + id }) }
        #expect((store.defaults.stringArray(forKey: "updates.transport.cleanup." + store.connection(of: bot)) ?? []).isEmpty)
    }
    #expect(throws: (any Error).self) { try StagedTransfer(stagedPackage(source), namespace: "bad'namespace") }
}

@Test @MainActor func skillsViewOpensSpendNoTurnsAndExplicitRefreshIsSingleFlightAndCleansUp() async throws {
    let source = try stagedSource(); defer { try? FileManager.default.removeItem(at: source) }
    let package = try stagedPackage(source)
    let (store, bot, host) = stagedStore(source: source, status: try stagedStatus(package), holdStatus: true)
    await store.refreshInstalledSkills(for: bot)
    await store.refreshInstalledSkills(for: bot)
    #expect(ChatParityServer.requests(host).isEmpty)
    let refresh = Task { await store.refreshStagedSkills(for: bot, onDemand: true) }
    try await waitUntil { ChatParityServer.requests(host).contains { $0.path.hasSuffix("/chat/stream") } }
    await store.refreshStagedSkills(for: bot, onDemand: true)
    await refresh.value
    await store.refreshInstalledSkills(for: bot)
    #expect(ChatParityServer.requests(host).filter { $0.path.hasSuffix("/chat/stream") }.count == 1)
    let created = ChatParityServer.requests(host).compactMap { $0.body?["id"] as? String }
    #expect(created.count == 1)
    #expect(ChatParityServer.requests(host).contains { $0.method == "DELETE" && $0.path == "/api/sessions/" + created[0] })
    #expect(store.boxInstallTransport.refreshing.isEmpty)
    #expect(bot.installedSkills == ["swarmhub-manager": "1.2.0"])
}

@Test @MainActor func failedStatusRefreshDeletesSessionAndKeepsLastGood() async throws {
    let source = try stagedSource(); defer { try? FileManager.default.removeItem(at: source) }
    let (store, bot, host) = stagedStore(source: source, status: nil, down: true)
    bot.installedSkills = ["swarmhub-manager": "1.2.0"]
    await store.refreshStagedSkills(for: bot, onDemand: true)
    #expect(bot.installedSkills == ["swarmhub-manager": "1.2.0"])
    #expect(ChatParityServer.requests(host).contains { $0.method == "DELETE" && $0.path.contains("agentapp_update_status_") })
    #expect(store.boxInstallTransport.refreshing.isEmpty)
}

@Test @MainActor func cancellingStatusRefreshStillCleansItsSession() async throws {
    let source = try stagedSource(); defer { try? FileManager.default.removeItem(at: source) }
    let (store, bot, host) = stagedStore(source: source, status: nil, holdStatus: true)
    let refresh = Task { await store.refreshStagedSkills(for: bot, onDemand: true) }
    try await waitUntil { ChatParityServer.requests(host).contains { $0.path.hasSuffix("/chat/stream") } }
    refresh.cancel()
    await refresh.value
    #expect(ChatParityServer.requests(host).contains { $0.method == "DELETE" && $0.path.contains("agentapp_update_status_") })
    #expect(store.boxInstallTransport.refreshing.isEmpty)
}

@Test @MainActor func interruptedCleanupIsRetriedBeforeAnotherRefresh() async throws {
    let source = try stagedSource(); defer { try? FileManager.default.removeItem(at: source) }
    let (store, bot, host) = stagedStore(source: source, status: nil)
    let key = "updates.transport.cleanup." + store.connection(of: bot)
    let interrupted = "QA-agentapp_update_bytes_interrupted_0"
    let oldStatus = AppConstants.selfTestPrefix + "agentapp_update_status_interrupted"
    store.defaults.set([interrupted, oldStatus], forKey: key)
    await store.refreshStagedSkills(for: bot, onDemand: true)
    let requests = ChatParityServer.requests(host)
    let deleted = try #require(requests.firstIndex { $0.method == "DELETE" && $0.path == "/api/sessions/" + interrupted })
    let created = try #require(requests.firstIndex { $0.method == "POST" && $0.path == "/api/sessions" })
    #expect(deleted < created)
    #expect(requests[..<created].contains { $0.method == "DELETE" && $0.path == "/api/sessions/" + oldStatus })
    #expect((store.defaults.stringArray(forKey: key) ?? []).isEmpty)
}

@Test @MainActor func failedCleanupRetainsIDsAndBlocksMoreTemporarySessions() async throws {
    let source = try stagedSource(); defer { try? FileManager.default.removeItem(at: source) }
    let (store, bot, host) = stagedStore(source: source, status: nil, cleanupDown: true)
    let key = "updates.transport.cleanup." + store.connection(of: bot)
    let interrupted = "QA-agentapp_update_status_interrupted"
    store.defaults.set([interrupted], forKey: key)
    await store.refreshStagedSkills(for: bot, onDemand: true)
    await store.refreshStagedSkills(for: bot, onDemand: true)
    #expect(store.defaults.stringArray(forKey: key) == [interrupted])
    #expect(!ChatParityServer.requests(host).contains { $0.method == "POST" })
    #expect(store.boxInstallTransport.refreshing.isEmpty)
}
