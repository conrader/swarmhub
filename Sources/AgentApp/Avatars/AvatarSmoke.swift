import AppKit
import Foundation
@preconcurrency import BotAvatarsKit

/// What one rendered avatar reports to `--ui-smoke`.
enum AvatarFacts {
    static func origin(_ bot: Bot, look: AvatarLook) -> String {
        if case .classic = look { return "classic" }
        return bot.avatarMarkMigrated ? "migrated" : "stored"
    }

    @MainActor static func facts(bot: Bot, look: AvatarLook, mode: AvatarMotionMode, size: CGFloat, place: String) -> [String: Any] {
        var facts: [String: Any] = ["name": bot.name, "origin": origin(bot, look: look), "mode": mode.rawValue, "size": Double(size), "place": place]
        switch look {
        case .mark(let shape, let colour):
            let body = AvatarKitMap.body(for: shape)
            facts["words"] = "\(shape)/\(colour.rawValue)"
            facts["stored_words"] = bot.avatarMark.map { "\($0.shape)/\($0.colour)" } ?? NSNull()
            facts["body"] = body.type.rawValue
            facts["approximate"] = body.approximate
        case .classic(let name):
            facts["words"] = name.rawValue
            facts["body"] = "classic"
        }
        return facts
    }
}

/// `--ui-smoke`'s `avatars` object (briefs/P15.md item 14): facts reported by the real views, then three probes:
/// by context after a settle, Calm forced for the probe, and one bot forced to working for a moment.
@MainActor enum AvatarSmoke {
    struct Budget {
        var settle: Duration = .milliseconds(1500)
        var working: Duration = .seconds(2)
        var stop: Duration = .seconds(3)
    }

    static func collect(store: AppStore, bot: Bot?, budget: Budget = .init(), settings: AvatarMotionSettings = .shared) async -> [String: Any] {
        var report: [String: Any] = [
            "reduce_motion": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            "motion_preference": settings.preference.rawValue,
            "app_can_idle": AvatarActivity.shared.canIdle
        ]
        try? await Task.sleep(for: budget.settle)
        report["sidebar"] = store.bots.filter { !$0.isHidden }.compactMap { UISmokeProbe.avatarFacts["sidebar|\($0.id)"] }
        report["groups"] = store.groups.filter { !$0.isHidden }.map { group in
            ["name": group.name, "marks": facts(prefix: "group:\(group.id)#")] as [String: Any]
        }
        report["focus"] = ["chat_header", "overview", "group_header"].flatMap { facts(prefix: $0) }
        report["idle"] = clock()

        settings.probeOverride = .calm
        try? await Task.sleep(for: budget.settle)
        report["calm"] = clock()

        if let bot, case .mark = bot.avatarLook {
            report["working"] = await workingProbe(store: store, bot: bot, budget: budget)
        } else {
            report["working"] = ["skipped": "no bot with a mark"]
        }
        settings.probeOverride = nil
        return report
    }

    /// Under Calm (no idle views), forces `bot` to working: the display link must start and tick, then stop.
    private static func workingProbe(store: AppStore, bot: Bot, budget: Budget) async -> [String: Any] {
        let key = "sidebar|\(bot.id)"
        UISmokeProbe.forcedWorking = bot.id; store.objectWillChange.send()
        try? await Task.sleep(for: .milliseconds(500))
        let firstFrame = BotAvatarClock.shared.frame
        let during: [String: Any] = ["mode": UISmokeProbe.avatarFacts[key]?["mode"] ?? NSNull(), "clock_running": BotAvatarClock.shared.isRunning,
                                     "live_views": UISmokeProbe.liveAvatarViews]
        try? await Task.sleep(for: budget.working - .milliseconds(500))
        let lastFrame = BotAvatarClock.shared.frame
        UISmokeProbe.forcedWorking = nil; store.objectWillChange.send()
        let started = ContinuousClock.now
        let stopped = await HeadlessE2E.wait(budget.stop, poll: .milliseconds(50)) {
            !BotAvatarClock.shared.isRunning && (UISmokeProbe.avatarFacts[key]?["mode"] as? String ?? "still") == "still"
        }
        let elapsed = ContinuousClock.now - started
        return ["bot": bot.name, "during": during.merging(["frames_advanced": lastFrame - firstFrame, "frame_advancing": lastFrame > firstFrame]) { $1 },
                "after": ["mode": UISmokeProbe.avatarFacts[key]?["mode"] ?? NSNull(), "clock_running": BotAvatarClock.shared.isRunning,
                          "stopped_within_budget": stopped,
                          "seconds": Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18] as [String: Any]]
    }

    private static func clock() -> [String: Any] {
        ["clock_running": BotAvatarClock.shared.isRunning, "live_views": UISmokeProbe.liveAvatarViews]
    }

    private static func facts(prefix: String) -> [[String: Any]] {
        UISmokeProbe.avatarFacts.filter { $0.key.hasPrefix(prefix) }.sorted { $0.key < $1.key }.map(\.value)
    }
}
