import Combine
import Foundation

enum BackendKind: String, Codable, CaseIterable, Identifiable {
    case mock = "Mock", hermes = "Hermes Agent", openClaw = "OpenClaw"
    var id: String { rawValue }
}

enum MessageRole: String, Codable { case user, assistant, system }
enum MessagePresentation: String, Codable { case text, draftEmail, options, attachment }

final class ChatMessage: ObservableObject, Identifiable, Codable {
    let id: UUID; let role: MessageRole; @Published var content: String; let createdAt: Date
    @Published var isStreaming: Bool; var presentation: MessagePresentation; var metadata: [String: String]
    @Published var reactions: [String]
    init(role: MessageRole, content: String, isStreaming: Bool = false, presentation: MessagePresentation = .text, metadata: [String: String] = [:], reactions: [String] = []) {
        id = UUID(); self.role = role; self.content = content; createdAt = .now; self.isStreaming = isStreaming
        self.presentation = presentation; self.metadata = metadata; self.reactions = reactions
    }
    enum CodingKeys: CodingKey { case id, role, content, createdAt, presentation, metadata, reactions }
    required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); role = try c.decode(MessageRole.self, forKey: .role)
        content = try c.decode(String.self, forKey: .content); createdAt = try c.decode(Date.self, forKey: .createdAt)
        presentation = try c.decodeIfPresent(MessagePresentation.self, forKey: .presentation) ?? .text
        metadata = try c.decodeIfPresent([String: String].self, forKey: .metadata) ?? [:]
        reactions = try c.decodeIfPresent([String].self, forKey: .reactions) ?? []; isStreaming = false
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self); try c.encode(id, forKey: .id); try c.encode(role, forKey: .role)
        try c.encode(content, forKey: .content); try c.encode(createdAt, forKey: .createdAt); try c.encode(presentation, forKey: .presentation)
        try c.encode(metadata, forKey: .metadata); try c.encode(reactions, forKey: .reactions)
    }
}

struct Routine: Identifiable, Codable, Hashable {
    let id: UUID; var name: String; var schedule: String; var isEnabled: Bool
    init(name: String, schedule: String, isEnabled: Bool = true) { id = UUID(); self.name = name; self.schedule = schedule; self.isEnabled = isEnabled }
}

final class Bot: ObservableObject, Identifiable, Codable, Hashable {
    let id: UUID; @Published var name: String; @Published var title: String; @Published var botDescription: String
    @Published var persona: String; @Published var backend: BackendKind; @Published var unreadCount: Int
    @Published var notificationsEnabled: Bool; let createdAt: Date; @Published var messages: [ChatMessage]; @Published var routines: [Routine]
    init(name: String, title: String = "Personal agent", description: String = "", persona: String = "You are a thoughtful, capable assistant.", backend: BackendKind = .mock, unreadCount: Int = 0, messages: [ChatMessage] = [], routines: [Routine] = []) {
        id = UUID(); self.name = name; self.title = title; botDescription = description; self.persona = persona; self.backend = backend
        self.unreadCount = unreadCount; notificationsEnabled = true; createdAt = .now; self.messages = messages; self.routines = routines
    }
    var initial: String { String(name.trimmingCharacters(in: .whitespaces).first ?? "A").uppercased() }
    var lastMessageSnippet: String { messages.last?.content.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines) ?? "Start a conversation" }
    static func == (lhs: Bot, rhs: Bot) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    enum CodingKeys: CodingKey { case id, name, title, botDescription, persona, backend, unreadCount, notificationsEnabled, createdAt, messages, routines }
    required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self); id = try c.decode(UUID.self, forKey: .id); name = try c.decode(String.self, forKey: .name)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Personal agent"; botDescription = try c.decodeIfPresent(String.self, forKey: .botDescription) ?? ""
        persona = try c.decode(String.self, forKey: .persona); backend = try c.decode(BackendKind.self, forKey: .backend); unreadCount = try c.decode(Int.self, forKey: .unreadCount)
        notificationsEnabled = try c.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? true; createdAt = try c.decode(Date.self, forKey: .createdAt)
        messages = try c.decode([ChatMessage].self, forKey: .messages); routines = try c.decodeIfPresent([Routine].self, forKey: .routines) ?? []
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self); try c.encode(id, forKey: .id); try c.encode(name, forKey: .name); try c.encode(title, forKey: .title)
        try c.encode(botDescription, forKey: .botDescription); try c.encode(persona, forKey: .persona); try c.encode(backend, forKey: .backend)
        try c.encode(unreadCount, forKey: .unreadCount); try c.encode(notificationsEnabled, forKey: .notificationsEnabled); try c.encode(createdAt, forKey: .createdAt)
        try c.encode(messages, forKey: .messages); try c.encode(routines, forKey: .routines)
    }
}

enum SubAgentStatus: String, Codable { case queued, running, completed, failed }
struct SubAgentTask: Identifiable, Codable, Sendable { let id: UUID; var title: String; var detail: String; var status: SubAgentStatus }
struct ApprovalRequest: Identifiable, Codable, Sendable { let id: UUID; let title: String; let summary: String; let draft: String? }
struct BackendSession: Identifiable, Sendable { let id: String; let title: String }
enum AgentEvent: Sendable { case token(String), status(String), subAgent(SubAgentTask), approval(ApprovalRequest), completed, failed(String) }
