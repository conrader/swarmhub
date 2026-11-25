import Foundation

extension HerdrClient {
    struct CodejobActivity: Decodable, Equatable, Sendable {
        struct Host: Decodable, Equatable, Sendable {
            let host: String
            let complete: Bool
            let jobs: [Job]
        }

        struct Job: Decodable, Equatable, Sendable {
            enum State: String, Decodable { case working, queued, wrapper, unknown }
            enum Provider: String, Decodable { case codex, claude }
            let owner: UUID
            let job: String
            let state: State
            let provider: Provider?

            var isWorking: Bool { state == .working && provider != nil }
            var description: String {
                switch state {
                case .working: provider.map { $0 == .codex ? "Codex working" : "Claude working" } ?? "Worker status unknown"
                case .queued: "Queued · waiting for a lock"
                case .wrapper: "Wrapper running · worker unconfirmed"
                case .unknown: "Worker status unknown"
                }
            }
        }

        // An incompatible optional feed must not prevent reading the native roster.
        let hosts: [Host]?
        init(from decoder: Decoder) throws {
            hosts = try? decoder.singleValueContainer().decode([Host].self)
        }
    }
}
