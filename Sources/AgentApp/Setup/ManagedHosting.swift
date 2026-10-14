import Foundation

/// P21 "Set up a new one": a strictly inert placeholder for hosted agents (deferred by Konrad on 2026-10-13). It holds
/// the provider's display name, the availability switch and the coming-soon words, nothing else: no network, no
/// account, no billing and no stored secret. A real path plugs in behind `isAvailable` later.
enum ManagedHosting {
    /// One constant; no vendor name appears in the code (a guard test keeps it that way).
    static let providerName = "Managed hosting"
    static let isAvailable = false

    static let cardTitle = "Set up a new one"
    static let cardDetail = "We run it for you."
    static let badge = "Coming soon"
    static let title = "Hosted agents are coming soon."
    static let detail = "You will be able to get a ready-made box here without running anything yourself. It is not available yet; nothing is created, sent or charged."

    static let all = [providerName, cardTitle, cardDetail, badge, title, detail]
}
