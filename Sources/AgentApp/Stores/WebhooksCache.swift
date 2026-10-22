import Foundation

/// What the Webhooks section of the Routines tab shows for one agent (memory only). Keys are never kept here: a new
/// key lives only in the reveal sheet's state until it closes.
struct BotWebhooksState: Equatable, Sendable {
    var panel: WebhookPanel?
    /// The action in flight; one at a time per agent.
    var busy: WebhookAction?
    var error: String?
    /// The box answered, but the action itself did not take (e.g. the receiver could not be started).
    var notice: String?
}

/// A created or rotated routine's address and new key, shown once in the reveal sheet.
struct WebhookReveal: Identifiable, Equatable {
    let id = UUID()
    let routine: String, url: String, key: String, rotated: Bool
    var curl: String {
        "curl -X POST -H 'Content-Type: application/json' -H '\(WebhookCopy.header): \(key)' -d '{\"text\": \"…\"}' '\(url)'"
    }
}

@MainActor final class WebhooksCache: ObservableObject {
    @Published private(set) var entries: [UUID: BotWebhooksState] = [:]
    /// Off for headless, demo and test stores: views never load on appear.
    var autoLoad = true

    func state(for botID: UUID) -> BotWebhooksState { entries[botID] ?? .init() }
    func update(_ botID: UUID, _ change: (inout BotWebhooksState) -> Void) {
        var state = entries[botID] ?? .init(); change(&state); entries[botID] = state
    }
}
