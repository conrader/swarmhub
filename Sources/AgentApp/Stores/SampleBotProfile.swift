import Foundation

/// Offline examples displayed when a person chooses the sample workspace.
struct SampleBotProfile {
    let instructions: String
    let models: [String]
    let contextPercent: Int
    let spend: String
    let projects: [String]
    let controlLevel: String
    let reviewer: String
    let rules: [String]
    let routine: String
    let schedule: String
    let skills: [String]
}

extension SampleWorkspace.Role {
    var profile: SampleBotProfile {
        switch self {
        case .jarvis:
            .init(instructions: "Primary bot on Studio server. Coordinates specialists, proposes sensitive bots for approval, and dispatches helpers.",
                  models: ["Claude · Sonnet", "Codex · Sol", "OpenCode · DeepSeek"],
                  contextPercent: 42, spend: "Subscription",
                  projects: ["web-1 · /srv/shop", "web-1 · /srv/docs"],
                  controlLevel: "Ask risky actions", reviewer: "You (main bot)",
                  rules: ["Allow bot creation for routine roles", "Ask before money/deploy bots"],
                  routine: "Skillshare sync check", schedule: "Daily · 09:00 · In sync",
                  skills: ["Bot management", "Release checklist", "Brand voice", "GitHub"])
        case .patch:
            .init(instructions: "Drafts release notes, watches pull requests for CI failures, inspects UI screenshots, and runs commands with live steps.",
                  models: ["Codex · Sol", "Claude · Sonnet", "Gemini CLI · Beta"],
                  contextPercent: 34, spend: "Subscription",
                  projects: ["web-1 · /srv/shop", "local · ~/code/swarmhub"],
                  controlLevel: "Ask reviewer (Scout)", reviewer: "Scout · Claude",
                  rules: ["Allow swift test in /srv/shop (1h)", "Ask reviewer before deploys"],
                  routine: "Watch PR #142 CI checks", schedule: "Zero idle tokens · Active",
                  skills: ["Changelog", "Code review", "Test runner"])
        case .scout:
            .init(instructions: "Audits Patch’s commands as a cross-model reviewer, runs scheduled morning briefs, and publishes searchable Pages.",
                  models: ["Claude · Sonnet", "OpenCode · Qwen", "Codex · Sol"],
                  contextPercent: 28, spend: "Subscription",
                  projects: ["web-1 · /srv/docs"],
                  controlLevel: "Ask risky actions", reviewer: "You",
                  rules: ["Read-only across connected projects", "Publish Morning Brief Page"],
                  routine: "Morning brief", schedule: "Weekdays · 08:55 · Published Page",
                  skills: ["Researcher", "Writing plainly", "Meeting minutes"])
        case .legal:
            .init(instructions: "Created by Jarvis for contract reviews. Runs on DeepSeek via OpenCode with a strict $2.00 session spend cap.",
                  models: ["OpenCode · DeepSeek", "Claude · Sonnet"],
                  contextPercent: 14, spend: "$0.06 / $2.00 cap",
                  projects: ["Saved documents"],
                  controlLevel: "Ask everything", reviewer: "You",
                  rules: ["Read-only documents", "Ask before outbound drafts"],
                  routine: "No active routines", schedule: "On-demand · Idle",
                  skills: ["PDF forms", "Writing plainly"])
        case .payments:
            .init(instructions: "Prepare supplier invoices for review. Ask before taking any action.",
                  models: ["Codex · Sol"], contextPercent: 0, spend: "Subscription", projects: ["Supplier invoices"],
                  controlLevel: "Ask everything", reviewer: "You", rules: ["Ask before preparing an invoice"],
                  routine: "No active routines", schedule: "On demand", skills: ["Invoice preparation"])
        }
    }
}

extension Bot {
    var sampleProfile: SampleBotProfile? {
        guard isDemo, backend == .mock else { return nil }
        return sampleRole?.profile
    }

    var sampleModelLabel: String? {
        guard let models = sampleProfile?.models else { return nil }
        if let sampleModel, models.contains(sampleModel) { return sampleModel }
        return models.first
    }
}
