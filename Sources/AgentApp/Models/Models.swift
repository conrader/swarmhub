import Combine
import Foundation

/// What runs a bot's agent. Every real bot is a Herdr agent; `mock` answers locally for the sample agents and tests.
/// A store written by an older build may name a backend that no longer exists: `StoreFile` leaves those bots out
/// (`LegacyStore`), so this type never sees them.
enum BackendKind: String, Codable, CaseIterable, Identifiable {
    case mock = "Mock", herdr = "Herdr"
    var id: String { rawValue }
    var shortName: String { rawValue }
}

enum MessageRole: String, Codable { case user, assistant, system }
/// How a message is drawn. A stored message that names a presentation this build no longer has (the cards of older
/// builds) reads as text.
enum MessagePresentation: String, Codable {
    case text
    init(from decoder: Decoder) throws { self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .text }
}

enum BotAvatarName: String, Codable, CaseIterable, Identifiable {
    case faceCoral, faceSky, faceMint, faceSun, faceLilac, faceRose
    case faceOcean, faceLime, facePeach, faceBlue, facePlum, faceSand
    case robot, blob, bubble, headphones, fox, planet, coffee, octopus, pebble
    var id: String { rawValue }
    var isFlatFace: Bool { rawValue.hasPrefix("face") }
    var displayName: String {
        switch self {
        case .faceCoral: "Coral"; case .faceSky: "Sky"; case .faceMint: "Mint"; case .faceSun: "Sun"
        case .faceLilac: "Lilac"; case .faceRose: "Rose"; case .faceOcean: "Ocean"; case .faceLime: "Lime"
        case .facePeach: "Peach"; case .faceBlue: "Blue"; case .facePlum: "Plum"; case .faceSand: "Sand"
        default: rawValue.capitalized
        }
    }
}

final class ChatMessage: ObservableObject, Identifiable, Codable {
    let id: UUID; let role: MessageRole; @Published var content: String; let createdAt: Date
    @Published var isStreaming: Bool; var presentation: MessagePresentation; @Published var metadata: [String: String]
    @Published var reactions: [String]; var replyToID: UUID?; var attachments: [ChatAttachment]
    /// Group chats: the bot that wrote an assistant message (nil = the user, or a one-bot chat).
    var authorID: UUID?
    /// P16: the state of the turn whose reply this row holds (nil = written before P16); encoded only when set.
    @Published var turnState: TurnState?
    /// P27: the tools this reply ran (bounded); encoded only when set. `lastTextAt` (memory only): when text last arrived.
    @Published var activity: ToolActivity?; @Published var lastTextAt: Date?
    init(id: UUID = UUID(), role: MessageRole, content: String, createdAt: Date = .now, isStreaming: Bool = false, presentation: MessagePresentation = .text, metadata: [String: String] = [:], reactions: [String] = [], replyToID: UUID? = nil, attachments: [ChatAttachment] = [], authorID: UUID? = nil, turnState: TurnState? = nil) {
        self.id = id; self.role = role; self.content = content; self.createdAt = createdAt; self.isStreaming = isStreaming
        self.presentation = presentation; self.metadata = metadata; self.reactions = reactions; self.replyToID = replyToID; self.attachments = attachments; self.authorID = authorID
        self.turnState = turnState
    }
    enum CodingKeys: CodingKey { case id, role, content, createdAt, presentation, metadata, reactions, replyToID, attachments, authorID, turnState, activity }
    required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); role = try c.decode(MessageRole.self, forKey: .role)
        content = try c.decode(String.self, forKey: .content); createdAt = try c.decode(Date.self, forKey: .createdAt)
        presentation = try c.decodeIfPresent(MessagePresentation.self, forKey: .presentation) ?? .text
        metadata = try c.decodeIfPresent([String: String].self, forKey: .metadata) ?? [:]
        reactions = try c.decodeIfPresent([String].self, forKey: .reactions) ?? []
        replyToID = try c.decodeIfPresent(UUID.self, forKey: .replyToID)
        attachments = try c.decodeIfPresent([ChatAttachment].self, forKey: .attachments) ?? []
        authorID = try c.decodeIfPresent(UUID.self, forKey: .authorID)
        // An unknown value (a newer build's state) must not make the whole store undecodable.
        turnState = (try? c.decodeIfPresent(TurnState.self, forKey: .turnState)) ?? nil
        activity = (try? c.decodeIfPresent(ToolActivity.self, forKey: .activity)) ?? nil
        isStreaming = false
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self); try c.encode(id, forKey: .id); try c.encode(role, forKey: .role)
        try c.encode(content, forKey: .content); try c.encode(createdAt, forKey: .createdAt); try c.encode(presentation, forKey: .presentation)
        try c.encode(metadata, forKey: .metadata)
        try c.encode(reactions, forKey: .reactions); try c.encodeIfPresent(replyToID, forKey: .replyToID)
        if !attachments.isEmpty { try c.encode(attachments, forKey: .attachments) }
        try c.encodeIfPresent(authorID, forKey: .authorID); try c.encodeIfPresent(turnState, forKey: .turnState)
        try c.encodeIfPresent(activity, forKey: .activity)
    }
}

