import Combine
import Foundation

enum BackendKind: String, Codable, CaseIterable, Identifiable {
    case mock = "Mock", hermes = "Hermes Agent", openClaw = "OpenClaw"
    var id: String { rawValue }
}

enum MessageRole: String, Codable { case user, assistant, system }
enum MessagePresentation: String, Codable { case text, draftEmail, options, attachment, image, links, voiceMemo, delegation }

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
    @Published var isStreaming: Bool; var presentation: MessagePresentation; var metadata: [String: String]
    @Published var reactions: [String]; var replyToID: UUID?
    init(id: UUID = UUID(), role: MessageRole, content: String, createdAt: Date = .now, isStreaming: Bool = false, presentation: MessagePresentation = .text, metadata: [String: String] = [:], reactions: [String] = [], replyToID: UUID? = nil) {
        self.id = id; self.role = role; self.content = content; self.createdAt = createdAt; self.isStreaming = isStreaming
        self.presentation = presentation; self.metadata = metadata; self.reactions = reactions; self.replyToID = replyToID
    }
    enum CodingKeys: CodingKey { case id, role, content, createdAt, presentation, metadata, reactions, replyToID }
    required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); role = try c.decode(MessageRole.self, forKey: .role)
        content = try c.decode(String.self, forKey: .content); createdAt = try c.decode(Date.self, forKey: .createdAt)
        presentation = try c.decodeIfPresent(MessagePresentation.self, forKey: .presentation) ?? .text
        metadata = try c.decodeIfPresent([String: String].self, forKey: .metadata) ?? [:]
        reactions = try c.decodeIfPresent([String].self, forKey: .reactions) ?? []
        replyToID = try c.decodeIfPresent(UUID.self, forKey: .replyToID)
        isStreaming = false
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self); try c.encode(id, forKey: .id); try c.encode(role, forKey: .role)
        try c.encode(content, forKey: .content); try c.encode(createdAt, forKey: .createdAt); try c.encode(presentation, forKey: .presentation)
        try c.encode(metadata, forKey: .metadata)
        try c.encode(reactions, forKey: .reactions); try c.encodeIfPresent(replyToID, forKey: .replyToID)
    }
}

