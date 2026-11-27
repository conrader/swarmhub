import Foundation
import Testing
@testable import AgentApp

private func item(_ id: String, enabled: Bool = true) -> QuickSwitcherModel.Item {
    .init(id: id, title: id, icon: "message", isEnabled: enabled, target: .setup)
}

// P32 4: the quick switcher's keyboard selection.
@Test func quickSwitcherHighlightsTheFirstMatchAndMovesOverEnabledRows() {
    var model = QuickSwitcherModel(items: [item("off", enabled: false), item("a"), item("b"), item("off2", enabled: false), item("c")])
    #expect(model.highlighted == "a" && model.selection?.id == "a", "the first enabled match")
    model.move(by: -1); #expect(model.highlighted == "a", "stops at the top")
    model.move(by: 1); #expect(model.highlighted == "b")
    model.move(by: 1); #expect(model.highlighted == "c", "skips a disabled row")
    model.move(by: 1); #expect(model.highlighted == "c", "stops at the bottom")
    model.highlight("off2"); #expect(model.highlighted == "c", "a disabled row cannot be highlighted")
    model.highlight("a"); #expect(model.selection?.id == "a")
    model.update([item("x"), item("y")]); #expect(model.highlighted == "x", "a new query highlights its first match")
    model.update([item("z", enabled: false)]); #expect(model.highlighted == nil && model.selection == nil, "Return does nothing")
    model.move(by: 1); #expect(model.highlighted == nil)
    model.update([]); #expect(model.selection == nil)
}

@MainActor @Test func quickSwitcherItemsFilterAgentsGroupsAndCommands() {
    let store = AppStore(storeURL: temporaryStore(), autoStart: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    store.bots = [Bot(name: "Atlas"), Bot(name: "Mira")]
    let all = QuickSwitcherModel.items(in: store, query: "")
    #expect(Array(all.prefix(2)).map(\.title) == ["Atlas", "Mira"] && !all[0].isCommand)
    #expect(all.contains { $0.target == .command(.newGroup) } && !all.contains { $0.target == .command(.quickSwitcher) })
    let atlas = QuickSwitcherModel.items(in: store, query: "atl")
    #expect(atlas.map(\.title) == ["Atlas"])
    var model = QuickSwitcherModel(items: atlas)
    #expect(model.selection?.target == .bot(store.bots[0].id), "Return opens Atlas")
    model.update(QuickSwitcherModel.items(in: store, query: "zzzz-nothing")); #expect(model.selection == nil)
}

@MainActor @Test func quickSwitcherSearchesSavedMessageTextAndKeepsItsDestination() async {
    let store = AppStore(storeURL: temporaryStore(), autoStart: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let bot = Bot(name: "Forge")
    let group = GroupChat(name: "Launch", memberIDs: [bot.id])
    let older = ChatMessage(role: .user, content: String(repeating: "context ", count: 150) + "Résumé for release")
    let newer = ChatMessage(role: .assistant, content: "Here is the **résumé** for release.", createdAt: older.createdAt.addingTimeInterval(10), authorID: bot.id)
    bot.messages = [older, ChatMessage(role: .assistant, content: "[SILENT]")]
    group.messages = [newer]
    store.bots = [bot]
    store.groups = [group]

    let hits = await QuickSwitcherModel.messages(in: store, query: "  RESUME  ")
    #expect(hits.map(\.target) == [.message(.init(conversation: group.id, message: newer.id)),
                                   .message(.init(conversation: bot.id, message: older.id))])
    #expect(hits.first?.detail?.contains("Launch · Forge") == true)
    #expect(hits.last?.title.hasPrefix("…") == true && hits.last?.title.contains("Résumé for release") == true)
    #expect(await QuickSwitcherModel.messages(in: store, query: "résumé for release").count == 2)
    #expect(await QuickSwitcherModel.messages(in: store, query: "silent").isEmpty)
    #expect(await QuickSwitcherModel.messages(in: store, query: " ").isEmpty)
}

@MainActor @Test func quickSwitcherFindsImportedRowsOnDiskWithNoLiveChatRows() async throws {
    let store = AppStore(storeURL: temporaryStore(), autoStart: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let bot = Bot(name: "Scout")
    bot.grokSourceID = "scout"
    store.bots = [bot]
    let archive = store.grokHistory.fileURL(for: bot.id)
    let visible = ArchivedMessage(id: "", seq: 9, role: "assistant", author: "Atlas", text: "Budget *literal*",
                                  timestamp: nil, hidden: false, channel: "agent", to: "Scout")
    var hidden = visible
    hidden.seq = 10
    hidden.hidden = true
    try FileManager.default.createDirectory(at: archive.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(GrokHistoryFile(sourceID: "scout", messages: [visible, hidden])).write(to: archive)
    let files = QuickSwitcherModel.ArchiveFiles()
    let hits = await QuickSwitcherModel.messages(in: store, query: "*literal*", files: files)
    #expect(hits.map(\.target) == [.message(.init(conversation: bot.id, imported: "seq:9"))])
    #expect(hits.first?.detail?.contains("Atlas → Scout") == true)
    #expect(hits.first?.detail?.contains("Grok history") == true)
    #expect(!store.grokHistory.isLoaded(bot.id))
    let page = await GrokHistoryPage.containing("seq:9", cached: nil, url: archive)
    #expect(page?.rows.map(\.seq) == [9])
    #expect(page?.earlier == nil && page?.later == nil)

    var revised = visible
    revised.text = "New budget from the imported file"
    try JSONEncoder().encode(GrokHistoryFile(sourceID: "scout", messages: [revised])).write(to: archive, options: .atomic)
    #expect(await QuickSwitcherModel.messages(in: store, query: "New budget", files: files).count == 1)
    try FileManager.default.removeItem(at: archive)
    #expect(await QuickSwitcherModel.messages(in: store, query: "New budget", files: files).isEmpty)
}

@MainActor @Test func quickSwitcherKeepsPageWorkspaceAndRevisionAcrossRepeatedPublications() async throws {
    let store = AppStore(storeURL: temporaryStore(), autoStart: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let bot = Bot(name: "Scout")
    func message(server: String, revision: Int) throws -> ChatMessage {
        let row = ChatMessage(role: .assistant, content: "Read the attached Page.")
        let data = Data(#"{"serverID":"\#(server)","items":[{"id":94,"kind":"page","title":"Résumé","pageID":7,"revision":\#(revision)}]}"#.utf8)
        row.publishedResults = try JSONDecoder().decode(HerdrReplyResults.self, from: data)
        if revision == 3 { row.publishedResults?.items[0].excerpt = "Un déploiement validé." }
        return row
    }
    bot.messages = try [message(server: "mac", revision: 2), message(server: "mac", revision: 2),
                        message(server: "mac", revision: 3), message(server: "linux", revision: 2)]
    store.bots = [bot]
    let results = await QuickSwitcherModel.messages(in: store, query: "resume")
    let pages = results.compactMap { item -> WorkspacePageLink? in
        if case .page(let link) = item.target { return link }
        return nil
    }
    let fromExcerpt = await QuickSwitcherModel.messages(in: store, query: "deploiement")
    #expect(fromExcerpt.map(\.target) == [.page(.init(serverID: "mac", pageID: 7, revision: 3, title: "Résumé"))])
    #expect(pages.count == 3)
    #expect(Set(pages) == [.init(serverID: "mac", pageID: 7, revision: 2, title: "Résumé"),
                           .init(serverID: "mac", pageID: 7, revision: 3, title: "Résumé"),
                           .init(serverID: "linux", pageID: 7, revision: 2, title: "Résumé")])
}
