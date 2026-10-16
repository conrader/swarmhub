import Foundation
import Testing
@testable import AgentApp

// P50: chats open where they were left, with Jump to latest. The view-model only: no real scrolling, no sleeps.

@MainActor private func store(at url: URL) -> AppStore {
    AppStore(storeURL: url, autoConfigureHermes: false, backendFactory: { _ in MockBackend() }, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
}

@MainActor @Test func thePositionIsSavedPerConversationAndRestoredAfterARelaunch() throws {
    let url = temporaryStore(), first = store(at: url)
    let bot = Bot(name: "Alpha", backend: .hermes), group = GroupChat(name: "Team", memberIDs: [bot.id])
    let chat = (0..<6).map { ChatMessage(role: $0.isMultiple(of: 2) ? .user : .assistant, content: "line \($0)") }
    bot.messages = chat; group.messages = Array(chat.prefix(4).map { ChatMessage(role: $0.role, content: $0.content) })
    first.bots = [bot]; first.groups = [group]
    first.chatScroll.saw(bot.id, top: chat[2].id, atBottom: false)
    first.chatScroll.saw(group.id, top: group.messages[1].id, atBottom: false)
    first.chatScroll.saw(group.id, top: group.messages[1].id, atBottom: true)
    #expect(first.chatScroll.open(bot.id, shown: chat.map(\.id)) == .message(chat[2].id))
    #expect(first.chatScroll.open(group.id, shown: group.messages.map(\.id)) == .newest, "left at the bottom: opens at the newest")
    first.save()

    let second = store(at: url)
    #expect(second.chatScroll.positions == [bot.id: chat[2].id])
    #expect(second.chatScroll.open(bot.id, shown: second.bots[0].messages.map(\.id)) == .message(chat[2].id))
    #expect(second.chatScroll.jumpLabel(bot.id) == "Jump to latest", "reopened in the middle: the button shows")
}

@MainActor @Test func anOldStoreWithoutPositionsLoads() throws {
    let url = temporaryStore()
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let bot = Bot(name: "Alpha", backend: .hermes); bot.messages = [ChatMessage(role: .user, content: "hi")]
    var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(StoreFile(bots: [bot], groups: []))) as? [String: Any])
    #expect(json["scrollPositions"] == nil, "absent while empty")
    json["scrollPositions"] = nil
    try JSONSerialization.data(withJSONObject: json).write(to: url)
    let loaded = store(at: url)
    #expect(loaded.bots.map(\.name) == ["Alpha"] && loaded.chatScroll.positions.isEmpty)
    #expect(loaded.chatScroll.open(bot.id, shown: bot.messages.map(\.id)) == .newest)
}

@MainActor @Test func aGoneMessageFallsBackToTheNewest() {
    let model = ChatScrollModel(), chat = UUID(), kept = UUID(), gone = UUID()
    model.saw(chat, top: gone, atBottom: false)
    #expect(model.open(chat, shown: [kept]) == .newest, "deleted, hidden as [SILENT] or trimmed")
    model.opened(chat, top: nil, atBottom: true)
    #expect(model.positions[chat] == nil && model.jumpLabel(chat) == nil)
}

@MainActor @Test func newCountsOnlyMessagesThatArriveWhileScrolledUp() {
    let model = ChatScrollModel(), chat = UUID(), other = UUID(), row = UUID()
    #expect(model.arrived(chat, count: 2), "at the bottom: follow, nothing counted")
    #expect(model.jumpLabel(chat) == nil && model.follows(chat))
    model.saw(chat, top: row, atBottom: false)
    #expect(model.jumpLabel(chat) == "Jump to latest" && !model.follows(chat))
    #expect(!model.arrived(chat, count: 2)); #expect(!model.arrived(chat, count: 1))
    #expect(model.jumpLabel(chat) == "Jump to latest · 3 new" && model.jumpLabel(other) == nil, "per conversation")
    // While the opening scroll settles, what the view shows is not the user's position.
    _ = model.open(chat, shown: [row])
    model.saw(chat, top: nil, atBottom: true)
    #expect(model.jumpLabel(chat) == "Jump to latest · 3 new")
    model.opened(chat, top: row, atBottom: false)
    model.saw(chat, top: row, atBottom: true)
    #expect(model.jumpLabel(chat) == nil, "scrolling back down clears the count")
    model.saw(chat, top: row, atBottom: false)
    #expect(model.jumpLabel(chat) == "Jump to latest", "a new scroll-up starts at zero")
}

@MainActor @Test func sendingAndJumpToLatestGoToTheBottom() {
    let model = ChatScrollModel(), chat = UUID(), row = UUID()
    model.saw(chat, top: row, atBottom: false); model.arrived(chat, count: 4)
    model.toBottom(chat)
    #expect(model.jumpLabel(chat) == nil && model.positions[chat] == nil && model.arrived(chat, count: 1), "the sent message is followed")
    #expect(model.open(chat, shown: [row]) == .newest)
}
