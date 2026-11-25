import Foundation

extension HerdrClient {
    enum RoutineSchedule: Codable, Equatable, Sendable {
        enum Source: String, Codable, Sendable { case github, slack }

        struct Filter: Codable, Equatable, Sendable {
            let field: String
            let equals: String

            fileprivate var isValid: Bool {
                let segments = field.split(separator: ".", omittingEmptySubsequences: false)
                return !field.isEmpty && field.utf8.count <= 128 && segments.count <= 8
                    && segments.allSatisfy { segment in
                        !segment.isEmpty && segment.allSatisfy {
                            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-")
                        }
                    }
                    && equals.unicodeScalars.count <= 160
                    && equals.unicodeScalars.contains { !$0.properties.isWhitespace }
                    && !equals.unicodeScalars.contains { $0.properties.generalCategory == .control }
            }
        }

        static let maximumWebhookFilters = 4

        case interval(minutes: UInt32)
        case daily(hour: UInt8, minute: UInt8, timezone: String?, weekdays: Bool)
        case webhook(source: Source?, filters: [Filter], review: Bool)

        private enum Kind: String, Codable { case interval, daily, webhook }
        private enum CodingKeys: String, CodingKey {
            case kind, minutes, hour, minute, timezone, weekdays, source, filters, review
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            switch try values.decode(Kind.self, forKey: .kind) {
            case .interval:
                self = .interval(minutes: try values.decode(UInt32.self, forKey: .minutes))
            case .daily:
                self = .daily(hour: try values.decode(UInt8.self, forKey: .hour),
                              minute: try values.decode(UInt8.self, forKey: .minute),
                              timezone: try values.decodeIfPresent(String.self, forKey: .timezone),
                              weekdays: try values.decode(Bool.self, forKey: .weekdays))
            case .webhook:
                self = .webhook(source: try values.decodeIfPresent(Source.self, forKey: .source),
                                filters: try values.decodeIfPresent([Filter].self, forKey: .filters) ?? [],
                                review: try values.decodeIfPresent(Bool.self, forKey: .review) ?? false)
            }
        }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .interval(let minutes):
                try values.encode(Kind.interval, forKey: .kind)
                try values.encode(minutes, forKey: .minutes)
            case .daily(let hour, let minute, let timezone, let weekdays):
                try values.encode(Kind.daily, forKey: .kind)
                try values.encode(hour, forKey: .hour)
                try values.encode(minute, forKey: .minute)
                try values.encodeIfPresent(timezone, forKey: .timezone)
                try values.encode(weekdays, forKey: .weekdays)
            case .webhook(let source, let filters, let review):
                try values.encode(Kind.webhook, forKey: .kind)
                try values.encodeIfPresent(source, forKey: .source)
                if !filters.isEmpty { try values.encode(filters, forKey: .filters) }
                if review { try values.encode(review, forKey: .review) }
            }
        }

        var webhookValidationMessage: String? {
            guard case .webhook(let source, let filters, _) = self else { return nil }
            if filters.count > Self.maximumWebhookFilters { return "Use up to four JSON field filters." }
            if source == .slack {
                if !filters.contains(where: { $0.field == "team_id" && Self.validSlackID($0.equals, prefixes: "T") }) {
                    return "Enter a Slack workspace ID starting with T in team_id."
                }
                if !filters.contains(where: { $0.field == "channel" && Self.validSlackID($0.equals, prefixes: "CG") }) {
                    return "Enter a Slack channel ID starting with C or G in channel."
                }
            }
            if filters.contains(where: { !$0.isValid }) {
                return "Use dot-separated JSON paths with up to 8 segments and 128 characters. Each segment can contain letters A–Z, digits, underscores, or hyphens. Enter nonempty plain text up to 160 characters for each value."
            }
            if Set(filters.map(\.field)).count != filters.count { return "Use each JSON field path only once." }
            return nil
        }

        private static func validSlackID(_ value: String, prefixes: String) -> Bool {
            guard (2...32).contains(value.utf8.count), let first = value.first, prefixes.contains(first) else { return false }
            return value.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber) }
        }

        func summary(in displayZone: TimeZone) -> String {
            switch self {
            case .interval(let minutes):
                return minutes == 1 ? "Every minute" : "Every \(minutes) minutes"
            case .daily(let hour, let minute, let timezone, let weekdays):
                let time = String(format: "%02d:%02d", Int(hour), Int(minute))
                let summary = "\(weekdays ? "Weekdays" : "Daily") at \(time)"
                // Keep the actual wall-clock rule if pinned elsewhere. The next occurrence
                // is shown separately in the display zone, including any day or DST shift.
                guard let timezone, TimeZone(identifier: timezone) != displayZone else { return summary }
                return "\(summary) (\(timezone))"
            case .webhook(let source, _, _):
                switch source {
                case .github: return "GitHub webhook"
                case .slack: return "Slack mention"
                case nil: return "Webhook"
                }
            }
        }
    }

    struct Routine: Codable, Identifiable, Sendable {
        enum State: String, Codable, Sendable { case active, paused, archived }

        let id: Int64
        let core: String
        let target: AgentRef
        let agent: String
        let name: String
        let task: String
        let schedule: RoutineSchedule
        let state: State
        let nextAt: Int64?
        var webhookReady: Bool
        let profileId: Int?
        var ownerBot: UUID? = nil
    }

    struct RoutineRun: Codable, Identifiable, Sendable {
        struct Conversation: Codable, Sendable {
            let core: String
            let address: String
            let createdMs: UInt64
            let agent: String
        }

        struct Outcome: Codable, Sendable {
            let id: Int64
            let state: String
            let summary: String
            let atMs: Int64
        }

        let id: Int64
        let kind: String
        let atMs: Int64
        let state: String
        let detail: String?
        let taskId: Int64?
        let conversation: Conversation?
        let awaitingResult: Bool?
        let result: Outcome?
    }

    struct RoutineDetail: Decodable, Sendable {
        let routine: Routine
        let runs: [RoutineRun]
        let reviews: [RoutineReview]?
        let slackReady: Bool?
    }

    struct RoutineWebhookKey: Decodable, Sendable {
        let key: String
        let path: String
    }

    struct RoutineReview: Decodable, Identifiable, Sendable {
        let id: Int64
        let atMs: Int64
        let payload: JSONValue?
        let stale: Bool
    }

    enum RoutineReviewDecision: String, Encodable, Sendable { case approve, dismiss }

    struct RoutineReviewResolution: Decodable, Sendable {
        let id: Int64?
        let dismissed: Bool?
    }

    enum RoutineControl: String, Encodable, Sendable { case pause, resume, archive }

    struct RoutineEdit: Encodable, Sendable {
        let name: String
        let task: String
        let schedule: RoutineSchedule
    }

    private struct RoutineCreate: Encodable {
        let name: String
        let task: String
        let schedule: RoutineSchedule
        let target: AgentRef
    }

    struct RoutineTest: Decodable, Sendable { let id: Int64 }

    struct BotCheckin: Decodable, Identifiable, Sendable {
        struct Schedule: Decodable, Sendable {
            let kind: String
            let url: String?
        }

        let id: Int64
        let what: String
        let paused: Bool
        let schedule: Schedule
        let nextMs: Int64?
    }

    func routines() async throws -> [Routine] { try await get("/api/routines") }

    func routine(_ id: Int64) async throws -> RoutineDetail { try await get("/api/routines/\(id)") }

    func createRoutine(_ edit: RoutineEdit, target: AgentRef) async throws -> Routine {
        let body = RoutineCreate(name: edit.name, task: edit.task, schedule: edit.schedule, target: target)
        return try await postRoutine("/api/routines", body)
    }

    func editRoutine(_ id: Int64, _ edit: RoutineEdit) async throws -> Routine {
        try await postRoutine("/api/routines/\(id)", edit)
    }

    func controlRoutine(_ id: Int64, _ action: RoutineControl) async throws -> Routine {
        try await postRoutine("/api/routines/\(id)/state", action)
    }

    func testRoutine(_ id: Int64) async throws -> RoutineTest {
        try await send(request("/api/routines/\(id)/test", method: "POST", body: nil))
    }

    func rotateRoutineWebhookKey(id: Int64) async throws -> RoutineWebhookKey {
        try await postRoutine("/api/routines/\(id)/webhook-key", [String: String]())
    }

    func resolveRoutineReview(routineID: Int64, reviewID: Int64, decision: RoutineReviewDecision) async throws -> RoutineReviewResolution {
        try await postRoutine("/api/routines/\(routineID)/reviews/\(reviewID)", decision)
    }

    static func routineWebhookURL(serverAddress: String, id: Int64, source: RoutineSchedule.Source?) -> URL? {
        guard let base = validatedBaseURL(serverAddress),
              var endpoint = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        endpoint.user = nil
        endpoint.password = nil
        endpoint.fragment = nil
        switch source {
        case .slack: endpoint.path = "/hooks/slack"
        case .github: endpoint.path = "/hooks/routines/\(id)/github"
        case nil: endpoint.path = "/hooks/routines/\(id)"
        }
        return endpoint.url
    }

    func botCheckins(_ id: UUID) async throws -> [BotCheckin] {
        struct Plans: Decodable { let checkins: [BotCheckin] }
        let plans: Plans = try await get("/api/bots/\(id.uuidString.lowercased())/checkins")
        return plans.checkins
    }

    private func postRoutine<T: Decodable>(_ path: String, _ body: some Encodable) async throws -> T {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return try await send(request(path, method: "POST", body: encoder.encode(body)))
    }
}

