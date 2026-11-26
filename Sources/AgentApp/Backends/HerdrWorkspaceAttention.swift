import Foundation

extension HerdrClient {
    struct AttentionInbox: Decodable {
        let ciFailures: [CIFailure]?
        let completions: [JobCompletion]?
    }

    struct JobCompletion: Decodable, Equatable, Sendable, Identifiable {
        let id: String
        let ownerBotId: String
        let ownerName: String?
        let verdict: String
        let outcomeDetail: String?
        let state: String
        let blocker: String?

        var delivery: String {
            switch state {
            case "pending": "Waiting for delivery to the bot"
            case "offered": "Waiting for the bot to acknowledge"
            case "uncertain": "Delivery to the bot is unconfirmed"
            default: state
            }
        }
    }

    struct CIFailure: Decodable, Equatable, Identifiable {
        let id: Int64
        let bot: String
        let pullRequest: String
        let checkRun: String

        var checkURL: URL? {
            guard checkRun.wholeMatch(of: #/https:\/\/github\.com\/[a-zA-Z0-9_.-]+\/[a-zA-Z0-9_.-]+\/runs\/[0-9]+/#) != nil else { return nil }
            return URL(string: checkRun)
        }
    }
}
