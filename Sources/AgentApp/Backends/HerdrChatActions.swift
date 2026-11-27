import Foundation

struct HerdrReplyResults: Codable, Sendable, Equatable {
    let serverID: String
    var items: [HerdrPublishedResult]
}

/// The journal row identifies the card. Pages also carry a separate document ID.
struct HerdrPublishedResult: Identifiable, Codable, Sendable, Equatable {
    enum Kind: String, Codable { case file, page }
    let id: Int
    let kind: Kind
    let title: String
    let pageID: Int?
    let revision: Int?

    var excerpt: String?

    init(page: HerdrClient.RoutinePage, journalID: Int) {
        id = journalID
        kind = .page
        title = page.title
        pageID = page.id
        revision = page.revision
        excerpt = page.excerpt
    }

    init?(_ row: HerdrClient.Item) {
        guard row.id > 0 else { return nil }
        switch row.kind {
        case "artifact": kind = .file
        case "page" where (row.pageId ?? 0) > 0: kind = .page
        default: return nil
        }
        id = row.id
        title = row.detail.flatMap { $0.isEmpty ? nil : $0 } ?? (kind == .file ? "Published file" : "Published Page")
        pageID = row.pageId
        revision = row.pageRevision
    }
}

struct WorkspacePageLink: Hashable, Identifiable, Sendable {
    let serverID: String
    let pageID: Int
    let revision: Int?
    let title: String

    var id: String { "page-\(serverID)-\(pageID)-\(revision.map(String.init) ?? "latest")" }
}

extension HerdrClient {
    struct Approval: Decodable, Identifiable, Equatable, Sendable {
        let id: Int
        var launchModel: String? = nil
        let agent, provider, tool, cwd, arguments: String
        let core, address: String?
        let createdMs: UInt64?
        struct Reviewer: Decodable, Equatable, Sendable {
            let model: String
            let assessment: String?
            var botId: String? = nil
            var botName: String? = nil
            var problem: String? = nil

            var title: String {
                if let botName { return Approval.visible(botName) + " · Claude review" }
                if botId != nil { return "Selected bot review" }
                return "Claude " + model.capitalized + " review"
            }
        }
        var reviewer: Reviewer? = nil
        var canRememberCommand: Bool? = nil
        var canRememberCommandHour: Bool? = nil

        var commandPreview: String? {
            guard tool == "Bash", let object = try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any],
                  let command = object["command"] as? String, !command.isEmpty else { return nil }
            return Self.visible(command)
        }

        var inboxArguments: String {
            if tool == "Bash", let object = try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: String],
               object.count == 1, let command = object["command"], !command.isEmpty {
                return Self.visible(command)
            }
            return Self.visible(arguments)
        }

        static func visible(_ value: String) -> String {
            value.unicodeScalars.map { scalar in
                switch scalar.properties.generalCategory {
                case .format, .lineSeparator, .paragraphSeparator: return String(format: "\\u{%04X}", scalar.value)
                case .control where scalar != "\n" && scalar != "\t": return String(format: "\\u{%04X}", scalar.value)
                default: return String(scalar)
                }
            }.joined()
        }
    }

    func pendingApprovals() async throws -> [Approval] {
        struct Inbox: Decodable { let pending: [Approval] }
        let inbox: Inbox = try await get("/api/approvals?pending_only=true")
        return inbox.pending
    }

    func approvals(for name: String) async throws -> [Approval] {
        try await approvals(for: Set([name]))[name] ?? []
    }

    func approvals(for names: Set<String>) async throws -> [String: [Approval]] {
        let pending = try await pendingApprovals()
        guard !pending.isEmpty else { return [:] }
        let current = try await workspace()
        var matches: [String: [Approval]] = [:]
        for name in names {
            guard let agent = liveAgent(named: name, in: current) else { continue }
            let rows = pending.filter {
                $0.agent == agent.name && $0.core == current.core && $0.address == agent.address && $0.createdMs == agent.createdMs
            }
            if !rows.isEmpty { matches[name] = rows }
        }
        return matches
    }

    struct CommandRule: Decodable, Identifiable, Sendable {
        let id: Int
        let bot, agent, provider, cwd, command: String
        var expiresMs: Int64? = nil
    }
    func commandRules(for botID: UUID) async throws -> [CommandRule] {
        let rules: [CommandRule] = try await get("/api/project-command-rules")
        return rules.filter { UUID(uuidString: $0.bot) == botID }
    }
    func revokeCommandRule(_ id: Int) async throws {
        struct Result: Decodable { let revoked: Bool }
        let _: Result = try await send(request("/api/project-command-rules/\(id)/revoke", method: "POST", body: Data("{}".utf8)))
    }

    enum Decision: String { case approve, deny, rememberCommand = "remember_command", rememberCommandHour = "remember_command_hour" }
    func decide(_ approval: Approval, _ decision: Decision) async throws {
        struct Accepted: Decodable { let id: Int }
        let _: Accepted = try await send(request("/api/approvals/\(approval.id)", method: "POST", body: try JSONEncoder().encode(decision.rawValue)))
    }

    struct PageSummary: Decodable, Identifiable, Sendable {
        let id: Int
        let title: String
        let pinned: Bool?
    }

    func workspacePages(matching term: String) async throws -> [PageSummary] {
        guard !term.isEmpty else { return try await get("/api/pages") }
        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: "kind", value: "pages"), URLQueryItem(name: "q", value: term)]
        let query = (components.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
        return try await get("/api/search?" + query)
    }

    struct PublishedPage: Decodable { let title, markdown: String }
    func publishedPage(id: Int, revision: Int?) async throws -> PublishedPage {
        try await get("/api/pages/\(id)" + (revision.map { "/revisions/\($0)" } ?? ""))
    }

    func publishedFile(id: Int) async throws -> Data {
        let response = try await raw(request("/api/library/files/\(id)/download", method: "GET", body: nil))
        guard (200..<300).contains(response.status) else { throw Self.failure(status: response.status, body: response.data) }
        return response.data
    }
}