struct HerdrRoutineSessions: Sendable {
    private struct Binding: Hashable {
        let core: String
        let target: HerdrClient.AgentRef
    }

    private let core: String?
    private let liveRefs: Set<HerdrClient.AgentRef>
    private let knownBindings: Set<Binding>
    private let profileIDs: Set<Int>
    let liveTarget: HerdrClient.AgentRef?

    init(agentName: String, workspace: HerdrClient.Workspace?, profiles: [HerdrClient.Profile]) {
        let agents = workspace?.agents.filter { $0.parent == nil } ?? []
        let running = agents.filter { $0.isLive && $0.reason == nil }
        let namedAgents = agents.filter { Self.matches($0.name, agentName) }
        let namedRefs = Set(namedAgents.map(\.ref))
        let claims = profiles.filter { profile in
            Self.matches(profile.runtimeName, agentName) || profile.sessions?.contains {
                $0.core == workspace?.core && namedRefs.contains(.init(address: $0.address, createdMs: $0.createdMs))
            } == true
        }
        let saved = claims.flatMap { $0.sessions ?? [] }.compactMap { session -> Binding? in
            guard let core = session.core else { return nil }
            return Binding(core: core, target: .init(address: session.address, createdMs: session.createdMs))
        }
        core = workspace?.core
        liveRefs = Set(running.map(\.ref))
        profileIDs = Set(claims.map(\.id))
        if let core {
            knownBindings = Set(saved + namedRefs.map { Binding(core: core, target: $0) })
            let live = running.filter { namedRefs.contains($0.ref) }
            liveTarget = live.first { $0.name == agentName }?.ref ?? live.first?.ref
                ?? running.first { saved.contains(Binding(core: core, target: $0.ref)) }?.ref
        } else {
            knownBindings = Set(saved)
            liveTarget = nil
        }
    }

