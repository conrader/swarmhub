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

extension HerdrClient {
    struct Approval: Decodable, Identifiable, Sendable {
        let id: Int
        var launchModel: String? = nil
        let agent, provider, tool, cwd, arguments: String
        let core, address: String?
        let createdMs: UInt64?

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

    func approvals(for name: String) async throws -> [Approval] {
        struct Inbox: Decodable { let pending: [Approval] }
        let inbox: Inbox = try await get("/api/approvals?pending_only=true")
        guard !inbox.pending.isEmpty else { return [] }
        let current = try await workspace()
        guard let agent = liveAgent(named: name, in: current) else { return [] }
        return inbox.pending.filter {
            $0.agent == agent.name && $0.core == current.core && $0.address == agent.address &&
                $0.createdMs == agent.createdMs
        }
    }

    enum Decision: String { case approve, deny }
    func decide(_ approval: Approval, _ decision: Decision) async throws {
        struct Accepted: Decodable { let id: Int }
        let _: Accepted = try await send(request("/api/approvals/\(approval.id)", method: "POST", body: try JSONEncoder().encode(decision.rawValue)))
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
