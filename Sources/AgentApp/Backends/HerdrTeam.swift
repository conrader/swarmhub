import Foundation

extension HerdrClient {
    struct TeamMember: Encodable, Equatable {
        let id, name, agentName, template: String
        var model: String
        let instructions: String
        let projects: [Int]
        let main, takesMessages, takesInitiative, notifications: Bool
    }

    struct TeamPage: Decodable {
        struct Party: Decodable { let name: String }
        struct Exchange: Decodable, Identifiable {
            let id: Int
            let from, to: Party
            let kind, state, text: String
            var title: String { "\(from.name) → \(to.name) · \(kind.capitalized)" }
        }
        struct Entry: Decodable {
            let id: Int
            let bot, kind, text: String
            let atMs: Int64
            let unread, notify: Bool
            let journal: Int?
            let message: Exchange?
        }
        let items: [Entry]
        let more: Bool
    }

    struct TeamOK: Decodable {}
    func registerTeam(_ members: [TeamMember]) async throws {
        struct Registration: Encodable { let bots: [TeamMember] }
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let _: TeamOK = try await send(request("/api/bots", method: "POST", body: encoder.encode(Registration(bots: members))))
    }
}