final class Bot: ObservableObject, Identifiable, Codable, Hashable {
    let id: UUID; @Published var name: String; @Published var title: String; @Published var botDescription: String
    @Published var persona: String; @Published var backend: BackendKind; @Published var unreadCount: Int
    @Published var avatarName: BotAvatarName
    @Published var isHidden: Bool; @Published var notificationsEnabled: Bool
    @Published var memorySummary: String; @Published var skills: [String]
    @Published var hermesProfile: String?; @Published var hermesSessionID: String?
    @Published var isDemo: Bool
    let createdAt: Date; @Published var messages: [ChatMessage]
    init(name: String, title: String = "Personal agent", description: String = "", persona: String = "You are a thoughtful, capable assistant.", backend: BackendKind = .mock, avatarName: BotAvatarName = .faceCoral, unreadCount: Int = 0, isHidden: Bool = false, notificationsEnabled: Bool = true, memorySummary: String = "", skills: [String] = [], messages: [ChatMessage] = [], hermesProfile: String? = nil, hermesSessionID: String? = nil, isDemo: Bool = false) {
        id = UUID(); self.name = name; self.title = title; botDescription = description; self.persona = persona; self.backend = backend
        self.avatarName = avatarName; self.unreadCount = unreadCount; self.isHidden = isHidden; self.notificationsEnabled = notificationsEnabled
        self.memorySummary = memorySummary; self.skills = skills; self.hermesProfile = hermesProfile; self.hermesSessionID = hermesSessionID; self.isDemo = isDemo; createdAt = .now; self.messages = messages
    }
    static func == (lhs: Bot, rhs: Bot) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    enum CodingKeys: CodingKey { case id, name, title, botDescription, persona, backend, avatarName, unreadCount, isHidden, notificationsEnabled, memorySummary, skills, hermesProfile, hermesSessionID, isDemo, createdAt, messages }
    required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self); id = try c.decode(UUID.self, forKey: .id); let decodedName = try c.decode(String.self, forKey: .name); name = decodedName
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Personal agent"; botDescription = try c.decodeIfPresent(String.self, forKey: .botDescription) ?? ""
        persona = try c.decode(String.self, forKey: .persona); let decodedBackend = try c.decode(BackendKind.self, forKey: .backend); backend = decodedBackend
        let legacyAvatar: BotAvatarName = ["Atlas": .robot, "Mira": .blob, "Patch": .headphones, "Scout": .fox, "Nova": .planet][decodedName] ?? .robot
        avatarName = try c.decodeIfPresent(BotAvatarName.self, forKey: .avatarName) ?? legacyAvatar; unreadCount = try c.decode(Int.self, forKey: .unreadCount)
        isHidden = try c.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false; notificationsEnabled = try c.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? true
        memorySummary = try c.decodeIfPresent(String.self, forKey: .memorySummary) ?? ""; skills = try c.decodeIfPresent([String].self, forKey: .skills) ?? []
        hermesProfile = try c.decodeIfPresent(String.self, forKey: .hermesProfile); hermesSessionID = try c.decodeIfPresent(String.self, forKey: .hermesSessionID)
        isDemo = try c.decodeIfPresent(Bool.self, forKey: .isDemo) ?? Bot.looksLikeLegacyDemo(name: decodedName, backend: decodedBackend)
        createdAt = try c.decode(Date.self, forKey: .createdAt); messages = try c.decode([ChatMessage].self, forKey: .messages)
    }
    private static func looksLikeLegacyDemo(name: String, backend: BackendKind) -> Bool {
        backend == .mock && ["Atlas", "Mira", "Patch", "Scout", "Nova"].contains(name)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self); try c.encode(id, forKey: .id); try c.encode(name, forKey: .name); try c.encode(title, forKey: .title)
        try c.encode(botDescription, forKey: .botDescription); try c.encode(persona, forKey: .persona); try c.encode(backend, forKey: .backend); try c.encode(avatarName, forKey: .avatarName)
        try c.encode(unreadCount, forKey: .unreadCount); try c.encode(createdAt, forKey: .createdAt); try c.encode(messages, forKey: .messages)
        try c.encode(isHidden, forKey: .isHidden); try c.encode(notificationsEnabled, forKey: .notificationsEnabled); try c.encode(memorySummary, forKey: .memorySummary); try c.encode(skills, forKey: .skills)
        try c.encodeIfPresent(hermesProfile, forKey: .hermesProfile); try c.encodeIfPresent(hermesSessionID, forKey: .hermesSessionID); try c.encode(isDemo, forKey: .isDemo)
    }
}

struct BotRoutine: Identifiable, Codable {
    let id: UUID; var name: String; var schedule: String; var lastRun: String; var isEnabled: Bool
    init(id: UUID = UUID(), name: String, schedule: String, lastRun: String = "Never", isEnabled: Bool = true) { self.id = id; self.name = name; self.schedule = schedule; self.lastRun = lastRun; self.isEnabled = isEnabled }
}

enum SubAgentStatus: String, Codable { case queued, running, completed, failed }
struct SubAgentTask: Identifiable, Codable, Sendable { let id: UUID; var title: String; var detail: String; var status: SubAgentStatus }
struct ApprovalRequest: Identifiable, Codable, Sendable {
    let id: UUID; let title: String; let summary: String; let draft: String?
    var runID: String? = nil; var requestID: String? = nil
    var botID: UUID? = nil; var profile: String? = nil; var sessionID: String? = nil
}
struct BackendSession: Identifiable, Sendable { let id: String; let title: String }
struct BackendMessage: Sendable, Equatable {
    let id: String?; let role: String; let content: String; let createdAt: Date?
    init(id: String? = nil, role: String, content: String, createdAt: Date? = nil) {
        self.id = id; self.role = role; self.content = content; self.createdAt = createdAt
    }
}
enum StopTarget: Sendable, Equatable { case serverRun(String), disconnectedLegacy, noActiveRun }
enum StopOutcome: Sendable, Equatable { case requested, disconnectedLegacy, noActiveRun }
enum AgentEvent: Sendable { case token(String), status(String), subAgent(SubAgentTask), approval(ApprovalRequest), completed, failed(String) }
