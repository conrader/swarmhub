import Foundation
import Testing
@testable import AgentApp

// Grok routines and connector requests: mapped from `automation-changed` events and connector cards, imported inert.
// The same vectors as scripts/test_grokbot_staged.py.

private let botID = "00000000-0000-4000-8000-0000000000aa"
private let token = "FAKETOKENVALUE1234"

private func automation(_ seq: Int, _ action: String, _ id: String, _ name: String? = nil) -> String {
    let named = name.map { #","automationName":"\#($0)""# } ?? ""
    return #"{"kind":"event","id":"e\#(seq)","seq":\#(seq),"event":{"type":"automation-changed","action":"\#(action)","automationId":"\#(id)"\#(named)}}"#
}

private func connector(_ seq: Int, _ name: String? = nil) -> String {
    let named = name.map { #","connector":"\#($0)""# } ?? ""
    return #"{"kind":"send-message","id":"c\#(seq)","seq":\#(seq),"requestId":"r\#(seq)","message":{"type":"connector","serverId":"srv-SECRETSERVER9","#
        + #""variant":"connect","reauth":{"accountKey":"acct-FAKEACCOUNTKEY77"}\#(named)}}"#
}

private let entries = [
    automation(1, "created", "a1", "Morning"), automation(2, "created", "a2", "Old"), automation(3, "updated", "a1", "Morning brief"),
    automation(4, "deleted", "a2", "Old"), automation(5, "disabled", "a3", "Night"), automation(6, "enabled", "a3"),
    automation(7, "created", "a4", "Deploy Bearer \(token)"),
    #"{"kind":"event","id":"e8","seq":8,"event":{"type":"automation-changed","action":"created"}}"#,
    connector(9, "GoogleDrive"), connector(10, "google_drive"), connector(11, "googledrive"), connector(12, "Slack"),
    connector(13, "Bearer \(token)"), connector(14),
]

private func built(_ lines: [String] = entries, name: String = "Atlas") throws -> GrokBundleV1 {
    let parsed = try lines.map { try GrokJSON.parse(Data($0.utf8)) }
    let roster: [[String: JSONValue]] = [["id": .string(botID), "name": .string(name)]]
    return try #require(GrokBundleBuilder.build(roster: roster, transcripts: [botID: parsed]).bundles.first)
}

@MainActor private func makeStore(_ url: URL = temporaryStore()) -> AppStore {
    AppStore(storeURL: url, autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults(),
             hermesSession: UnreachableProtocol.session)
}

@Test func automationEventsBecomePausedRoutinesLatestStateWinsAndDeletedOnesAreLeftOut() throws {
    let bundle = try built()
    #expect(bundle.routines.map(\.id) == ["a1", "a3", "a4"].map(GrokStagedConfig.routineID))
    #expect(bundle.routines.prefix(2).map(\.name) == ["Morning brief", "Night"])
    #expect(bundle.routines[2].name.contains("[REDACTED]") && !bundle.routines[2].name.contains(token))
    #expect(GrokStagedConfig.routineID("a1") == "grok-automation-" + "f55ff16f66f43360266b95db")
    #expect(bundle.statistics.eventsDropped == 1 && bundle.statistics.droppedByKind["event/automation-changed"] == 1)
    #expect(bundle.limitations.contains(GrokBundleBuilder.routinesLimitation))
    let routines = try #require(bundle.json["routines"]?.arrayValue)
    for routine in routines {
        #expect(routine["enabled"] == .bool(false) && routine["schedule"] == .null && routine["prompt"] == .string(""))
    }
    #expect(bundle.json["memory_facts"] == .array([]))   // Grok Bot keeps no memories to import
}

@Test func connectorCardsBecomeNamesOnlyWithoutServerIDsAccountKeysOrSecrets() throws {
    let bundle = try built()
    #expect(bundle.connectors == ["googledrive", "google-drive", "slack"])
    #expect(bundle.statistics.cardsDropped == 1 && bundle.statistics.droppedByKind == ["event/automation-changed": 1, "send-message/connector": 1])
    #expect(bundle.limitations.contains(GrokBundleBuilder.connectorsLimitation))
    let text = String(decoding: try JSONEncoder().encode(bundle), as: UTF8.self)
    for secret in [token, "SECRETSERVER9", "FAKEACCOUNTKEY77", "accountKey", "serverId", #""a1""#, #""a4""#] { #expect(!text.contains(secret), "\(secret)") }
    #expect(bundle.redactions.values.reduce(0, +) >= 2)
    #expect(GrokStagedConfig.connectorName("  Google  Drive!! ") == "google-drive" && GrokStagedConfig.connectorName("--") == "")
}

@MainActor @Test func aGrokImportStagesRoutinesPausedAndConnectorsAsRequestsAndReimportNeverDuplicates() throws {
    let url = temporaryStore()
    let store = makeStore(url)
    let bundle = GrokBotBundle(try built())
    try store.importGrokBundles([bundle])
    let bot = try #require(store.bots.first { $0.grokSourceID == botID })
    #expect(bot.routines.map(\.name).prefix(2) == ["Morning brief", "Night"] && bot.routines.count == 3)
    #expect(bot.routines.allSatisfy { !$0.isEnabled && $0.importKind == .cron && $0.schedule.isEmpty && $0.prompt.isEmpty })
    #expect(bot.requestedConnectorIDs == ["googledrive", "google-drive", "slack"])
    let ids = bot.routines.map(\.id)

    // Re-import: same rows, same ids; the source renaming a routine renames its pending row.
    try store.importGrokBundles([bundle])
    #expect(bot.routines.map(\.id) == ids && bot.requestedConnectorIDs.count == 3)
    let renamed = GrokBotBundle(try built(entries + [automation(20, "updated", "a3", "Night shift")]))
    try store.importGrokBundles([renamed])
    #expect(bot.routines.map(\.id) == ids && bot.routines[1].name == "Night shift" && !bot.routines[1].isEnabled)

    // A removed routine (or one created on the server) never comes back.
    store.removePendingRoutine(bot.routines[0], from: bot)
    try store.importGrokBundles([renamed])
    #expect(bot.routines.map(\.id) == Array(ids.dropFirst()))
    #expect(store.bots.filter { $0.grokSourceID == botID }.count == 1)

    // Persisted without any secret, and the memory survives a relaunch.
    let saved = try String(contentsOf: url, encoding: .utf8)
    for secret in [token, "SECRETSERVER9", "FAKEACCOUNTKEY77"] { #expect(!saved.contains(secret), "\(secret)") }
    let reopened = try #require(makeStore(url).bots.first { $0.grokSourceID == botID })
    #expect(reopened.grokRoutineIDs.count == 3 && reopened.routines.count == 2)
}

@MainActor @Test func aBundleFileIsFilteredAgainAndItsRoutinesNeverArriveEnabled() throws {
    let store = makeStore()
    let routine = GrokBotBundle.Routine(id: "r1", name: "Ping Bearer \(token)", prompt: "Use Bearer \(token)", schedule: "0 8 * * *", enabled: true)
    var bundle = GrokBotBundle(try built([]))
    bundle.routines = [routine]
    bundle.connectors = [.init(name: "Bearer \(token)"), .init(name: "Notion"), .init(name: "notion")]
    try store.importGrokBundles([bundle])
    let bot = try #require(store.bots.first)
    let imported = try #require(bot.routines.first)
    #expect(!imported.isEnabled && imported.schedule == "0 8 * * *" && imported.name.contains("[REDACTED]") && !imported.name.contains(token))
    #expect(!imported.prompt.contains(token) && bot.requestedConnectorIDs == ["notion"])
    #expect(imported.id == AppStore.grokRoutineUUID(sourceID: botID, routineID: "r1"))
    #expect(AppStore.grokRoutineUUID(sourceID: botID, routineID: "r1") != AppStore.grokRoutineUUID(sourceID: "other", routineID: "r1"))
}

@MainActor @Test func aRoutineWithoutAScheduleIsNeverSentToTheServer() async throws {
    let store = makeStore()
    try store.importGrokBundles([GrokBotBundle(try built())])
    let bot = try #require(store.bots.first)
    let routine = try #require(bot.routines.first)
    #expect(await store.createRoutineOnServer(routine, for: bot) == "This routine needs a schedule first.")
    #expect(bot.routines.count == 3 && store.routines.state(for: bot.id).busy.isEmpty)
}

@MainActor @Test func groupsCarryNoRoutines() throws {
    let store = makeStore()
    var group = GrokBotBundle(try built())
    group.isGroup = true
    try store.importGrokBundles([group])
    #expect(store.groups.count == 1 && store.bots.allSatisfy(\.routines.isEmpty))
}
