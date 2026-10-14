import Foundation
import Testing
@testable import AgentApp

// P16 Part 6: `--reconcile` on a synthetic store shaped like the 2026-10-13 incident.

private let first = syntheticParagraph(98, seed: 31), second = syntheticParagraph(193, seed: 32)

/// A saved store with the group "Konrad, DMT, Achilles": Achilles' reply kept only the first 100 of the box's 293 characters.
@MainActor private func incidentStore() throws -> (url: URL, keyStore: any HermesKeyStore, session: URLSession, states: [SessionServer.State]) {
    let url = temporaryStore()
    let (store, bots, states) = reconcileStore(bots: ["DMT", "Achilles"], url: url)
    let group = try #require(store.createGroup(name: "", memberIDs: bots.map(\.id)))
    let trigger = ChatMessage(role: .user, content: "how did it go"); group.messages.append(trigger)
    let replies = ["DMT reply that arrived whole", first + "\n\n" + second]
    for (index, bot) in bots.enumerated() {
        let session = GroupRouting.sessionID(group: group.id, bot: bot.id)
        group.sessions[bot.id.uuidString.lowercased()] = session
        let blob = GroupRouting.context(for: .init(id: bot.id, name: bot.name), groupName: group.name, members: store.routingMembers(of: group), messages: group.messages, current: trigger.id)
        states[index].add(session, "user", blob); states[index].add(session, "assistant", replies[index], finish: "stop")
        let kept = index == 0 ? replies[0] : first + "\n\n"
        group.messages.append(ChatMessage(role: .assistant, content: kept, authorID: bot.id))
    }
    store.save()
    return (url, store.keyStore, store.hermesSession, states)
}

@MainActor private func run(_ fixture: (url: URL, keyStore: any HermesKeyStore, session: URLSession, states: [SessionServer.State]), dryRun: Bool = false,
                            appRunning: Bool = false, beforeSwap: () -> Void = {}) async -> (Int32, [String]) {
    var lines: [String] = []
    let code = await HeadlessReconcile.reconcile(.init(dryRun: dryRun, store: fixture.url), keyStore: fixture.keyStore, session: fixture.session, defaults: isolatedDefaults(),
                                                 appIsRunning: { appRunning }, beforeSwap: beforeSwap, output: { lines.append($0) })
    return (code, lines)
}

private func backups(beside url: URL) -> [URL] {
    ((try? FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? []).filter { $0.lastPathComponent.hasPrefix("store.json.backup-reconcile-") }
}

@MainActor @Test func aDryRunPrintsTheIncidentLineAndLeavesTheBytes() async throws {
    let fixture = try incidentStore()
    let before = try Data(contentsOf: fixture.url)
    let (code, lines) = await run(fixture, dryRun: true)
    let after = try Data(contentsOf: fixture.url)
    #expect(code == 0 && after == before && backups(beside: fixture.url).isEmpty)
    #expect(lines.contains("Group Konrad, DMT, Achilles | DMT: paired 1, extended 0, added 0 | Achilles: paired 1, extended 1 (+193 chars), added 0 | read 2/2 sessions"))
    #expect(lines.last == "Dry run: nothing written (1 would change, 0 failed)")
}

@MainActor @Test func aRealRunExtendsTheRowWithABackupAndOnlyGETs() async throws {
    let fixture = try incidentStore()
    let before = try Data(contentsOf: fixture.url)
    let (code, lines) = await run(fixture)
    #expect(code == 0)
    let backup = try #require(backups(beside: fixture.url).first)
    let saved = try Data(contentsOf: backup)
    #expect(saved == before, "byte-equal backup")
    #expect(lines.last == "Reconcile: 1 changed, 0 failed, backup \(backup.lastPathComponent)")
    let healed = AppStore(storeURL: fixture.url, autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let row = try #require(healed.groups.first?.messages.last)
    #expect(row.content == first + "\n\n" + second && row.content.count == 293 && row.metadata["restored"] == "extended")
    #expect(fixture.states.allSatisfy { $0.methods == ["GET"] }, "GET only to the box")
    #expect(!lines.joined().contains(first.prefix(20)) && !lines.joined().contains("how did it go"), "no chat text in the output")
    // Idempotent: a second run changes nothing and writes no backup.
    let (again, second) = await run(fixture)
    #expect(again == 0 && second.last == "Reconcile: 0 changed, 0 failed, no backup" && backups(beside: fixture.url).count == 1)
}

@MainActor @Test func itRefusesWhileTheAppRunsAndLeavesAChangedFileAlone() async throws {
    let fixture = try incidentStore()
    let (refused, lines) = await run(fixture, appRunning: true)
    #expect(refused == 75 && lines == ["Refused: \(AppConstants.name) is running. Quit it first."])
    let (dry, _) = await run(fixture, dryRun: true, appRunning: true)
    #expect(dry == 0, "a dry run only reads a copy")
    let url = fixture.url
    let (changed, out) = await run(fixture, beforeSwap: { try? Data("{\"version\":2,\"bots\":[],\"groups\":[]}".utf8).write(to: url) })
    #expect(changed == 1 && out.last?.hasPrefix("Reconcile failed: store.json changed while it was reconciled") == true)
    let kept = try String(contentsOf: url, encoding: .utf8)
    #expect(kept == "{\"version\":2,\"bots\":[],\"groups\":[]}", "the newer file is never overwritten")
}

@Test func verificationCatchesDroppedKeysAndShrunkMessages() {
    let id = UUID().uuidString
    let old = Data("{\"version\":2,\"extra\":1,\"bots\":[{\"id\":\"b\",\"messages\":[{\"id\":\"\(id)\",\"role\":\"assistant\",\"content\":\"abc\"}]}]}".utf8)
    let grown = Data("{\"version\":2,\"extra\":1,\"bots\":[{\"id\":\"b\",\"messages\":[{\"id\":\"\(id)\",\"role\":\"assistant\",\"content\":\"abcdef\",\"turnState\":\"finished\"}]}]}".utf8)
    #expect(HeadlessReconcile.verify(old: old, new: grown) == nil)
    #expect(HeadlessReconcile.verify(old: old, new: Data("{\"version\":2,\"bots\":[{\"id\":\"b\",\"messages\":[{\"id\":\"\(id)\",\"role\":\"assistant\",\"content\":\"abc\"}]}]}".utf8)) == "key /extra would be dropped")
    #expect(HeadlessReconcile.verify(old: old, new: Data("{\"version\":2,\"extra\":1,\"bots\":[{\"id\":\"b\",\"messages\":[{\"id\":\"\(id)\",\"role\":\"assistant\",\"content\":\"ab\"}]}]}".utf8)) == "message \(id) would lose text")
    #expect(HeadlessReconcile.verify(old: old, new: Data("{\"version\":2,\"extra\":1,\"bots\":[{\"id\":\"b\",\"messages\":[]}]}".utf8))?.contains("would") == true)
}

@MainActor @Test func optionsParseAndBadFlagsAreRefused() {
    let options = HeadlessReconcile.parse(["AgentApp", "--reconcile", "--dry-run", "--bot", "DMT", "--group", "Crew", "--store", "/tmp/x.json"])
    #expect(options == .init(dryRun: true, bots: ["DMT"], groups: ["Crew"], store: URL(fileURLWithPath: "/tmp/x.json")))
    #expect(HeadlessReconcile.parse(["AgentApp", "--reconcile", "--bot"]) == nil && HeadlessReconcile.parse(["AgentApp", "--reconcile", "--wat"]) == nil)
}
