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
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
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
