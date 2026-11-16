import Foundation
import Testing
@testable import AgentApp

// P32 1: the sample agents' cards are the real draft and choices cards, so every control in them works.
@MainActor @Test func sampleAgentsUseTheRealCards() {
    let store = AppStore(storeURL: temporaryStore(), autoStart: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    store.loadSamples()
    let messages = store.bots.flatMap(\.messages)
    #expect(!messages.isEmpty && messages.allSatisfy { $0.presentation == .text }, "no fixed-presentation sample cards")
    let blocks = messages.flatMap { ChatCardParser.parse($0.content) }
    #expect(blocks.contains { if case .draft(let draft) = $0 { draft.to?.contains("maya@") == true && draft.subject?.contains(AppConstants.name) == true } else { false } })
    #expect(blocks.contains { if case .choices(let prompt, let options) = $0 { !prompt.isEmpty && options.count == 3 } else { false } })
}

