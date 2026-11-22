import Foundation

extension SidebarChat {
    var isUnread: Bool {
        switch self { case .bot(let bot): bot.isUnread; case .group(let group): group.isUnread }
    }
    var displayName: String {
        switch self { case .bot(let bot): bot.name; case .group(let group): group.name }
    }
}

/// What the sidebar draws, worked out in one pass from the already-sorted visible chats and the user's arrangement.
struct SidebarLayout {
    /// One run of rows under one header. `id` nil is Unsectioned.
    struct Bucket: Identifiable {
        let id: UUID?
        let name: String
        let showsHeader: Bool
        let isCollapsed: Bool
        let chats: [SidebarChat]
        let hasUnread: Bool
        var key: String { id?.uuidString ?? "unsectioned" }
    }

    let pinned: [SidebarChat]
    let sections: [Bucket]
    /// Pinned first, then the rows of the open buckets, top to bottom. Keyboard navigation walks this.
    let navigationOrder: [SidebarChat]

    static func make(chats: [SidebarChat], organisation: SidebarOrganisation) -> SidebarLayout {
        // Nothing arranged: one headerless bucket equal to the input.
        if organisation.pinned.isEmpty && organisation.sections.isEmpty {
            let bucket = Bucket(id: nil, name: "Unsectioned", showsHeader: false, isCollapsed: false, chats: chats,
                                hasUnread: chats.contains { $0.isUnread })
            return SidebarLayout(pinned: [], sections: [bucket], navigationOrder: chats)
        }
        var byID: [UUID: SidebarChat] = [:]
        for chat in chats { byID[chat.id] = chat }
        var pinned: [SidebarChat] = []
        var pinnedIDs = Set<UUID>()
        for id in organisation.pinned {
            if let chat = byID[id], pinnedIDs.insert(id).inserted { pinned.append(chat) }
        }
        var sectionOf: [UUID: Int] = [:]
        for (index, section) in organisation.sections.enumerated() {
            for id in section.chats where sectionOf[id] == nil { sectionOf[id] = index }
        }
        var members: [[SidebarChat]] = Array(repeating: [], count: organisation.sections.count)
        var loose: [SidebarChat] = []
        for chat in chats where !pinnedIDs.contains(chat.id) {
            if let index = sectionOf[chat.id] { members[index].append(chat) } else { loose.append(chat) }
        }
        var buckets: [Bucket] = []
        for (index, section) in organisation.sections.enumerated() {
            buckets.append(Bucket(id: section.id, name: section.name, showsHeader: true, isCollapsed: section.collapsed,
                                  chats: members[index], hasUnread: members[index].contains { $0.isUnread }))
        }
        // "Unsectioned" is listed only while something is in it (or there is no section at all): an empty one under the
        // user's sections would be a header about nothing.
        let showsUnsectionedHeader = !organisation.sections.isEmpty
        if !loose.isEmpty || organisation.sections.isEmpty {
            buckets.append(Bucket(id: nil, name: "Unsectioned", showsHeader: showsUnsectionedHeader,
                                  isCollapsed: showsUnsectionedHeader && organisation.unsectionedCollapsed,
                                  chats: loose, hasUnread: loose.contains { $0.isUnread }))
        }
        var order = pinned
        for bucket in buckets where !bucket.isCollapsed { order += bucket.chats }
        return SidebarLayout(pinned: pinned, sections: buckets, navigationOrder: order)
    }
}
