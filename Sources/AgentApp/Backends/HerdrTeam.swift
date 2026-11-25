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
            var code: String? = nil
            let journal: Int?
            let message: Exchange?
        }
        let items: [Entry]
        let more: Bool
    }

    struct TeamOK: Decodable {}

    struct TeamRegistrationBatch {
        let body: Data
        let ids: [String]
    }

    /// Measure and send the same bytes, including JSON escapes, delimiters and the outer object.
    static func teamRegistrationBatches(_ members: [TeamMember]) throws -> [TeamRegistrationBatch] {
        let limit = 128 * 1024
        let prefix = Data(#"{"bots":["#.utf8)
        let suffix = Data("]}".utf8)
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        var batches: [TeamRegistrationBatch] = []
        var body = prefix
        var ids: [String] = []
        // Promotion clears the old main in the same bridge transaction. A later failed
        // batch must never leave the server with an interim, main-less directory.
        for member in members.filter(\.main) + members.filter({ !$0.main }) {
            let encoded = try encoder.encode(member)
            guard prefix.count + encoded.count + suffix.count <= limit else {
                throw BackendError.unavailable("Team registration for \(member.name) exceeds the 128 KiB limit for POST /api/bots.")
            }
            if ids.count == 200 || body.count + (ids.isEmpty ? 0 : 1) + encoded.count + suffix.count > limit {
                body.append(suffix)
                batches.append(.init(body: body, ids: ids))
                body = prefix
                ids = []
            }
            if !ids.isEmpty { body.append(0x2C) } // comma
            body.append(encoded)
            ids.append(member.id)
        }
        if !ids.isEmpty {
            body.append(suffix)
            batches.append(.init(body: body, ids: ids))
        }
        return batches
    }

    func registerTeam(_ batch: TeamRegistrationBatch) async throws {
        do {
            let _: TeamOK = try await send(request("/api/bots", method: "POST", body: batch.body))
        } catch Failure.http(let status, let reason) {
            throw Failure.http(status, "Team registration (POST /api/bots, \(batch.body.count) bytes) failed. \(reason)")
        }
    }
}
