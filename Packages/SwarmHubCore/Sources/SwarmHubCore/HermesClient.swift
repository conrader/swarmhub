import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Stock Hermes endpoints. Credentials never appear in models, caches or errors.
public struct HermesClient: AgentClient {
    public let address: ConnectionAddress
    private let key: String
    let session: URLSession

    public init(address: ConnectionAddress, key: String, session: URLSession? = nil) {
        self.address = address; self.key = key
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 3600
            configuration.httpShouldSetCookies = false
            self.session = URLSession(configuration: configuration, delegate: RefuseRedirects(), delegateQueue: nil)
        }
    }

    public func verify() async throws -> ProfileVerification {
        let json = try await json(path: "v1/models")
        guard let row = (json["data"] as? [[String: Any]])?.first, let model = row["id"] as? String, !model.isEmpty else { throw CoreError.invalidResponse }
        guard address.profile == "default" || model == address.profile else {
            throw CoreError.unsupported("The server ignored this profile prefix. This profile cannot be added.")
        }
        let name = address.profile == "default" ? "Hermes" : address.profile.replacingOccurrences(of: "grok-", with: "").replacingOccurrences(of: "-", with: " ").capitalized
        return try await ProfileVerification(name: name, capabilities: capabilities())
    }

    public func capabilities() async throws -> ServerCapabilities {
        do {
            let values = try await json(path: "v1/capabilities")["features"] as? [String: Any] ?? [:]
            return ServerCapabilities(features: Set(values.compactMap { $0.value as? Bool == true ? $0.key : nil }))
        } catch CoreError.http(404) { return ServerCapabilities() }
    }

    public func sessions() async throws -> [SessionSummary] {
        var result: [SessionSummary] = []
        for offset in stride(from: 0, to: 10_000, by: 100) {
            let json = try await json(path: "api/sessions", query: [
                .init(name: "source", value: "api_server"), .init(name: "limit", value: "100"), .init(name: "offset", value: String(offset))
            ])
            guard let rows = (json["data"] ?? json["sessions"]) as? [[String: Any]] else { throw CoreError.invalidResponse }
            for row in rows {
                guard let id = row["id"] as? String, ConnectionAddress.validResourceID(id) else { throw CoreError.invalidIdentifier }
                let source = row["source"] as? String ?? "api_server"
                if source == "grok-import" { continue }
                let title = row["title"] as? String ?? row["preview"] as? String ?? "Conversation"
                result.append(.init(id: id, title: title.isEmpty ? "Conversation" : title, source: source))
            }
            if rows.count < 100 { return result }
        }
        throw CoreError.unsupported("The session list exceeded the paging limit. No sessions were deleted.")
    }

    public func createSession(title: String) async throws -> String {
        let id = "agentapp_ios_\(UUID().uuidString.lowercased())"
        let json = try await json(path: "api/sessions", method: "POST", body: ["id": id, "title": title, "source": "api_server", "system_prompt": ""])
        guard let row = json["session"] as? [String: Any], let created = row["id"] as? String,
              ConnectionAddress.validResourceID(created) else { throw CoreError.invalidResponse }
        return created
    }

    public func messages(sessionID: String) async throws -> [TranscriptMessage] {
        try Self.validateID(sessionID)
        var result: [TranscriptMessage] = []
        for offset in stride(from: 0, to: 50_000, by: 500) {
            let json = try await json(path: "api/sessions/\(sessionID)/messages", query: [
                .init(name: "order", value: "oldest"), .init(name: "limit", value: "500"),
                .init(name: "offset", value: String(offset)), .init(name: "inline_images", value: "false")
            ])
            guard let rows = json["data"] as? [[String: Any]] else { throw CoreError.invalidResponse }
            for (index, row) in rows.enumerated() {
                guard let rawRole = row["role"] as? String, let role = TranscriptRole(rawValue: rawRole) else { continue }
                let text = Self.content(row["content"])
                let rawID = row["id"] ?? row["message_id"]
                let id = rawID.map { String(describing: $0) } ?? "\(sessionID):row:\(offset + index)"
                let stamp = (row["created_at"] ?? row["timestamp"]) as? Double
                result.append(.init(id: id, role: role, text: text, timestamp: stamp.map(Date.init(timeIntervalSince1970:))))
            }
            if rows.count < 500 { return result }
        }
        throw CoreError.unsupported("History exceeded the paging limit. The saved transcript was kept.")
    }

    public func stop(runID: String) async throws {
        try Self.validateID(runID)
        guard try await capabilities().stop else { throw CoreError.unsupported("This server does not support stopping runs.") }
        _ = try await json(path: "v1/runs/\(runID)/stop", method: "POST", body: [:])
    }

    public func steer(runID: String, text: String) async throws {
        try Self.validateID(runID)
        guard try await capabilities().steer else { throw CoreError.unsupported("This server does not support guidance during a run.") }
        let result = try await json(path: "v1/runs/\(runID)/steer", method: "POST", body: ["input": text])
        guard result["accepted"] as? Bool != false else { throw CoreError.unsupported("The server did not accept this guidance.") }
    }

    public func resolve(_ approval: ApprovalItem, approved: Bool) async throws {
        try Self.validateID(approval.runID); try Self.validateID(approval.requestID)
        guard try await capabilities().approvals else { throw CoreError.unsupported("This server cannot accept approval decisions.") }
        guard !approved || approval.canApprove else { throw CoreError.unsupported("The exact action is unavailable. This request cannot be approved.") }
        guard approval.choices.contains(approved ? "once" : "deny") else { throw CoreError.unsupported("This approval choice is unavailable.") }
        let result = try await json(path: "v1/runs/\(approval.runID)/approval", method: "POST", body: ["request_id": approval.requestID, "choice": approved ? "once" : "deny"])
        guard let count = result["resolved"] as? Int, count > 0 else { throw CoreError.unsupported("The request was not acknowledged. It may already be resolved.") }
    }

    public func run(runID: String) async throws -> RunSnapshot {
        try Self.validateID(runID)
        let result = try await json(path: "v1/runs/\(runID)")
        guard let status = result["status"] as? String else { throw CoreError.invalidResponse }
        let state: TurnState? = ["completed": .completed, "cancelled": .cancelled, "failed": .failed][status]
        let approval = (result["approval"] as? [String: Any]).flatMap { Self.approval($0, runID: runID) }
        return .init(state: state, status: status, approval: approval)
    }

    func request(path: String, method: String = "GET", query: [URLQueryItem] = [], body: [String: Any]? = nil) throws -> URLRequest {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CoreError.missingKey }
        var request = URLRequest(url: try address.endpoint(path, query: query))
        request.httpMethod = method
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { request.httpBody = try HermesContent.body(body) }
        return request
    }

    func json(path: String, method: String = "GET", query: [URLQueryItem] = [], body: [String: Any]? = nil) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: request(path: path, method: method, query: query, body: body))
        try Self.validate(response)
        guard data.count <= 16_000_000, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CoreError.invalidResponse }
        return json
    }

    static func validate(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else { throw CoreError.invalidResponse }
        if (300..<400).contains(response.statusCode) { throw CoreError.redirectRefused }
        guard (200..<300).contains(response.statusCode) else { throw CoreError.http(response.statusCode) }
    }
    static func validateID(_ id: String) throws { guard ConnectionAddress.validResourceID(id) else { throw CoreError.invalidIdentifier } }
    static func content(_ value: Any?) -> String {
        if let text = value as? String { return text }
        if let object = value as? [String: Any] { return object["text"] as? String ?? "" }
        return (value as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
    }
}

private final class RefuseRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