final class Bot: ObservableObject, Identifiable, Codable, Hashable {
    let id: UUID; @Published var name: String; @Published var title: String; @Published var botDescription: String
    @Published var persona: String; @Published var backend: BackendKind; @Published var unreadCount: Int
    @Published var avatarName: BotAvatarName
    /// P15: Grok's shape/colour words (nil = the classic `avatarName`); additive, so a rollback still opens the store.
    @Published var avatarMark: AvatarMark? = nil
    /// Transient: the mark was recovered by `AvatarMigration` at decode and is not saved yet.
    var avatarMarkMigrated = false
    @Published var isHidden: Bool; @Published var notificationsEnabled: Bool
    /// The session a backend that keeps sessions answers in; a Herdr agent keeps its own conversation, so it stays nil.
    @Published var sessionID: String?
    @Published var isDemo: Bool
    /// This bot is the main bot of its Herdr server: the one that creates bots there (`AppStore+HerdrBots.swift`).
    @Published var canManageBots = false
    /// The sidebar's manual "Mark as Unread" flag.
    @Published var manualUnread: Bool
    /// Grok import: accent colour (hex), source id, archive size, and — for an archived read-only group
    /// conversation — its member names.
    @Published var accentColor: String?; @Published var grokSourceID: String?
    @Published var grokHistoryCount: Int; @Published var archivedMembers: [String]?
    var isReadOnlyArchive: Bool { archivedMembers != nil }
    let createdAt: Date; @Published var messages: [ChatMessage]
    init(name: String, title: String = "", description: String = "", persona: String = Bot.defaultPersona, backend: BackendKind = .mock, avatarName: BotAvatarName? = nil, unreadCount: Int = 0, isHidden: Bool = false, notificationsEnabled: Bool = true, messages: [ChatMessage] = [], sessionID: String? = nil, isDemo: Bool = false) {
        id = UUID(); self.name = name; self.title = title; botDescription = description; self.persona = persona; self.backend = backend
        self.avatarName = avatarName ?? .faceCoral; self.unreadCount = unreadCount; self.isHidden = isHidden; self.notificationsEnabled = notificationsEnabled
        self.sessionID = sessionID; self.isDemo = isDemo; accentColor = nil; grokSourceID = nil; grokHistoryCount = 0; archivedMembers = nil
        manualUnread = false; createdAt = .now; self.messages = messages
        // No explicit classic choice: the bot gets its derived mark (avatarName keeps the legacy default for older builds).
        avatarMark = avatarName == nil ? GrokDefaultLook.mark(for: id.uuidString.lowercased()) : nil
    }
    static let defaultPersona = "You are a thoughtful, capable assistant."
    /// What older versions put under a new bot's name; it says nothing, so it is not shown.
    static let placeholderTitle = "Personal agent"
    /// The persona as it leaves for the agent. An imported bot's persona came from Grok Bot data and may predate the
    /// current filter, so it goes through `SecretFilter` once more; a persona typed here is sent as written (a
    /// deliberate `token: …` line in it stays).
    var outboundPersona: String { grokSourceID == nil ? persona : SecretFilter.redacted(persona, replacement: GrokRedactor.marker) }
    static func ==(lhs: Bot, rhs: Bot) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    /// `hermesSessionID` is the name `sessionID` was saved under before; it is read, never written.
    enum CodingKeys: CodingKey { case id, name, title, botDescription, persona, backend, avatarName, unreadCount, isHidden, notificationsEnabled, sessionID, hermesSessionID, isDemo, accentColor, grokSourceID, grokHistoryCount, archivedMembers, manualUnread, createdAt, messages, avatarMark, canManageBots }
    required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self); id = try c.decode(UUID.self, forKey: .id); let decodedName = try c.decode(String.self, forKey: .name); name = decodedName
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Personal agent"; botDescription = try c.decodeIfPresent(String.self, forKey: .botDescription) ?? ""
        persona = try c.decode(String.self, forKey: .persona); let decodedBackend = try c.decode(BackendKind.self, forKey: .backend); backend = decodedBackend
        let legacyAvatar: BotAvatarName = ["Atlas": .robot, "Mira": .blob, "Patch": .headphones, "Scout": .fox, "Nova": .planet][decodedName] ?? .robot
        avatarName = try c.decodeIfPresent(BotAvatarName.self, forKey: .avatarName) ?? legacyAvatar; unreadCount = try c.decodeIfPresent(Int.self, forKey: .unreadCount) ?? 0
        isHidden = try c.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false; notificationsEnabled = try c.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? true
        sessionID = try c.decodeIfPresent(String.self, forKey: .sessionID) ?? c.decodeIfPresent(String.self, forKey: .hermesSessionID)
        isDemo = try c.decodeIfPresent(Bool.self, forKey: .isDemo) ?? Bot.looksLikeLegacyDemo(name: decodedName, backend: decodedBackend)
        accentColor = try c.decodeIfPresent(String.self, forKey: .accentColor)
        grokSourceID = try c.decodeIfPresent(String.self, forKey: .grokSourceID); grokHistoryCount = try c.decodeIfPresent(Int.self, forKey: .grokHistoryCount) ?? 0
        archivedMembers = try c.decodeIfPresent([String].self, forKey: .archivedMembers)
        manualUnread = try c.decodeIfPresent(Bool.self, forKey: .manualUnread) ?? false
        canManageBots = try c.decodeIfPresent(Bool.self, forKey: .canManageBots) ?? false
        createdAt = try c.decode(Date.self, forKey: .createdAt); messages = try c.decode([ChatMessage].self, forKey: .messages)
        // A malformed mark must not cost the store; a missing one may be recovered from what the P6 importer wrote.
        avatarMark = (try? c.decodeIfPresent(AvatarMark.self, forKey: .avatarMark)) ?? nil
        if avatarMark == nil, let migrated = AvatarMigration.mark(avatarName: avatarName, accentColor: accentColor, grokSourceID: grokSourceID) {
            avatarMark = migrated; avatarMarkMigrated = true
        }
    }
    private static func looksLikeLegacyDemo(name: String, backend: BackendKind) -> Bool {
        backend == .mock && ["Atlas", "Mira", "Patch", "Scout", "Nova"].contains(name)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self); try c.encode(id, forKey: .id); try c.encode(name, forKey: .name); try c.encode(title, forKey: .title)
        try c.encode(botDescription, forKey: .botDescription); try c.encode(persona, forKey: .persona); try c.encode(backend, forKey: .backend); try c.encode(avatarName, forKey: .avatarName)
        try c.encode(unreadCount, forKey: .unreadCount); try c.encode(createdAt, forKey: .createdAt); try c.encode(messages, forKey: .messages)
        try c.encode(isHidden, forKey: .isHidden); try c.encode(notificationsEnabled, forKey: .notificationsEnabled)
        try c.encodeIfPresent(sessionID, forKey: .sessionID); try c.encode(isDemo, forKey: .isDemo)
        try c.encodeIfPresent(accentColor, forKey: .accentColor); try c.encodeIfPresent(grokSourceID, forKey: .grokSourceID)
        try c.encode(grokHistoryCount, forKey: .grokHistoryCount); try c.encodeIfPresent(archivedMembers, forKey: .archivedMembers)
        try c.encode(manualUnread, forKey: .manualUnread)
        try c.encodeIfPresent(avatarMark, forKey: .avatarMark)
        if canManageBots { try c.encode(true, forKey: .canManageBots) }
    }
}

enum StopTarget: Sendable, Equatable { case serverRun(String), noRunControl, noActiveRun }
enum StopOutcome: Sendable, Equatable { case requested, noRunControl, noActiveRun }
/// What a backend's stream says about a turn. `replace`: the whole reply text so far, when a snapshot no longer
/// extends what was streamed. `tool`: a tool started, progressed or finished; the reply keeps these as its activity steps.
enum AgentEvent: Sendable { case token(String), replace(String), status(String), tool(ToolEvent), completed, failed(String) }
