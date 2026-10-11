import Combine
import Foundation

enum BackendKind: String, Codable, CaseIterable, Identifiable { case mock = "Mock", hermes = "Hermes Agent", openClaw = "OpenClaw"; var id: String { rawValue } }
enum MessageRole: String, Codable { case user, assistant, system }

final class ChatMessage: ObservableObject, Identifiable, Codable {
    let id: UUID; let role: MessageRole; @Published var content: String; let createdAt: Date; @Published var isStreaming: Bool
    init(role: MessageRole, content: String, isStreaming: Bool = false) { id = UUID(); self.role = role; self.content = content; createdAt = .now; self.isStreaming = isStreaming }
    enum CodingKeys: CodingKey { case id, role, content, createdAt }
    required init(from decoder: Decoder) throws { let c = try decoder.container(keyedBy: CodingKeys.self); id = try c.decode(UUID.self, forKey: .id); role = try c.decode(MessageRole.self, forKey: .role); content = try c.decode(String.self, forKey: .content); createdAt = try c.decode(Date.self, forKey: .createdAt); isStreaming = false }
    func encode(to encoder: Encoder) throws { var c = encoder.container(keyedBy: CodingKeys.self); try c.encode(id, forKey: .id); try c.encode(role, forKey: .role); try c.encode(content, forKey: .content); try c.encode(createdAt, forKey: .createdAt) }
}

final class Bot: ObservableObject, Identifiable, Codable, Hashable {
    let id: UUID; @Published var name: String; @Published var persona: String; @Published var backend: BackendKind; @Published var unreadCount: Int; let createdAt: Date; @Published var messages: [ChatMessage]
    init(name: String, persona: String = "You are a thoughtful, capable assistant.", backend: BackendKind = .mock) { id = UUID(); self.name = name; self.persona = persona; self.backend = backend; unreadCount = 0; createdAt = .now; messages = [] }
    var initial: String { String(name.trimmingCharacters(in: .whitespaces).first ?? "A").uppercased() }
    static func == (lhs: Bot, rhs: Bot) -> Bool { lhs.id == rhs.id }; func hash(into hasher: inout Hasher) { hasher.combine(id) }
    enum CodingKeys: CodingKey { case id, name, persona, backend, unreadCount, createdAt, messages }
    required init(from decoder: Decoder) throws { let c = try decoder.container(keyedBy: CodingKeys.self); id = try c.decode(UUID.self, forKey: .id); name = try c.decode(String.self, forKey: .name); persona = try c.decode(String.self, forKey: .persona); backend = try c.decode(BackendKind.self, forKey: .backend); unreadCount = try c.decode(Int.self, forKey: .unreadCount); createdAt = try c.decode(Date.self, forKey: .createdAt); messages = try c.decode([ChatMessage].self, forKey: .messages) }
    func encode(to encoder: Encoder) throws { var c = encoder.container(keyedBy: CodingKeys.self); try c.encode(id, forKey: .id); try c.encode(name, forKey: .name); try c.encode(persona, forKey: .persona); try c.encode(backend, forKey: .backend); try c.encode(unreadCount, forKey: .unreadCount); try c.encode(createdAt, forKey: .createdAt); try c.encode(messages, forKey: .messages) }
}

enum SubAgentStatus: String, Codable { case queued, running, completed, failed }
struct SubAgentTask: Identifiable, Codable, Sendable { let id: UUID; var title: String; var detail: String; var status: SubAgentStatus }
struct ApprovalRequest: Identifiable, Codable, Sendable { let id: UUID; let title: String; let summary: String; let draft: String? }
struct BackendSession: Identifiable, Sendable { let id: String; let title: String }
enum AgentEvent: Sendable { case token(String), status(String), subAgent(SubAgentTask), approval(ApprovalRequest), completed, failed(String) }
