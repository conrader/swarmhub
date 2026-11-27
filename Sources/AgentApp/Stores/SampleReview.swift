import Foundation

enum SampleReview: String, CaseIterable {
    case testCommand, paymentsBot

    enum Decision: String {
        case allowOnce, allowInProject, decline, createBot, dismiss

        var title: String {
            switch self {
            case .allowOnce: "Allow once"
            case .allowInProject: "Always allow in /srv/shop"
            case .decline: "Decline"
            case .createBot: "Create bot"
            case .dismiss: "Not now"
            }
        }

        var receipt: String {
            switch self {
            case .allowOnce: "Sample command allowed once. 28 tests passed."
            case .allowInProject: "Sample tests passed. Saved the project rule for /srv/shop."
            case .decline: "Sample command declined."
            case .createBot: "Payments joined the sample team. Every action requires approval."
            case .dismiss: "Payments proposal dismissed."
            }
        }
    }

    static let messageKey = "sample.review"

    var invitation: String {
        switch self {
        case .testCommand: "Scout has reviewed the importer tests. You can now decide whether Patch runs them."
        case .paymentsBot: "Review the Payments proposal here or in Needs Attention."
        }
    }

    func belongs(to message: ChatMessage) -> Bool {
        guard message.role == .assistant && message.presentation == .text else { return false }
        if let value = message.metadata[Self.messageKey] { return value == rawValue }
        // Released sample histories predate the marker and contain the original invitation.
        return message.content == invitation
    }

    static let projectRule = "Allow swift test --filter ImporterTests in /srv/shop"

    var title: String {
        switch self {
        case .testCommand: "Run swift test --filter ImporterTests in /srv/shop"
        case .paymentsBot: "Create Payments to prepare supplier invoices"
        }
    }

    var detail: String {
        switch self {
        case .testCommand: "Scout (Claude) reviewed the local importer tests. They use no network and perform no destructive writes."
        case .paymentsBot: "Jarvis paused creation because this bot handles billing. Each action requires your approval."
        }
    }

    var choices: [Decision] {
        switch self {
        case .testCommand: [.allowOnce, .allowInProject, .decline]
        case .paymentsBot: [.createBot, .dismiss]
        }
    }
}

extension Bot {
    var pendingSampleReview: SampleReview? {
        guard sampleDecision == nil else { return nil }
        return sampleReview
    }

    var sampleReview: SampleReview? {
        guard isDemo, backend == .mock else { return nil }
        switch sampleRole {
        case .jarvis: return .paymentsBot
        case .patch: return .testCommand
        default: return nil
        }
    }
}

extension AppStore {
    func resolveSampleReview(_ decision: SampleReview.Decision, for bot: Bot) {
        guard bots.contains(bot), let review = bot.pendingSampleReview, review.choices.contains(decision) else { return }
        objectWillChange.send()
        bot.sampleDecision = decision
        if decision == .createBot {
            let payments = Bot(name: "Payments", title: "Supplier invoices", isDemo: true)
            payments.sampleRole = .payments
            bots.append(payments)
        }
        if !bot.messages.contains(where: review.belongs(to:)) {
            bot.messages.append(ChatMessage(role: .assistant, content: decision.receipt))
        }
        updateSampleGoal(in: bot)
        save()
    }
}
