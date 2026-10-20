#if DEBUG
import Foundation
import Testing
@testable import AgentApp

@Suite struct UIAcceptanceTests {
    @Test func explicitOptInAndConflictingConfigurationFailClosed() throws {
        #expect(try UIAcceptanceMode.validate(environment: [:]) == false)
        #expect(try UIAcceptanceMode.validate(environment: ["SWARMHUB_QA_MODE": "1"]) == false)
        #expect(try UIAcceptanceMode.validate(environment: [UIAcceptanceMode.variable: "1"]))
        for value in ["", "0", "true", " 1"] {
            #expect(throws: UIAcceptanceError.self) { try UIAcceptanceMode.validate(environment: [UIAcceptanceMode.variable: value]) }
        }
        for name in ["HERMES_URL", "SWARMHUB_QA_HERMES_URL", "COMPOSIO_API_KEY", "OPENCLAW_URL",
                     "SWARMHUB_KEYCHAIN_SERVICE", "SWARMHUB_QA_MODE", "SWARMHUB_UI_ACCEPTANCE_STORE_PATH"] {
            #expect(throws: UIAcceptanceError.self) {
                try UIAcceptanceMode.validate(environment: [UIAcceptanceMode.variable: "1", name: "unsafe"])
            }
        }
    }

    @Test @MainActor func actualDependenciesFailClosed() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let keys = MemoryKeyStore()
        func validate(backend: any AgentBackend = UIAcceptanceChatBackend(), storeURL: URL? = nil,
                      auto: Bool = false, isolated: Bool = true, hermes: String? = nil, connectors: [String] = []) throws {
            try UIAcceptanceIsolation.validate(backend: backend, keys: keys, autoConfigure: auto,
                storeURL: storeURL ?? root.appending(path: "store.json"), root: root, isolatedDefaults: isolated,
                hermesURL: hermes, connectors: connectors)
        }
        try validate()
        #expect(throws: UIAcceptanceError.self) { try validate(backend: MockBackend()) }
        #expect(throws: UIAcceptanceError.self) { try validate(auto: true) }
        #expect(throws: UIAcceptanceError.self) { try validate(isolated: false) }
        #expect(throws: UIAcceptanceError.self) { try validate(hermes: "http://127.0.0.1:8650") }
        #expect(throws: UIAcceptanceError.self) { try validate(connectors: ["email"]) }
        #expect(throws: UIAcceptanceError.self) { try validate(storeURL: root.appending(path: "../store.json")) }
        #expect(throws: UIAcceptanceError.self) {
            try UIAcceptanceIsolation.validate(backend: UIAcceptanceChatBackend(), keys: QAKeyStore(), autoConfigure: false,
                storeURL: root.appending(path: "store.json"), root: root, isolatedDefaults: true, hermesURL: nil, connectors: [])
        }
    }

    @Test func networkGuardRejectsLoopbackAndRemote() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UIAcceptanceRequestGuard.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        for address in ["http://127.0.0.1:9", "https://acceptance.invalid"] {
            do { _ = try await session.data(from: URL(string: address)!); Issue.record("Network guard allowed a request") }
            catch { /* Expected: the protocol fails before any transport. */ }
        }
    }

    @Test @MainActor func draftSendRecordsReceiptAndCannotDeliverOrReplayChangedContent() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = try UIAcceptanceController(directory: directory)
        let store = controller.store, bot = controller.local
        let source = try #require(bot.messages.first)
        let block = try #require(ChatCardParser.parse(source.content).first)
        let target = ConversationActionTarget.bot(botID: bot.id, threadID: nil)
        store.selectedBot = controller.remote // Selection must not redirect the card.
        #expect(store.performCardAction(target: target, sourceID: source.id, index: 0, expected: block))
        let attempt = try #require(controller.backend.attempts.first)
        #expect(attempt.simulated && !attempt.delivered && attempt.conversationID == bot.id)
        #expect(attempt.to == "a@example.invalid" && attempt.body == "Dummy message. Nothing is sent.")
        #expect(source.metadata["draftSimulation.0"] == "simulated:true, delivered:false")
        let data = try Data(contentsOf: directory.appending(path: "send-\(attempt.id).json"))
        #expect(try JSONDecoder().decode(UIAcceptanceBackend.SendAttempt.self, from: data) == attempt)
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appending(path: "send-\(attempt.id).json").path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(!store.performCardAction(target: target, sourceID: source.id, index: 0, expected: block))
        #expect(controller.backend.attempts.count == 1 && store.runningTurns.isEmpty)
        if case .draft(var draft) = block {
            draft.body = "Changed"
            #expect(throws: UIAcceptanceError.self) {
                try controller.backend.recordSend(sourceID: source.id, conversationID: bot.id, index: 0, draft: draft)
            }
        }
    }

    @Test @MainActor func recorderFailureDoesNotMarkDraftSentAndSecretStaysInMemory() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = try UIAcceptanceController(directory: directory)
        let prompt = try #require(controller.backend.secretPrompt)
        #expect(controller.store.provideSecret(prompt, value: "dummy-never-a-real-key"))
        #expect(controller.backend.keys.key(for: "acceptance.dummy") == "dummy-never-a-real-key")
        #expect(controller.local.messages.count == 1 && controller.store.runningTurns.isEmpty)
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            if let data = try? Data(contentsOf: file) {
                #expect(!String(decoding: data, as: UTF8.self).contains("dummy-never-a-real-key"))
            }
        }
        let source = try #require(controller.local.messages.first)
        let block = try #require(ChatCardParser.parse(source.content).first)
        // Remove the sink after initialization to force a recording error before any UI success.
        try FileManager.default.removeItem(at: directory)
        #expect(!controller.store.performCardAction(target: .bot(botID: controller.local.id, threadID: nil),
                                                    sourceID: source.id, index: 0, expected: block))
        #expect(source.metadata["draftSent.0"] == nil && controller.backend.attempts.isEmpty)
    }

    @Test @MainActor func approvalVariantsBindDecisionsAndRejectDifferentOperation() async throws {
        for remote in [false, true] {
            for approved in [false, true] {
                let directory = try scratch()
                defer { try? FileManager.default.removeItem(at: directory) }
                let controller = try UIAcceptanceController(directory: directory)
                let bot = remote ? controller.remote : controller.local
                let card = try #require(controller.store.approvals.first { $0.botID == bot.id })
                let original = try #require(card.managedRecord)
                let bad = try JSONSerialization.data(withJSONObject: ["approved": approved, "fingerprint": String(repeating: "0", count: 64), "gate": original.gate])
                #expect(throws: UIAcceptanceError.self) {
                    try controller.backend.control(bot: bot, verb: "decide", task: original.id, input: bad)
                }
                controller.store.decide(card, approved: approved)
                try await waitUntil { !controller.store.managedDecisionsInFlight.contains(card.id) }
                #expect(!controller.store.approvals.contains { $0.id == card.id })
                let receipt = try #require(controller.backend.records[original.id])
                #expect(receipt.confirms(approved, original: original))
                #expect(controller.store.approvals.count == 1)
                #expect(controller.backend.attempts.isEmpty)
            }
        }
    }

    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "ui-acceptance-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return root
    }
}
#endif
