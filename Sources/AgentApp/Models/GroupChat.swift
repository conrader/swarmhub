import Combine
import Foundation

/// A group chat: the user plus several bots in one shared thread. Each member answers through its own agent; a backend
/// that keeps sessions gets one dedicated to this group (`group-<group id>-<bot id>`), see `GroupRouting`.
final class GroupChat: ObservableObject, Identifiable, Codable, Hashable, Conversation {
    let id: UUID; let createdAt: Date
    @Published var name: String; @Published var memberIDs: [UUID]; @Published var messages: [ChatMessage]
    @Published var unreadCount: Int; @Published var manualUnread: Bool; @Published var isHidden: Bool; @Published var isMuted: Bool
    /// Session id per member (key: lowercased bot UUID).
    @Published var sessions: [String: String]
    /// Grok import: source id and size of the read-only archive in `grok-history/<group id>.json`.
    @Published var grokSourceID: String?; @Published var grokHistoryCount: Int
    /// The member answering right now (not saved); `sessionID` follows it so Stop and steer reach its run.
    var activeMemberID: UUID?
    /// P16: the round in progress (saved; encoded only when set).
    var round: GroupRound?

    init(id: UUID = UUID(), name: String, memberIDs: [UUID], messages: [ChatMessage] = [], createdAt: Date = .now) {
        self.id = id; self.name = name; self.memberIDs = memberIDs; self.messages = messages; self.createdAt = createdAt
        unreadCount = 0; manualUnread = false; isHidden = false; isMuted = false; sessions = [:]; grokSourceID = nil; grokHistoryCount = 0
    }

    static func == (lhs: GroupChat, rhs: GroupChat) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    var isUnread: Bool { unreadCount > 0 || manualUnread }
    func session(for botID: UUID) -> String? { sessions[botID.uuidString.lowercased()] }
    var sessionID: String? {
        get { activeMemberID.flatMap(session(for:)) }
        set { if let id = activeMemberID { sessions[id.uuidString.lowercased()] = newValue } }
    }

    enum CodingKeys: CodingKey { case id, name, memberIDs, messages, unreadCount, manualUnread, isHidden, isMuted, sessions, grokSourceID, grokHistoryCount, createdAt, round }
    required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Group"
        memberIDs = try c.decodeIfPresent([UUID].self, forKey: .memberIDs) ?? []; messages = try c.decodeIfPresent([ChatMessage].self, forKey: .messages) ?? []
        unreadCount = try c.decodeIfPresent(Int.self, forKey: .unreadCount) ?? 0; manualUnread = try c.decodeIfPresent(Bool.self, forKey: .manualUnread) ?? false
        isHidden = try c.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false; isMuted = try c.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        sessions = try c.decodeIfPresent([String: String].self, forKey: .sessions) ?? [:]
        grokSourceID = try c.decodeIfPresent(String.self, forKey: .grokSourceID); grokHistoryCount = try c.decodeIfPresent(Int.self, forKey: .grokHistoryCount) ?? 0
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        // A malformed round must not cost the store.
        round = (try? c.decodeIfPresent(GroupRound.self, forKey: .round)) ?? nil
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(name, forKey: .name); try c.encode(memberIDs, forKey: .memberIDs); try c.encode(messages, forKey: .messages)
        try c.encode(unreadCount, forKey: .unreadCount); try c.encode(manualUnread, forKey: .manualUnread); try c.encode(isHidden, forKey: .isHidden); try c.encode(isMuted, forKey: .isMuted)
        try c.encode(sessions, forKey: .sessions); try c.encodeIfPresent(grokSourceID, forKey: .grokSourceID); try c.encode(grokHistoryCount, forKey: .grokHistoryCount)
        try c.encode(createdAt, forKey: .createdAt); try c.encodeIfPresent(round, forKey: .round)
    }
}

/// store.json. Version 1 was a bare array of bots; version 2 is `{"version": 2, "bots": […], "groups": […]}`.
/// Both decode; saving always writes the current version. A key this build does not know (the settings of features
/// older builds had) is ignored, never an error.
struct StoreFile: Codable {
    static let currentVersion = 2
    var version = StoreFile.currentVersion; var bots: [Bot]; var groups: [GroupChat]
    /// Each chat's top visible message (conversation id → message id); absent while empty.
    var scrollPositions: [String: String]?
    var removedBots: [String: Set<String>]?

    init(bots: [Bot], groups: [GroupChat], scrollPositions: [String: String]? = nil) {
        self.bots = bots; self.groups = groups; self.scrollPositions = scrollPositions
    }

    enum CodingKeys: CodingKey { case version, bots, groups, scrollPositions, removedBots }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        guard version <= StoreFile.currentVersion, c.contains(.bots) || c.contains(.groups) else {
            throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath, debugDescription: "Unsupported store structure."))
        }
        bots = try c.decodeIfPresent([Bot].self, forKey: .bots) ?? []
        groups = try c.decodeIfPresent([GroupChat].self, forKey: .groups) ?? []
        scrollPositions = (try? c.decodeIfPresent([String: String].self, forKey: .scrollPositions)) ?? nil
        removedBots = try c.decodeIfPresent([String: Set<String>].self, forKey: .removedBots)
    }

    static func decode(_ data: Data) throws -> StoreFile {
        let first = data.first { ![0x20, 0x09, 0x0A, 0x0D].contains($0) }
        guard first == UInt8(ascii: "[") else { return try JSONDecoder().decode(StoreFile.self, from: data) }
        var file = StoreFile(bots: try JSONDecoder().decode([Bot].self, from: data), groups: [])
        file.version = 1
        return file
    }

    mutating func migrateArchivedGroups() -> [String] {
        let archived = bots.filter { $0.retiredBackend == nil && $0.archivedMembers != nil }
        var names: [String] = []
        for old in archived {
            let ids = AppStore.resolveMembers((old.archivedMembers ?? []).map { ($0, nil) }, from: bots)
            let group = GroupChat(id: old.id, name: old.name, memberIDs: ids, messages: old.messages, createdAt: old.createdAt)
            group.grokSourceID = old.grokSourceID; group.grokHistoryCount = old.grokHistoryCount
            group.isHidden = old.isHidden; group.isMuted = !old.notificationsEnabled
            group.unreadCount = old.unreadCount; group.manualUnread = old.manualUnread
            if let existing = groups.first(where: { $0.id == group.id }) {
                let saved = Set(existing.messages.map(\.id))
                existing.messages += group.messages.filter { !saved.contains($0.id) }
                existing.messages.sort { $0.createdAt < $1.createdAt }
                existing.grokSourceID = existing.grokSourceID ?? group.grokSourceID
                existing.grokHistoryCount = max(existing.grokHistoryCount, group.grokHistoryCount)
            } else {
                groups.append(group); names.append(group.name)
            }
        }
        let archivedIDs = Set(archived.map(\.id))
        bots.removeAll { archivedIDs.contains($0.id) }
        return names
    }
}
