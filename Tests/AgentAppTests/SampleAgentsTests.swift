import Foundation
import Testing
@testable import AgentApp

// P32 1: the sample agents' cards are the real draft and choices cards, so every control in them works.
@MainActor @Test func sampleAgentsUseTheRealCards() {
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    store.loadSamples()
    let messages = store.bots.flatMap(\.messages)
    #expect(!messages.isEmpty && messages.allSatisfy { $0.presentation == .text }, "no fixed-presentation sample cards")
    let blocks = messages.flatMap { ChatCardParser.parse($0.content) }
    #expect(blocks.contains { if case .draft(let draft) = $0 { draft.to?.contains("maya@") == true && draft.subject?.contains(AppConstants.name) == true } else { false } })
    #expect(blocks.contains { if case .choices(let prompt, let options) = $0 { !prompt.isEmpty && options.count == 3 } else { false } })
}

@Test func aStoredLegacyPresentationReadsAsText() throws {
    let json = #"{"id":"\#(UUID())","role":"assistant","content":"Voice note","createdAt":1,"presentation":"voiceMemo","metadata":{"duration":"0:18"},"reactions":[]}"#
    let message = try JSONDecoder().decode(ChatMessage.self, from: Data(json.utf8))
    #expect(message.presentation == .text && message.content == "Voice note")
    let routine = #"{"id":"\#(UUID())","role":"assistant","content":"r","createdAt":1,"presentation":"routineResult","metadata":{},"reactions":[]}"#
    #expect(try JSONDecoder().decode(ChatMessage.self, from: Data(routine.utf8)).presentation == .routineResult)
}