    func isLive(_ routine: HerdrClient.Routine) -> Bool? {
        guard let core else { return nil }
        return routine.core == core && liveRefs.contains(routine.target)
    }

    func contains(_ routine: HerdrClient.Routine) -> Bool {
        knownBindings.contains(Binding(core: routine.core, target: routine.target))
            || routine.profileId.map(profileIDs.contains) == true
    }

    static func matches(_ storedName: String, _ agentName: String) -> Bool {
        // A renamed bot keeps the runtime name's ID suffix, as in HerdrClient.liveAgent.
        storedName == agentName || HerdrClient.suffix(of: storedName) == HerdrClient.suffix(of: agentName)
    }
}

func routinesForBot(_ routines: [HerdrClient.Routine], agentName: String, sessions: HerdrRoutineSessions?) -> [HerdrClient.Routine] {
    routines.filter {
        $0.state != .archived && (HerdrRoutineSessions.matches($0.agent, agentName) || sessions?.contains($0) == true)
    }
}

extension HerdrClient {
    struct TransferBody: Encodable {
        let core: String
        let action: String
        var id: Int64?
        var target: AgentRef?
        var name: String?
        var task: String?
        var schedule: RoutineSchedule?
        var state: Routine.State?
        var nextAt: Int64?
        var after: String?
        var owner: UUID?
        var attempt: UUID?
        var digests: [String]?
    }

    struct TransferResult: Decodable { let routine: Routine?; let digests: [String]? }

    func transfer(_ token: UUID, _ body: TransferBody) async throws -> TransferResult {
        try await postRoutine("/api/routine-transfers/\(token.uuidString)", body)
    }
}
