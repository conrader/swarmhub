import Foundation

/// P12: an OpenClaw session's transcript, threads and model list.
extension OpenClawBackend: ModelCatalogProviding {
    /// `chat.history` mapped to rows: user and assistant rows with visible text (`[Image: …]` lines for image blocks);
    /// a user row's leading P26 manager block is removed; tool and system rows are skipped. Opening the chat connects (a user action); the launch sweep is Hermes-only.
    func loadMessages(sessionID: String) async throws -> [BackendMessage] {
        let (connection, capabilities) = try await connected()
        try require(.history, in: capabilities)
        return OpenClawHistory.rows(try await historyPage(connection, sessionKey: sessionID))
    }

    /// A thread: `sessions.create {agentId, parentSessionKey, key, fork:true, forkFrom:"last-completed", displayName}`, so it
    /// carries the transcript as it stood. A Gateway that rejects the fork parameters hides Reply in thread for this link.
    func forkSession(sessionID: String, id: String?) async throws -> String {
        let (connection, capabilities) = try await connected()
        try require(.threads, in: capabilities)
        let key = Self.sessionKey(agentID: agentID, name: id ?? UUID().uuidString)
        let params: GatewayJSON = ["agentId": .string(agentID), "parentSessionKey": .string(sessionID), "key": .string(key), "fork": true,
                                   "forkFrom": "last-completed", "displayName": .string("\(AppConstants.name) · thread")]
        let response = try await call(connection, "sessions.create", params, feature: .threads)
        return response["key"]?.string ?? key
    }

    // MARK: ModelCatalogProviding (P17)

    var catalogScope: String { "\(gateway.id)|\(agentID)" }

    /// `models.list {agentId}` grouped by provider, with the agent's configured primary model as its default. Reads
    /// only over a live link: opening the Overview never connects a Gateway.
    func modelCatalog(sessionID: String?) async throws -> ModelCatalog {
        guard let connection = await hub.currentConnection(gateway.id), let capabilities = await hub.capabilities(gatewayID: gateway.id, connection: connection) else {
            throw BackendError.unavailable("Connect this Gateway to see its models.")
        }
        if let reason = capabilities.reason(.models) { throw BackendError.unavailable("\(reason) Update OpenClaw to list this agent's models.") }
        let listed = try await call(connection, "models.list", ["agentId": .string(agentID)])
        var primary: String?
        if capabilities.isAvailable(.agents), let agents = try? await call(connection, "agents.list", .object([:])) {
            primary = OpenClawAgent.list(agents).agents.first { $0.id == agentID }?.primaryModel
        }
        return OpenClawHistory.catalog(listed, primary: primary, gatewayName: gateway.name, agentID: agentID)
    }
}

enum OpenClawHistory {
    static func rows(_ page: GatewayJSON) -> [BackendMessage] {
        (page["messages"]?.array ?? []).compactMap { row in
            guard let role = row["role"]?.string, role == "user" || role == "assistant" else { return nil }
            let shown = OpenClawText.visible(row) ?? ""
            let text = role == "user" ? ManagerEnvelope.strip(shown) : shown
            let content = ([text] + OpenClawText.imageLines(row)).filter { !$0.isEmpty }.joined(separator: "\n")
            guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return BackendMessage(role: role, content: content, createdAt: date(row["timestamp"] ?? row["createdAt"]), finishReason: row["stopReason"]?.string)
        }
    }

    /// ISO 8601 text or epoch milliseconds.
    static func date(_ value: GatewayJSON?) -> Date? {
        if let ms = value?.double { return Date(timeIntervalSince1970: ms / 1000) }
        guard let text = value?.string else { return nil }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    static func catalog(_ listed: GatewayJSON, primary: String?, gatewayName: String, agentID: String) -> ModelCatalog {
        var order: [String] = [], byProvider: [String: ModelCatalog.Supplier] = [:]
        for row in listed["models"]?.array ?? [] {
            guard let id = row["id"]?.string, let provider = row["provider"]?.string else { continue }
            if byProvider[provider] == nil { order.append(provider); byProvider[provider] = .init(slug: provider, name: ModelCatalog.Supplier.titleCased(provider), models: []) }
            byProvider[provider]?.models.append(id)
            if row["available"]?.bool == false {
                let why = row["unavailableReason"]?.string.map { $0.replacingOccurrences(of: "_", with: " ") } ?? "unavailable"
                byProvider[provider]?.reasons[id] = "Not available on the Gateway now (\(why))."
            }
        }
        let primaryProvider = primary.flatMap { model in order.first { provider in byProvider[provider]?.models.contains { ModelCatalog.sameModel($0, model) } == true } }
            ?? primary?.split(separator: "/").first.map(String.init).flatMap { order.contains($0) ? $0 : nil }
        if let primaryProvider, let index = order.firstIndex(of: primaryProvider) { order.insert(order.remove(at: index), at: 0) }
        return ModelCatalog(suppliers: order.compactMap { byProvider[$0] }, defaultSupplier: primaryProvider,
                            agentDefault: primary.map { .init(model: $0, supplier: primaryProvider) }, pinning: .none,
                            place: "OpenClaw Gateway \(gatewayName)", detail: "Agent \(agentID)")
    }
}
