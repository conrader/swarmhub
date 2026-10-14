import Foundation

/// P32 4: the quick switcher's rows and its keyboard highlight. The first enabled match is highlighted; up and down move
/// over enabled rows and stop at the ends; Return opens the highlighted row.
struct QuickSwitcherModel: Equatable {
    struct Item: Identifiable, Equatable {
        enum Target: Equatable { case bot(UUID), group(UUID), command(AppCommand), setup }
        var id: String; var title: String; var icon: String; var shortcut: String? = nil; var isEnabled = true; var target: Target
        /// Commands come after a divider.
        var isCommand: Bool { if case .bot = target { false } else if case .group = target { false } else { true } }
    }

    private(set) var items: [Item] = []
    private(set) var highlighted: String?

    init(items: [Item] = []) { update(items) }

    /// New matches (the query changed): the first enabled one is highlighted.
    mutating func update(_ items: [Item]) {
        self.items = items
        highlighted = items.first(where: \.isEnabled)?.id
    }

    mutating func move(by offset: Int) {
        let enabled = items.filter(\.isEnabled)
        guard !enabled.isEmpty else { highlighted = nil; return }
        let index = enabled.firstIndex { $0.id == highlighted } ?? (offset > 0 ? -1 : enabled.count)
        highlighted = enabled[min(max(index + offset, 0), enabled.count - 1)].id
    }

    mutating func highlight(_ id: String) { if items.contains(where: { $0.id == id && $0.isEnabled }) { highlighted = id } }

    var selection: Item? { items.first { $0.id == highlighted && $0.isEnabled } }

    @MainActor static func items(in store: AppStore, query: String) -> [Item] {
        func matches(_ title: String) -> Bool { query.isEmpty || title.localizedCaseInsensitiveContains(query) }
        var items = store.bots.filter { matches($0.name) }.map { Item(id: "bot-\($0.id)", title: $0.name, icon: "message", target: .bot($0.id)) }
        items += store.groups.filter { matches($0.name) }.map { Item(id: "group-\($0.id)", title: $0.name, icon: "person.3", target: .group($0.id)) }
        items += AppCommand.allCases.filter { $0 != .quickSwitcher && matches($0.title) }.map {
            Item(id: "command-\($0.rawValue)", title: $0.title, icon: $0.icon, shortcut: $0.shortcutText, isEnabled: $0.isEnabled(in: store), target: .command($0))
        }
        let setup = store.boxConfigured ? SimpleCopy.changeConnection : SimpleCopy.setUp
        if matches(setup) { items.append(Item(id: "setup", title: setup, icon: "link", target: .setup)) }
        return items
    }
}
