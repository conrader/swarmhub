import Foundation

extension HerdrClient {
    struct SessionModel: Decodable, Equatable, Sendable {
        let current: String?
        let defaultModel: String?
        var effective: String? { current ?? defaultModel }
    }

    func sessionModel(_ agent: AgentRef, core: String) async throws -> SessionModel {
        var query = URLComponents()
        query.queryItems = [URLQueryItem(name: "expected_core", value: core)]
        return try await get("/api/agents/\(agent.address)/\(agent.createdMs)/model?" + (query.percentEncodedQuery ?? ""))
    }

    func selectModel(_ id: String?, for agent: AgentRef, core: String) async throws -> SessionModel {
        let state = try await sessionModel(agent, core: core)
        if let id, state.current == id { return state }
        let change = id.map { ["action": "select", "id": $0] } ?? ["action": "reset"]
        let changed: SessionModel = try await post("/api/agents/\(agent.address)/\(agent.createdMs)/model",
            ["expected_core": core, "expected_current": state.current as Any? ?? NSNull(),
             "expected_default": state.defaultModel as Any? ?? NSNull(), "change": change])
        guard changed.effective != nil, changed.effective == (id ?? state.defaultModel) else { throw Failure.http(409, "OpenCode did not confirm the requested model.") }
        return changed
    }
}

struct HerdrModelConfirmation: Codable, Equatable, Sendable {
    let server: String
    let core: String
    let address: String
    let created: UInt64
    let id: String
    let label: String

    func matches(server: String?, core: String?, agent: HerdrClient.AgentRef?) -> Bool {
        self.server == server && self.core == core && address == agent?.address && created == agent?.createdMs
    }
}
