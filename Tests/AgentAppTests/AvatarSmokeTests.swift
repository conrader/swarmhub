import AppKit
import Foundation
import Testing
@testable import AgentApp

/// P15 item 14: the `avatars` object, built from what the views reported (synthetic facts here; no window).
@MainActor @Test func avatarSmokeReportsRowsGroupsFocusAndProbes() async throws {
    _ = NSApplication.shared
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let marked = Bot(name: "Marked"); let classic = Bot(name: "Classic", avatarName: .fox)
    store.bots = [marked, classic]
    let group = GroupChat(name: "Pair", memberIDs: [marked.id, classic.id]); store.groups = [group]
    UISmokeProbe.avatarFacts["sidebar|\(marked.id)"] = AvatarFacts.facts(bot: marked, look: marked.avatarLook, mode: .still, size: 28, place: "sidebar")
    UISmokeProbe.avatarFacts["sidebar|\(classic.id)"] = AvatarFacts.facts(bot: classic, look: classic.avatarLook, mode: .still, size: 28, place: "sidebar")
    UISmokeProbe.avatarFacts["group:\(group.id)#0|\(marked.id)"] = AvatarFacts.facts(bot: marked, look: marked.avatarLook, mode: .still, size: 19.04, place: "group")
    UISmokeProbe.avatarFacts["chat_header|\(marked.id)"] = AvatarFacts.facts(bot: marked, look: marked.avatarLook, mode: .idle, size: 30, place: "chat_header")
    defer { UISmokeProbe.avatarFacts = UISmokeProbe.avatarFacts.filter { !$0.key.contains(marked.id.uuidString) && !$0.key.contains(classic.id.uuidString) } }
    let settings = AvatarMotionSettings(defaults: isolatedDefaults())
    let budget = AvatarSmoke.Budget(settle: .milliseconds(20), working: .milliseconds(600), stop: .milliseconds(200))
    let report = await AvatarSmoke.collect(store: store, bot: marked, budget: budget, settings: settings)

    #expect(report["motion_preference"] as? String == "byContext" && report["reduce_motion"] is Bool)
    let rows = try #require(report["sidebar"] as? [[String: Any]])
    #expect(rows.map { $0["name"] as? String } == ["Marked", "Classic"])
    let derived = GrokDefaultLook.mark(for: marked.avatarSeed)
    #expect(rows[0]["words"] as? String == "\(derived.shape)/\(derived.colour)" && rows[0]["origin"] as? String == "stored")
    #expect(rows[0]["body"] as? String == AvatarKitMap.body(for: derived.shape).type.rawValue && rows[0]["size"] as? Double == 28)
    #expect(rows[0]["facing"] as? String == "right" && rows[0]["scenario"] as? String == "still")
    #expect(rows[1]["origin"] as? String == "classic" && rows[1]["words"] as? String == "fox")
    let groups = try #require(report["groups"] as? [[String: Any]])
    #expect(groups.first?["name"] as? String == "Pair" && (groups.first?["marks"] as? [[String: Any]])?.count == 1)
    #expect((report["focus"] as? [[String: Any]])?.first { $0["name"] as? String == "Marked" }?["mode"] as? String == "idle")
    #expect((report["idle"] as? [String: Any])?["live_views"] is Int && (report["calm"] as? [String: Any])?["clock_running"] is Bool)
    let working = try #require(report["working"] as? [String: Any])
    #expect(working["bot"] as? String == "Marked" && working["during"] is [String: Any] && working["after"] is [String: Any])
    #expect((working["off"] as? [String: Any])?["clock_running"] is Bool)
    #expect(settings.probeOverride == nil && UISmokeProbe.forcedWorking != marked.id)
}

@MainActor @Test func forcedWorkingIsReadOnlyByIsWorking() {
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let bot = Bot(name: "Forced"), group = GroupChat(name: "G", memberIDs: [bot.id])
    #expect(!store.isWorking(bot))
    UISmokeProbe.forcedWorking = bot.id
    #expect(store.isWorking(bot) && store.isWorking(bot, in: group) && !store.isStreaming)
    UISmokeProbe.forcedWorking = nil
    #expect(!store.isWorking(bot))
}

@MainActor @Test func migratedOriginIsReported() {
    let bot = Bot(name: "M"); bot.avatarMarkMigrated = true
    #expect(AvatarFacts.origin(bot, look: bot.avatarLook) == "migrated")
}
