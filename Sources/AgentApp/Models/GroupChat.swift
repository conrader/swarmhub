import Combine
import Foundation

/// A group chat: the user plus several bots in one shared thread. Each member answers in its own Hermes
/// session dedicated to this group (`group-<group id>-<bot id>`), see `GroupRouting`.
final class GroupChat: ObservableObject, Identifiable, Codable, Hashable, Conversation {
    let id: UUID; let createdAt: Date
    @Published var name: String; @Published var memberIDs: [UUID]; @Published var messages: [ChatMessage]
    @Published var unreadCount: Int; @Published var manualUnread: Bool; @Published var isHidden: Bool; @Published var isMuted: Bool
    /// Hermes session id per member (key: lowercased bot UUID).
    @Published var sessions: [String: String]
    /// Grok import: source id and size of the read-only archive in `grok-history/<group id>.json`.
    @Published var grokSourceID: String?; @Published var grokHistoryCount: Int
    /// The member answering right now (not saved); `hermesSessionID` follows it so Stop and steer reach its run.
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
    var hermesSessionID: String? {
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
/// Both decode; saving always writes the current version.
struct StoreFile: Codable {
    static let currentVersion = 2
    var version = StoreFile.currentVersion; var bots: [Bot]; var groups: [GroupChat]
    /// P13 app-wide model defaults; absent (nil) while empty, so an unconfigured store encodes as before.
    var modelDefaults: ModelDefaults?
    /// P37 D2: SwarmHub-wide approval lines and review-after lines; absent while empty.
    var approvalRoutes: [ApprovalRoute]?; var reviewAfter: [ReviewAfterRule]?
    /// P31 D+E: each box's last models and capacity reports (keyed by connection); absent while empty.
    var boxReadings: [String: BoxReadings]?
    /// P41: bot-message seen marks (connection|profile → session id → mark); absent while empty.
    var botMessageMarks: [String: [String: String]]?
    /// P45: each chat's goal, loop and heartbeat (keyed by the chat's id); absent while empty.
    var automations: [String: ChatAutomation]?
    /// P46: the heartbeat template, each bot's plan and its "Bot Chat" title; absent while empty.
    var heartbeat: HeartbeatSettings?

    init(bots: [Bot], groups: [GroupChat], modelDefaults: ModelDefaults? = nil, approvalRoutes: [ApprovalRoute]? = nil, reviewAfter: [ReviewAfterRule]? = nil,
         boxReadings: [String: BoxReadings]? = nil, botMessageMarks: [String: [String: String]]? = nil, automations: [String: ChatAutomation]? = nil,
         heartbeat: HeartbeatSettings? = nil) {
        self.bots = bots; self.groups = groups; self.modelDefaults = modelDefaults; self.approvalRoutes = approvalRoutes; self.reviewAfter = reviewAfter
        self.boxReadings = boxReadings; self.botMessageMarks = botMessageMarks; self.automations = automations; self.heartbeat = heartbeat
    }

    enum CodingKeys: CodingKey { case version, bots, groups, modelDefaults, approvalRoutes, reviewAfter, boxReadings, botMessageMarks, automations, heartbeat }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        bots = try c.decodeIfPresent([Bot].self, forKey: .bots) ?? []; groups = try c.decodeIfPresent([GroupChat].self, forKey: .groups) ?? []
        modelDefaults = (try? c.decodeIfPresent(ModelDefaults.self, forKey: .modelDefaults)) ?? nil
        approvalRoutes = (try? c.decodeIfPresent([ApprovalRoute].self, forKey: .approvalRoutes)) ?? nil
        reviewAfter = (try? c.decodeIfPresent([ReviewAfterRule].self, forKey: .reviewAfter)) ?? nil
        boxReadings = (try? c.decodeIfPresent([String: BoxReadings].self, forKey: .boxReadings)) ?? nil
        botMessageMarks = (try? c.decodeIfPresent([String: [String: String]].self, forKey: .botMessageMarks)) ?? nil
        automations = (try? c.decodeIfPresent([String: ChatAutomation].self, forKey: .automations)) ?? nil
        heartbeat = (try? c.decodeIfPresent(HeartbeatSettings.self, forKey: .heartbeat)) ?? nil
    }

    static func decode(_ data: Data) throws -> StoreFile {
        let first = data.first { ![0x20, 0x09, 0x0A, 0x0D].contains($0) }
        if first == UInt8(ascii: "[") { return StoreFile(bots: try JSONDecoder().decode([Bot].self, from: data), groups: []).with(version: 1) }
        return try JSONDecoder().decode(StoreFile.self, from: data)
    }
    private func with(version: Int) -> StoreFile { var copy = self; copy.version = version; return copy }
}
