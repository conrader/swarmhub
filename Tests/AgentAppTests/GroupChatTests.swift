import Foundation
import Testing
@testable import AgentApp

/// Synthetic per-bot backend for group routing: replies with "<name> says hi" (or hangs), records each
/// created session id and every sent turn (session id + context text).
actor GroupBackend: AgentBackend {
    nonisolated let kind = BackendKind.hermes
    let name: String; let hang: Bool
    private(set) var created: [String] = []; nonisolated let sent = AwaitableLog<(session: String, text: String)>(); private(set) var stops = 0
    init(name: String, hang: Bool = false) { self.name = name; self.hang = hang }
    func sessionTransport() async throws -> HermesTransport? { .nativeSessions }
    func createSession(title: String, systemPrompt: String, id: String?) async throws -> String { created.append(id ?? "nil"); return id ?? "s" }
    func send(_ request: AgentRequest) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        sent.append((request.sessionID, request.messages.last?.content ?? ""))
        let (name, hang) = (name, hang)
        return AsyncThrowingStream { continuation in
            let task = Task {
                continuation.yield(.token(hang ? "thinking" : "\(name) says hi"))
                if hang { await hangUntilCancelled() } else { continuation.yield(.completed) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    func stopTarget(sessionID: String) async throws -> StopTarget { .serverRun("run-\(name)") }
    func requestStop(_ target: StopTarget) async throws -> StopOutcome { stops += 1; return .requested }
    func listSessions() async throws -> [BackendSession] { [] }
    func cancel(sessionID: String) async throws -> StopOutcome { .requested }
    func resolveApproval(id: UUID, approved: Bool) async throws {}
    func testConnection() async throws -> String { "ok" }
    func sessions() -> [String] { created }
    func turns() -> [(session: String, text: String)] { sent.all }
    func stopCount() -> Int { stops }
}

@MainActor private func groupStore(_ names: [String], hanging: Set<String> = [], url: URL = temporaryStore()) -> (AppStore, [Bot], [UUID: GroupBackend], GroupChat) {
    let bots = names.map { Bot(name: $0, backend: .hermes, hermesProfile: "grok-\($0.lowercased().replacingOccurrences(of: " ", with: "-"))") }
    let backends = Dictionary(uniqueKeysWithValues: bots.map { ($0.id, GroupBackend(name: $0.name, hang: hanging.contains($0.name))) })
    let store = AppStore(storeURL: url, autoConfigureHermes: false, backendFactory: { bot in backends[bot.id]! }, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    store.bots = bots
    let group = store.createGroup(name: "", memberIDs: bots.map(\.id))!
    return (store, bots, backends, group)
}

private let members: [GroupRouting.Member] = [.init(id: UUID(), name: "DMT"), .init(id: UUID(), name: "Achilles"), .init(id: UUID(), name: "Finance Controller")]

@Test func mentionsAreCaseInsensitiveAndAllowSpacesInNames() {
    let (dmt, achilles, finance) = (members[0].id, members[1].id, members[2].id)
    #expect(GroupRouting.mentions(in: "@dmt what do you think?", members: members) == [dmt])
    #expect(GroupRouting.mentions(in: "ask @finance controller, then @ACHILLES.", members: members) == [achilles, finance])
    #expect(GroupRouting.mentions(in: "(@Achilles) and @DMT: go", members: members) == [dmt, achilles], "member order, punctuation boundaries")
    #expect(GroupRouting.mentions(in: "@Bob please", members: members).isEmpty, "unknown names are not mentions")
    #expect(GroupRouting.mentions(in: "@DMTx and @Achilles2", members: members).isEmpty, "a name must end at a word boundary")
    #expect(GroupRouting.mentions(in: "mail konrad@dmt.zone or x@achilles", members: members).isEmpty, "email-like text is not a mention")
    #expect(GroupRouting.mentions(in: "@dmt.zone is a domain", members: members).isEmpty)
    #expect(GroupRouting.recipients(of: "hello all", members: members) == members.map(\.id))
    #expect(GroupRouting.recipients(of: "@Bob hello", members: members) == members.map(\.id), "an unknown mention goes to everyone")
}

@Test func composerAutocompleteFindsAndCompletesTheTypedMention() {
    #expect(GroupRouting.typedMention(in: "hey @ach") == "ach")
    #expect(GroupRouting.typedMention(in: "konrad@dm") == nil)
    #expect(GroupRouting.suggestions(for: "fin", names: members.map(\.name)) == ["Finance Controller"])
    #expect(GroupRouting.suggestions(for: "", names: members.map(\.name)).count == 3)
    #expect(GroupRouting.suggestions(for: "DMT", names: members.map(\.name)).isEmpty, "a complete name closes the popup")
    #expect(GroupRouting.complete("hey @fin", with: "Finance Controller") == "hey @Finance Controller ")
}

@Test func contextIsTheTranscriptSinceTheBotsLastReplyCapped() {
    let (dmt, achilles) = (members[0], members[1])
    let messages = [
        ChatMessage(role: .user, content: "old question"), ChatMessage(role: .assistant, content: "old DMT answer", authorID: dmt.id),
        ChatMessage(role: .assistant, content: "Achilles chimes in", authorID: achilles.id), ChatMessage(role: .system, content: "Stop requested"),
        ChatMessage(role: .user, content: "new question"),
    ]
    let context = GroupRouting.context(for: dmt, groupName: "Konrad, DMT, Achilles", members: members, messages: messages)
    let lines = context.components(separatedBy: "\n")
    #expect(lines.first?.contains("You (DMT)") == false && lines.first?.contains("you (DMT)") == true)
    #expect(Array(lines.dropFirst()) == ["Achilles: Achilles chimes in", "Konrad: new question"])
    #expect(GroupRouting.context(for: achilles, groupName: "G", members: members, messages: messages).hasSuffix("\nKonrad: new question"))

    let long = (0..<40).map { ChatMessage(role: .user, content: "line \($0) " + String(repeating: "x", count: 400)) }
    let capped = GroupRouting.context(for: dmt, groupName: "G", members: members, messages: long)
    #expect(capped.count <= GroupRouting.contextLimit && capped.contains("[… earlier messages omitted]"))
    #expect(capped.contains("Konrad: line 39 ") && !capped.contains("Konrad: line 0 "), "newest lines are kept")
    let huge = GroupRouting.context(for: dmt, groupName: "G", members: members, messages: [ChatMessage(role: .user, content: String(repeating: "y", count: 20_000))])
    #expect(huge.count <= GroupRouting.contextLimit && huge.contains("Konrad: yyy"))
}

@MainActor @Test func everyMemberAnswersInOrderInItsOwnGroupSession() async throws {
    let (store, bots, backends, group) = groupStore(["DMT", "Achilles", "Jarvis"])
    #expect(group.name == "Konrad, DMT, Achilles, Jarvis" && store.selectedGroup === group)
    #expect(store.send(text: "Morning, team", to: group))
    try await waitUntil { store.isIdle }
    #expect(group.messages.map(\.content) == ["Morning, team", "DMT says hi", "Achilles says hi", "Jarvis says hi"])
    #expect(group.messages.dropFirst().map(\.authorID) == bots.map(\.id))
    for bot in bots {
        let expected = "group-\(group.id.uuidString.lowercased())-\(bot.id.uuidString.lowercased())"
        #expect(GroupRouting.sessionID(group: group.id, bot: bot.id) == expected)
        #expect(await backends[bot.id]!.sessions() == [expected])
        #expect(await backends[bot.id]!.turns().map(\.session) == [expected])
        #expect(group.session(for: bot.id) == expected)
    }
    // Sequential: each later bot sees the earlier replies of this round in its context.
    let jarvisContext = try #require(await backends[bots[2].id]!.turns().first?.text)
    #expect(jarvisContext.hasSuffix("Konrad: Morning, team\nDMT: DMT says hi\nAchilles: Achilles says hi"))

    // A mention goes only to that bot; its context starts after its own last reply; sessions are reused.
    #expect(store.send(text: "@achilles one more thing", to: group))
    try await waitUntil { store.isIdle }
    #expect(group.messages.suffix(2).map(\.content) == ["@achilles one more thing", "Achilles says hi"])
    let (dmtTurns, jarvisTurns) = (await backends[bots[0].id]!.turns().count, await backends[bots[2].id]!.turns().count)
    #expect(dmtTurns == 1 && jarvisTurns == 1)
    let achillesTurns = await backends[bots[1].id]!.turns()
    #expect(achillesTurns.count == 2 && achillesTurns[1].text.hasSuffix("since your last reply:]\nJarvis: Jarvis says hi\nKonrad: @achilles one more thing"))
    #expect(!achillesTurns[1].text.contains("Morning, team"))
    #expect(await backends[bots[1].id]!.sessions().count == 1, "the group session is created once")
}

@MainActor @Test func stopStopsTheAnsweringBotAndSkipsTheRest() async throws {
    let (store, bots, backends, group) = groupStore(["DMT", "Achilles", "Jarvis"], hanging: ["Achilles"])
    store.send(text: "go", to: group)
    try await backends[bots[1].id]!.sent.wait { $0.count == 1 }
    #expect(store.streamingBotID == bots[1].id && group.hermesSessionID == GroupRouting.sessionID(group: group.id, bot: bots[1].id))
    store.stop()
    try await waitUntil { store.isIdle && !store.isStreaming }
    try await waitUntil { group.messages.contains { $0.role == .system && $0.content.contains("Stop requested") } }
    #expect(await backends[bots[1].id]!.stopCount() == 1)
    #expect(await backends[bots[2].id]!.turns().isEmpty, "Jarvis was skipped")
    #expect(group.messages.compactMap(\.authorID) == [bots[0].id, bots[1].id])
    #expect(store.groupRun == nil && group.activeMemberID == nil)
}

@MainActor @Test func groupsNeedTwoBotsAndMembershipCanChange() throws {
    let (store, bots, _, group) = groupStore(["DMT", "Achilles"])
    #expect(store.createGroup(name: "Solo", memberIDs: [bots[0].id, bots[0].id]) == nil)
    let extra = Bot(name: "Doc", backend: .hermes, hermesProfile: "grok-doc"); store.bots.append(extra)
    store.addMember(extra, to: group); store.addMember(extra, to: group)
    store.removeMember(bots[0].id, from: group); store.renameGroup(group, to: "  Crew ")
    #expect(group.memberIDs == [bots[1].id, extra.id] && group.name == "Crew")
    store.delete(extra)
    #expect(group.memberIDs == [bots[1].id])
}

@MainActor @Test func groupsPersistAndOldStoresStillLoad() throws {
    let url = temporaryStore()
    let (store, bots, _, group) = groupStore(["DMT", "Achilles"], url: url)
    group.messages.append(ChatMessage(role: .assistant, content: "hello", authorID: bots[0].id))
    group.sessions[bots[0].id.uuidString.lowercased()] = "group-x"; group.isMuted = true; group.manualUnread = true
    store.save()
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text.hasPrefix("{") && text.contains("\"version\":2"))
    let restored = AppStore(storeURL: url, autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let copy = try #require(restored.groups.first)
    #expect(restored.bots.count == 2 && copy.id == group.id && copy.name == group.name && copy.memberIDs == group.memberIDs)
    #expect(copy.messages.last?.authorID == bots[0].id && copy.session(for: bots[0].id) == "group-x" && copy.isMuted && copy.manualUnread)

    // Version 1: a bare array of bots, including a P6 archived Grok group → migrated to a group, same id, archive kept.
    let oldURL = temporaryStore()
    let dmt = Bot(name: "DMT", backend: .hermes, hermesProfile: "grok-dmt"), achilles = Bot(name: "Achilles", backend: .hermes, hermesProfile: "grok-achilles")
    let archived = Bot(name: "Konrad, DMT, Achilles"); archived.archivedMembers = ["DMT", "Achilles"]; archived.grokSourceID = "group-source"; archived.grokHistoryCount = 2
    try FileManager.default.createDirectory(at: oldURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode([dmt, archived, achilles]).write(to: oldURL)
    let history = GrokHistoryStore(directory: oldURL.deletingLastPathComponent().appending(path: "grok-history"))
    try history.merge([ArchivedMessage(id: "a", seq: 1, role: "user", author: "Konrad", text: "hi", timestamp: nil, hidden: false, channel: "chat", to: nil),
                       ArchivedMessage(id: "b", seq: 2, role: "assistant", author: "DMT", text: "yo", timestamp: nil, hidden: false, channel: "chat", to: nil)], sourceID: "group-source", for: archived.id)
    let migrated = AppStore(storeURL: oldURL, autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    #expect(migrated.persistenceEnabled && migrated.bots.map(\.name) == ["DMT", "Achilles"])
    let converted = try #require(migrated.groups.first)
    #expect(converted.id == archived.id && converted.name == "Konrad, DMT, Achilles" && converted.memberIDs == [dmt.id, achilles.id])
    #expect(converted.grokSourceID == "group-source" && migrated.grokHistory.messages(for: converted.id).count == 2)
    #expect(migrated.migratedGroupNames == ["Konrad, DMT, Achilles"])
    #expect(try String(contentsOf: oldURL, encoding: .utf8).contains("\"groups\""), "the migrated store is saved in the new format")
    let again = AppStore(storeURL: oldURL, autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    #expect(again.groups.count == 1 && again.migratedGroupNames.isEmpty && again.bots.count == 2)
}
