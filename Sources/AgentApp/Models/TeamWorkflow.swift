import Foundation

struct TeamSkill: Codable, Equatable {
    var name: String
    var instructions: String
}

struct TeamHandoff<Peer: Codable & Equatable>: Codable, Equatable {
    var recipient: Peer
    var condition: String
}

/// The saved group uses bot UUIDs. A pack uses member positions so it can travel between workspaces.
struct TeamWorkflow<Peer: Codable & Equatable>: Codable, Equatable {
    var skills: [TeamSkill] = []
    var handoffs: [TeamHandoff<Peer>] = []
    var isEmpty: Bool { skills.isEmpty && handoffs.isEmpty }

    func remapping<T>(_ target: (Peer) throws -> T) rethrows -> TeamWorkflow<T> {
        .init(skills: skills, handoffs: try handoffs.map { .init(recipient: try target($0.recipient), condition: $0.condition) })
    }

    func validate(owner: Peer, members: [Peer]) throws {
        guard skills.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                                  !$0.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw BackendError.unavailable("Give each skill a name and instructions.")
        }
        guard handoffs.allSatisfy({ $0.recipient != owner && members.contains($0.recipient) &&
                                   !$0.condition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw BackendError.unavailable("Each handoff needs another group member and a condition.")
        }
    }
}

extension GroupChat {
    func removeWorkflowMember(_ id: UUID) {
        memberIDs.removeAll { $0 == id }
        workflows.removeValue(forKey: id)
        for key in Array(workflows.keys) {
            workflows[key]?.handoffs.removeAll { $0.recipient == id }
            if workflows[key]?.isEmpty == true { workflows[key] = nil }
        }
    }

    func workflowPrefix(for bot: Bot, members: [Bot]) -> String {
        guard let workflow = workflows[bot.id] else { return "" }
        var entries = workflow.skills.map { "Skill · " + $0.name + "\n" + $0.instructions }
        for rule in workflow.handoffs where !bot.documentReadOnly {
            guard let peer = members.first(where: { $0.id == rule.recipient }) else { continue }
            entries.append("Handoff to " + peer.name + " when: " + rule.condition +
                           "\nWhen the condition is met, end your reply with one fenced block. Replace TASK with the work to send.\n" +
                           "```swarmhub\n{\"op\":\"group_handoff\",\"recipient\":\"" + peer.id.uuidString.lowercased() +
                           "\",\"task\":\"TASK\"}\n```")
        }
        guard !entries.isEmpty else { return "" }
        return "[Group workflow for " + bot.name + "]\n" + entries.joined(separator: "\n\n") + "\n[/Group workflow]\n\n"
    }
}

/// Move instructions to a file only when the workspace cannot fit them beside this turn.
struct TeamWorkflowDelivery {
    let text: String
    var file: HerdrClient.TaskFile?

    init(workflow: String, message: String, inlineLimit: Int, fileLimit: Int, occupiedNames: Set<String>) throws {
        if workflow.isEmpty || (workflow + message).utf8.count <= inlineLimit {
            try HerdrClient.validateMessage(message, limit: inlineLimit)
            text = workflow + message
            return
        }
        var name = "team-workflow.txt"
        var suffix = 1
        while occupiedNames.contains(name) {
            suffix += 1
            name = "team-workflow-\(suffix).txt"
        }
        let note = "Read the group instructions in " + name + " before answering."
        let withMessage = note + "\n\n" + message
        let includeMessage = withMessage.utf8.count > fileLimit
        text = includeMessage ? "Read the group instructions and current task in " + name + "." : withMessage
        try HerdrClient.validateMessage(text, limit: fileLimit)
        let contents = includeMessage ? workflow + "\nCurrent task:\n" + message : workflow
        let file = HerdrClient.TaskFile(name: name, mime: "text/plain", data: Data(contents.utf8), isWorkflow: true)
        try HerdrClient.TaskFile.validate([file])
        self.file = file
    }
}

extension HerdrClient {
    struct WorkspaceSkill: Decodable, Identifiable {
        let id: Int
        let name: String
        let archived: Bool
        let instructions: String?
    }
    func workspaceSkills() async throws -> [WorkspaceSkill] { try await get("/api/skills") }
    func workspaceSkill(_ id: Int) async throws -> WorkspaceSkill { try await get("/api/skills/\(id)") }
}
