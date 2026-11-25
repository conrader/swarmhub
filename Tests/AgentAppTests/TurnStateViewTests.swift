import AppKit
import Foundation
import Testing
@testable import AgentApp

// P16 views: the footers and the warning line render; the sidebar badge (P20 item waiting on P16).

@MainActor @Test func theSidebarBadgeMarksAFailedOrIncompleteLastTurn() {
    let store = AppStore(storeURL: temporaryStore(), autoStart: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let bot = Bot(name: "Echo", backend: .herdr); store.bots = [bot]
    bot.messages = [ChatMessage(role: .user, content: "q"), ChatMessage(role: .assistant, content: "a", turnState: .finished)]
    #expect(!store.needsAttention(bot))
    bot.messages[1].turnState = .notSent
    #expect(store.needsAttention(bot))
    bot.messages[1].turnState = .incomplete
    #expect(store.needsAttention(bot))
    bot.messages[1].checkingSavedReply = true
    #expect(!store.needsAttention(bot))
    bot.messages[1].checkingSavedReply = false
    bot.messages[1].isStreaming = true
    #expect(!store.needsAttention(bot), "a reply still streaming is working, not failed")
    bot.messages[1].isStreaming = false; bot.messages[1].turnState = nil
    #expect(!store.needsAttention(bot), "rows written before P16 carry no badge")
}
