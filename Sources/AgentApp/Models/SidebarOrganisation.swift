import Foundation

/// A named group of chats in the sidebar, folded or open. Only ids are kept, so a chat's own data lives in one place.
struct SidebarSection: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var collapsed: Bool
    var chats: [UUID]

    init(id: UUID = UUID(), name: String, collapsed: Bool = false, chats: [UUID] = []) {
        self.id = id; self.name = name; self.collapsed = collapsed; self.chats = chats
    }

    enum CodingKeys: String, CodingKey { case id, name, collapsed, chats }
    /// Lenient: a field a later build adds, or one missing here, never makes the store unreadable.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        collapsed = try c.decodeIfPresent(Bool.self, forKey: .collapsed) ?? false
        chats = try c.decodeIfPresent([UUID].self, forKey: .chats) ?? []
    }
}

/// How the user has arranged the sidebar: pinned chats, named sections and which folds are shut. Saved in store.json
/// only while something is arranged. All the rules live here so they can be tested without a store.
struct SidebarOrganisation: Codable, Equatable {
    static let maxPinned = 9
    static let maxNameLength = 48
    var pinned: [UUID] = []
    var sections: [SidebarSection] = []
    var unsectionedCollapsed = false

    init() {}

    var isEmpty: Bool { pinned.isEmpty && sections.isEmpty && !unsectionedCollapsed }

    enum CodingKeys: String, CodingKey { case pinned, sections, unsectionedCollapsed }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pinned = try c.decodeIfPresent([UUID].self, forKey: .pinned) ?? []
        sections = try c.decodeIfPresent([SidebarSection].self, forKey: .sections) ?? []
        unsectionedCollapsed = try c.decodeIfPresent(Bool.self, forKey: .unsectionedCollapsed) ?? false
    }

    // MARK: Names

    /// The name a section would get, or nil when it is not allowed: trimmed, 1 to 48 characters, not in use by another
    /// section (ignoring case) and not one of the two fixed names.
    func validatedName(_ raw: String, excluding id: UUID? = nil) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= SidebarOrganisation.maxNameLength else { return nil }
        let key = name.lowercased()
        if key == "pinned" || key == "unsectioned" { return nil }
        for section in sections where section.id != id && section.name.lowercased() == key { return nil }
        return name
    }

    func section(_ id: UUID) -> SidebarSection? { sections.first { $0.id == id } }

    /// The section a chat is in, nil for Unsectioned.
    func sectionID(of chat: UUID) -> UUID? { sections.first { $0.chats.contains(chat) }?.id }

    // MARK: Sections

    /// Adds a section at the end, with the chat in it when one is given. Returns its id, or nil for a refused name.
    @discardableResult
    mutating func createSection(named raw: String, adding chat: UUID? = nil) -> UUID? {
        guard let name = validatedName(raw) else { return nil }
        let section = SidebarSection(name: name)
        sections.append(section)
        if let chat { moveChat(chat, toSection: section.id) }
        return section.id
    }

    @discardableResult
    mutating func renameSection(_ id: UUID, to raw: String) -> Bool {
        guard let index = sections.firstIndex(where: { $0.id == id }), let name = validatedName(raw, excluding: id) else { return false }
        sections[index].name = name
        return true
    }

    /// The section goes; its chats stop being members and so show as Unsectioned. No chat is touched.
    mutating func deleteSection(_ id: UUID) {
        sections.removeAll { $0.id == id }
    }

    mutating func moveSection(_ id: UUID, by offset: Int) {
        guard let index = sections.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard target >= 0, target < sections.count, target != index else { return }
        let section = sections.remove(at: index)
        sections.insert(section, at: target)
    }

    /// nil is the Unsectioned bucket.
    mutating func setCollapsed(_ id: UUID?, _ collapsed: Bool) {
        guard let id else { unsectionedCollapsed = collapsed; return }
        guard let index = sections.firstIndex(where: { $0.id == id }) else { return }
        sections[index].collapsed = collapsed
    }

    /// A chat is in at most one section: it leaves every other one first. nil puts it in Unsectioned.
    mutating func moveChat(_ chat: UUID, toSection id: UUID?) {
        for index in sections.indices { sections[index].chats.removeAll { $0 == chat } }
        guard let id, let index = sections.firstIndex(where: { $0.id == id }) else { return }
        sections[index].chats.append(chat)
    }

    // MARK: Pins

    var canPinMore: Bool { pinned.count < SidebarOrganisation.maxPinned }

    /// Pins at the end of the strip; false when it is full. Section membership is kept.
    @discardableResult
    mutating func pin(_ chat: UUID) -> Bool {
        if pinned.contains(chat) { return true }
        guard canPinMore else { return false }
        pinned.append(chat)
        return true
    }

    mutating func unpin(_ chat: UUID) { pinned.removeAll { $0 == chat } }

    /// Drops ids that are not chats any more and repeats, so a stale or hand-edited file cannot misdraw the list.
    mutating func prune(keeping validIDs: Set<UUID>) {
        var seenPins = Set<UUID>()
        pinned = pinned.filter { validIDs.contains($0) && seenPins.insert($0).inserted }
        if pinned.count > SidebarOrganisation.maxPinned { pinned = Array(pinned.prefix(SidebarOrganisation.maxPinned)) }
        var seen = Set<UUID>()
        for index in sections.indices {
            sections[index].chats = sections[index].chats.filter { validIDs.contains($0) && seen.insert($0).inserted }
        }
    }
}
