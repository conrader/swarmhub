import Foundation

struct NativeSidebarRow: Identifiable {
    let thread: HerdrClient.NativeThread
    let target: LiveTerminal
    let depth: Int
    let hasChildren: Bool
    let folded: Bool
    var id: LiveTerminal.Source { target.id }
}

private struct ThreadKey: Hashable {
    let provider: HerdrClient.ChildRuntime
    let id: String
}

extension AppStore {
    private func nativeFoldsKey(for bot: Bot) -> String {
        "sidebar.foldedNativeSessions." + bot.id.uuidString + "." + herdrServer(for: bot).id
    }

    private func nativeFolds(for bot: Bot) -> Set<LiveTerminal.Source> {
        guard let data = defaults.data(forKey: nativeFoldsKey(for: bot)) else { return [] }
        return (try? JSONDecoder().decode(Set<LiveTerminal.Source>.self, from: data)) ?? []
    }

    func setNativeSessionFolded(_ closed: Bool, target: LiveTerminal.Source, for bot: Bot) {
        var folded = nativeFolds(for: bot)
        guard folded.contains(target) != closed else { return }
        if closed { folded.insert(target) } else { folded.remove(target) }
        let key = nativeFoldsKey(for: bot)
        if folded.isEmpty { defaults.removeObject(forKey: key) }
        else if let data = try? JSONEncoder().encode(folded) { defaults.set(data, forKey: key) }
        objectWillChange.send()
    }

    func nativeSidebarRows(_ list: HerdrClient.Helpers, for bot: Bot) -> [NativeSidebarRow] {
        let threads = list.nativeThreads
        let folded = nativeFolds(for: bot)
        let ids = Set(threads.map { ThreadKey(provider: $0.provider, id: $0.id) })
        let children = Dictionary(grouping: threads) { ThreadKey(provider: $0.provider, id: $0.parent) }
        let roots = threads.filter { !ids.contains(ThreadKey(provider: $0.provider, id: $0.parent)) }
        var pending = roots.reversed().map { ($0, 0) }
        var seen: Set<ThreadKey> = []
        var result: [NativeSidebarRow] = []
        while let (thread, depth) = pending.popLast() {
            let key = ThreadKey(provider: thread.provider, id: thread.id)
            guard seen.insert(key).inserted else { continue }
            let nested = children[key] ?? []
            let target = LiveTerminal(thread: thread, owner: list.parent, core: list.core)
            let closed = folded.contains(target.id)
            result.append(.init(thread: thread, target: target, depth: depth, hasChildren: !nested.isEmpty, folded: closed))
            if !closed {
                pending += nested.reversed().map { ($0, depth + 1) }
            }
        }
        return result
    }
}
