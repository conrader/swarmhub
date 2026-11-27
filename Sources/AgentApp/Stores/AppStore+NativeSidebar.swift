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

    func nativeSidebarRows(_ list: HerdrClient.Helpers, for bot: Bot, includingFolded: Bool = false) -> [NativeSidebarRow] {
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
            if includingFolded || !closed {
                pending += nested.reversed().map { ($0, depth + 1) }
            }
        }
        return result
    }
}


// Both sidebar renderers walk the same ordered rows, including provider threads started by workspace helpers.
enum SidebarSessionItem: Identifiable {
    case workspace(SidebarHelperSession)
    case native(NativeSidebarRow, selection: HerdrHelperSelection, depth: Int)

    var id: LiveTerminal.Source {
        switch self {
        case .workspace(let row): .agent(row.helper.ref)
        case .native(let row, _, _): row.id
        }
    }

    var depth: Int {
        switch self {
        case .workspace(let row): row.depth
        case .native(_, _, let depth): depth
        }
    }

    var selection: HerdrHelperSelection {
        switch self {
        case .workspace(let row): row.id
        case .native(_, let selection, _): selection
        }
    }

    var terminal: LiveTerminal? {
        switch self {
        case .workspace(let row): row.helper.isLive ? LiveTerminal(agent: row.helper.ref, title: row.helper.name, core: row.core) : nil
        case .native(let row, _, _): row.target
        }
    }
}

extension AppStore {
    func sessionsExpanded(for bot: Bot) -> Bool { defaults.object(forKey: bot.sessionsExpandedKey) as? Bool ?? true }

    func setSessionsExpanded(_ expanded: Bool, for bot: Bot) {
        defaults.set(expanded, forKey: bot.sessionsExpandedKey)
        objectWillChange.send()
    }

    func sidebarRoots(for bot: Bot) -> [HerdrHelperParent] {
        Self.sortedSidebarRoots(herdrHelpers.keys.filter { $0.botID == bot.id && $0.source == nil && herdrHelpers[$0]?.hasSidebarSessions == true })
    }

    static func sortedSidebarRoots(_ roots: [HerdrHelperParent]) -> [HerdrHelperParent] {
        roots.sorted {
            if $0.groupRuntime != $1.groupRuntime { return ($0.groupRuntime ?? "") < ($1.groupRuntime ?? "") }
            return ($0.archive?.session.createdMs ?? .max) > ($1.archive?.session.createdMs ?? .max)
        }
    }

    /// The inspector and Back can navigate to a session even while its branch is folded.
    func revealSession(_ selection: HerdrHelperSelection, for bot: Bot) {
        guard selection.botID == bot.id else { return }
        let root = HerdrHelperParent(botID: bot.id, groupRuntime: selection.groupRuntime, archive: selection.archive)
        let rows = sessionRows(under: root, for: bot, includingFolded: true)
        let index = rows.firstIndex { row in
            let candidate = row.selection
            guard candidate.parent == selection.parent, candidate.helperID == selection.helperID else { return false }
            if let native = selection.native {
                return candidate.native?.server == native.server && candidate.native?.core == native.core
                    && candidate.native?.owner == native.owner && candidate.native?.thread.provider == native.thread.provider
            }
            return candidate.native == nil
        }
        guard let index else { return }
        var depth = rows[index].depth
        for row in rows[..<index].reversed() where row.depth < depth {
            switch row {
            case .native(let ancestor, _, _): setNativeSessionFolded(false, target: ancestor.id, for: bot)
            case .workspace(let ancestor): setHelperBranchFolded(false, branch: ancestor.branch, for: bot)
            }
            depth = row.depth
            if depth == 0 { break }
        }
        if !sessionsExpanded(for: bot) { setSessionsExpanded(true, for: bot) }
        if let bucket = sidebarLayout.sections.first(where: { $0.isCollapsed && $0.chats.contains { $0.id == bot.id } }) {
            setSidebarSectionCollapsed(bucket.id, false)
        }
        if bot.isHidden && !showingHiddenBots { showingHiddenBots = true }
    }

    func sessionRows(under parent: HerdrHelperParent, for bot: Bot, includingFolded: Bool = false) -> [SidebarSessionItem] {
        func native(under parent: HerdrHelperParent, depth: Int) -> [SidebarSessionItem] {
            guard let list = herdrHelpers[parent], !list.nativeThreads.isEmpty else { return [] }
            let server = herdrServer(for: bot)
            return nativeSidebarRows(list, for: bot, includingFolded: includingFolded).map { row in
                let selection = HerdrHelperSelection(botID: bot.id, helperID: row.thread.id, groupRuntime: parent.groupRuntime,
                                                     source: parent.source, archive: parent.archive,
                                                     native: .init(thread: row.thread, core: list.core, owner: list.parent, server: server))
                return .native(row, selection: selection, depth: depth + row.depth)
            }
        }
        var entries = native(under: parent, depth: 0)
        let helpers = includingFolded ? sidebarSessions(under: parent) : visibleHelperSessions(under: parent, for: bot)
        for helper in helpers {
            entries.append(.workspace(helper))
            if !helper.folded {
                let owner = helper.id.parent.children(of: helper.helper.ref, core: helper.core)
                entries += native(under: owner, depth: helper.depth + 1)
            }
        }
        return entries
    }
}
