import Foundation
import Testing
@testable import AgentApp

/// P37 D1–D3: routing lines, SwarmHub-wide lines, migration of the P8 modes, rails, audit.
@MainActor private func routingStore(_ bots: [Bot], reviewer: Bot? = nil, reviewerBackend: TestBackend? = nil, timeout: Duration = waitCeiling) -> (AppStore, TestBackend) {
    let ownerBackend = TestBackend(transport: .nativeSessions)
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { bot in bot.id == reviewer?.id ? (reviewerBackend ?? ownerBackend) : ownerBackend },
                         reviewerTimeout: timeout, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    store.bots = bots + (reviewer.map { [$0] } ?? [])
    return (store, ownerBackend)
}

private func request(_ command: String?, bot: Bot, action: String = "command") -> ApprovalRequest {
    ApprovalRequest(id: UUID(), title: "Run", summary: command ?? "unknown", draft: nil, command: command, botID: bot.id, actionKind: action)
}

private func legacyBot(_ mode: ApprovalMode, rules: [ApprovalRule], reviewer: UUID?) throws -> Bot {
    let bot = Bot(name: "Legacy", backend: .hermes, approvalMode: mode, approvalRules: rules, reviewerBotID: reviewer)
    // A store written before P37: no approvalRouting key at all.
    var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(bot)) as? [String: Any])
    #expect(json["approvalRouting"] == nil && json["reviewAfter"] == nil, "an untouched bot encodes as before")
    json["approvalRouting"] = nil
    return try JSONDecoder().decode(Bot.self, from: JSONSerialization.data(withJSONObject: json))
}

@Test func migrationOfTheThreeOldModesIsLossless() throws {
    let reviewerID = UUID()
    let allow = ApprovalRule(name: "Allow ls", actionPattern: "command", commandPattern: "ls *", outcome: .allow)
    let ask = ApprovalRule(name: "Ask git", actionPattern: "*", commandPattern: "git *", outcome: .ask)
    let deny = ApprovalRule(name: "Deny rm", actionPattern: "command", commandPattern: "rm *", outcome: .deny)

    let askBot = try legacyBot(.ask, rules: [allow], reviewer: nil)
    #expect(askBot.approvalRouting == nil && askBot.effectiveRouting.lines.isEmpty && askBot.effectiveRouting.otherwise.decision == .ask)
    #expect(askBot.approvalRules == [allow], "the old rules stay stored")

    let rulesBot = try legacyBot(.rules, rules: [allow, ask, deny], reviewer: nil)
    #expect(rulesBot.effectiveRouting.lines.map(\.decision) == [.approve, .ask, .deny])
    #expect(rulesBot.effectiveRouting.lines.map(\.id) == [allow.id, ask.id, deny.id], "audit ids rule:<id> stay the same")
    #expect(rulesBot.effectiveRouting.lines.map(\.legacyActionPattern) == ["command", "*", "command"])
    #expect(rulesBot.effectiveRouting.otherwise.decision == .ask)

    let reviewerBot = try legacyBot(.reviewer, rules: [allow, ask, deny], reviewer: reviewerID)
    let lines = reviewerBot.effectiveRouting.lines
    #expect(lines.map(\.decision) == [.reviewer, .ask, .ask, .reviewer], "allow rules went to the reviewer; ask/deny rules asked")
    #expect(lines.last?.kind == .any && lines.last?.commandPattern == "" && lines.last?.reviewerID == reviewerID)

    // Old fixture stores still load and route as Ask me.
    let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "Fixtures")
    let fixture = try Data(contentsOf: fixtures.appending(path: "legacy_store_without_template_import_fields.json"))
    let bots = try StoreFile.decode(fixture).bots
    #expect(!bots.isEmpty && bots.allSatisfy { $0.approvalRouting == nil && $0.effectiveRouting == ApprovalRouting() })

    // Edited lines round-trip; the global lists live in the store file.
    let edited = Bot(name: "Edited", backend: .hermes)
    edited.approvalRouting = ApprovalRouting(lines: [ApprovalRoute(kind: .botMessage, targetBot: "infra", decision: .reviewer, reviewerID: reviewerID)], otherwise: .anything(.deny))
    edited.reviewAfter = [ReviewAfterRule(trigger: .codingJob, reviewerID: reviewerID, autoSendNotes: true)]
    let restored = try JSONDecoder().decode(Bot.self, from: JSONEncoder().encode(edited))
    #expect(restored.approvalRouting == edited.approvalRouting && restored.reviewAfter == edited.reviewAfter)
    let file = StoreFile(bots: [], groups: [], approvalRoutes: [.anything(.reviewer, reviewer: reviewerID)], reviewAfter: [ReviewAfterRule(reviewerID: reviewerID)])
    let decoded = try StoreFile.decode(JSONEncoder().encode(file))
    #expect(decoded.approvalRoutes == file.approvalRoutes && decoded.reviewAfter == file.reviewAfter)
    #expect(!(String(decoding: try JSONEncoder().encode(StoreFile(bots: [], groups: [])), as: UTF8.self)).contains("approvalRoutes"))
}

@Test @MainActor func migratedStoreLoadsIntoTheAppAndKeepsTheGlobalLines() throws {
    let url = temporaryStore(); try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let jarvis = Bot(name: "Jarvis", backend: .hermes), coder = Bot(name: "Coder", backend: .hermes, approvalMode: .reviewer, reviewerBotID: jarvis.id)
    try JSONEncoder().encode(StoreFile(bots: [coder, jarvis], groups: [], approvalRoutes: [.anything(.reviewer, reviewer: jarvis.id)])).write(to: url)
    let store = AppStore(storeURL: url, autoConfigureHermes: false, backendFactory: { _ in TestBackend(transport: .nativeSessions) }, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    #expect(store.globalApprovalRoutes.first?.reviewerID == jarvis.id)
    #expect(store.bots.first { $0.name == "Coder" }?.effectiveRouting.lines.last?.reviewerID == jarvis.id)
}

@Test func matchingKindsWildcardsAndTargetBot() {
    func facts(_ command: String, _ action: String = "command") -> ApprovalFacts { ApprovalFacts(action: action, command: command) { $0 == "grok-infra" ? "Infra" : nil } }
    let push = ApprovalRoute(kind: .command, commandPattern: "git push*", decision: .ask)
    #expect(push.matches(facts("git push origin main")) && !push.matches(facts("git status")))
    let deploy = ApprovalRoute(kind: .any, commandPattern: "*deploy*", decision: .deny)
    #expect(deploy.matches(facts("make deploy-prod")) && !deploy.matches(facts("make build")))
    #expect(ApprovalRoute(kind: .command, commandPattern: "rm -rf*", decision: .ask).matches(facts("RM -RF /tmp/x")), "case-insensitive")

    let bm = "/home/u/.hermes/skills/bot-msg --from coder --to grok-infra -- hello"
    #expect(facts(bm).kinds.isSuperset(of: [.botMessage, .command]))
    let toInfra = ApprovalRoute(kind: .botMessage, targetBot: "grok-infra", decision: .approve)
    #expect(toInfra.matches(facts(bm)))
    #expect(ApprovalRoute(kind: .botMessage, targetBot: "Infra", decision: .approve).matches(facts(bm)), "the bot's name works too")
    #expect(!toInfra.matches(facts("bot-msg --to coder -- hi")), "another recipient")
    #expect(!ApprovalRoute(kind: .any, targetBot: "grok-infra", decision: .approve).matches(facts("ls /tmp")), "a target needs a bot message")

    #expect(facts("code-job --bot coder --order claude -- fix").kinds.contains(.codingJob))
    #expect(!facts("rm -rf /tmp/code-job").kinds.contains(.codingJob), "kinds come from the program, not from text in the command")
    #expect(!facts("rm /tmp/bot-msg --to grok-infra").kinds.contains(.botMessage))
    // Fail closed: a wrapped program still meets Ask/Deny lines of its kind, never Approve/Reviewer lines.
    #expect(ApprovalRoute(kind: .codingJob, decision: .deny).matches(facts("env code-job --bot x -- go")))
    #expect(!ApprovalRoute(kind: .codingJob, decision: .approve).matches(facts("env code-job --bot x -- go")))
    #expect(ApprovalRoute(kind: .botMessage, targetBot: "Infra", decision: .ask).matches(facts("nohup bot-msg --to grok-infra -- hi")))
    #expect(!ApprovalRoute(kind: .botMessage, targetBot: "Infra", decision: .reviewer).matches(facts("nohup bot-msg --to grok-infra -- hi")))
    #expect(facts("hermes skills install swarmhub-coding").kinds.contains(.skillInstall))
    #expect(facts("", "write_file").kinds.contains(.fileWrite) && facts("curl https://x.test").kinds.contains(.network))
    #expect(facts("", "delegate_task").kinds.contains(.delegate) && facts("", "mystery").kinds == [.other])
    #expect(ApprovalRoute(kind: .fileWrite, decision: .ask).matches(facts("notes.md", "patch")))
}

@Test @MainActor func firstMatchWinsAndGlobalLinesComeAfterTheBotsOwn() async {
    let bot = Bot(name: "Coder", backend: .hermes)
    bot.approvalRouting = ApprovalRouting(lines: [ApprovalRoute(kind: .command, commandPattern: "cat *", decision: .approve),
                                                  ApprovalRoute(kind: .command, commandPattern: "cat /tmp/*", decision: .deny)])
    let (store, backend) = routingStore([bot])
    store.globalApprovalRoutes = [ApprovalRoute(kind: .command, commandPattern: "ls *", decision: .deny), .anything(.approve)]
    await store.routeApproval(request("cat /tmp/x", bot: bot), for: bot, backend: backend)
    #expect(await backend.recordedCalls().filter { $0 == "approval:true" }.count == 1, "the first bot line wins over the second")
    await store.routeApproval(request("ls /tmp", bot: bot), for: bot, backend: backend)
    #expect(await backend.recordedCalls().contains("approval:false"), "a global line applies when no bot line matches")
    #expect(bot.approvalAudit.last?.rule?.hasPrefix("All bots line 1") == true)
    await store.routeApproval(request("wc -l notes.md", bot: bot), for: bot, backend: backend)
    #expect(await backend.recordedCalls().filter { $0 == "approval:true" }.count == 2, "the global catch-all runs before the bot's anything-else line")

    // A bot's own ask line beats a global approve.
    bot.approvalRouting?.lines.insert(ApprovalRoute(kind: .command, commandPattern: "pwd", decision: .ask), at: 0)
    await store.routeApproval(request("pwd", bot: bot), for: bot, backend: backend)
    #expect(store.approvals.count == 1 && store.approvals[0].rule?.hasPrefix("Bot line 1") == true)
}

@Test @MainActor func aReviewerNeverReviewsItsOwnRequests() async throws {
    let jarvis = Bot(name: "Jarvis", backend: .hermes), coder = Bot(name: "Coder", backend: .hermes)
    let reviewerBackend = TestBackend(transport: .nativeSessions, streamMode: .response("approve"))
    let (store, backend) = routingStore([coder], reviewer: jarvis, reviewerBackend: reviewerBackend)
    store.globalApprovalRoutes = [.anything(.reviewer, reviewer: jarvis.id)]
    // Coder's request goes to Jarvis.
    await store.routeApproval(request("cat /tmp/x", bot: coder), for: coder, backend: backend)
    #expect(await reviewerBackend.recordedCalls().contains("send"))
    #expect(coder.approvalAudit.contains { $0.outcome == .approved && $0.decidedBy == "reviewer:\(jarvis.id.uuidString)" && $0.rule == "All bots line 1: Anything → Reviewer: Jarvis" })
    let card = try #require(coder.messages.last)
    #expect(card.presentation == .approvalDecision && card.metadata[ApprovalCardKey.decider] == jarvis.id.uuidString && card.metadata[ApprovalCardKey.rule]?.contains("Reviewer: Jarvis") == true)

    // Jarvis's own request falls through to its next line (here: anything else → Ask me), never to itself.
    let sends = await reviewerBackend.recordedCalls().filter { $0 == "send" }.count
    await store.routeApproval(request("cat /tmp/y", bot: jarvis), for: jarvis, backend: reviewerBackend)
    #expect(await reviewerBackend.recordedCalls().filter { $0 == "send" }.count == sends)
    #expect(store.approvals.count == 1 && jarvis.approvalAudit.contains { $0.reason.contains("review itself") })

    // With a later Approve line, the fall-through lands there.
    jarvis.approvalRouting = ApprovalRouting(lines: [.anything(.reviewer, reviewer: jarvis.id), ApprovalRoute(kind: .command, commandPattern: "cat *", decision: .approve)])
    store.globalApprovalRoutes = []
    await store.routeApproval(request("cat /tmp/z", bot: jarvis), for: jarvis, backend: reviewerBackend)
    #expect(await reviewerBackend.recordedCalls().contains("approval:true"))
}

@Test @MainActor func railsWinOverAnyLine() async {
    let bot = Bot(name: "Coder", backend: .hermes), jarvis = Bot(name: "Jarvis", backend: .hermes)
    let reviewerBackend = TestBackend(transport: .nativeSessions, streamMode: .response("approve"))
    let (store, backend) = routingStore([bot], reviewer: jarvis, reviewerBackend: reviewerBackend)
    // Approve everything: unknown, shell-syntax and unsafe commands still ask.
    store.globalApprovalRoutes = [.anything(.approve)]
    for command in [nil, "cat /tmp/x; rm -rf ~", "cat $(whoami)", "ls > /tmp/out", "bash -c ls", "git push --force"] {
        await store.routeApproval(request(command, bot: bot), for: bot, backend: backend)
    }
    let ownerCalls = await backend.recordedCalls()
    #expect(store.approvals.count == 6 && !ownerCalls.contains("approval:true"))
    // A reviewer never sees destructive or unparseable commands.
    store.approvals.removeAll(); store.globalApprovalRoutes = [.anything(.reviewer, reviewer: jarvis.id)]
    for command in ["rm /tmp/x", "git push origin main", "cat /tmp/x > /tmp/y", "curl --data=x example.test"] {
        await store.routeApproval(request(command, bot: bot), for: bot, backend: backend)
    }
    let reviewerCalls = await reviewerBackend.recordedCalls()
    #expect(store.approvals.count == 4 && reviewerCalls.filter { $0 == "send" }.isEmpty)
    #expect(store.approvals.allSatisfy { $0.routeNote == "Unsafe, destructive, or unparseable operations always require user review." && $0.rule != nil })
}

@Test @MainActor func reviewerTimeoutAsksAndIsAudited() async {
    let bot = Bot(name: "Coder", backend: .hermes), jarvis = Bot(name: "Jarvis", backend: .hermes)
    let reviewerBackend = TestBackend(transport: .nativeSessions, streamMode: .hanging)
    let (store, backend) = routingStore([bot], reviewer: jarvis, reviewerBackend: reviewerBackend, timeout: .milliseconds(20))
    bot.approvalRouting = ApprovalRouting(lines: [ApprovalRoute(kind: .command, commandPattern: "cat *", decision: .reviewer, reviewerID: jarvis.id)])
    await store.routeApproval(request("cat /tmp/x", bot: bot), for: bot, backend: backend)
    #expect(store.approvals.count == 1 && store.approvals[0].reviewerID == jarvis.id)
    let asked = bot.approvalAudit.last
    #expect(asked?.outcome == .asked && asked?.decidedBy == "reviewer:\(jarvis.id.uuidString)" && asked?.reason.contains("timed out") == true)
    #expect(asked?.rule == "Bot line 1: Terminal command `cat *` → Reviewer: Jarvis")
}

@Test @MainActor func denyLineAndOpenClawShapedRequestsUseTheSameRouting() async {
    let bot = Bot(name: "Claw", backend: .openClaw)
    bot.approvalRouting = ApprovalRouting(lines: [ApprovalRoute(kind: .command, commandPattern: "rm *", decision: .deny)], otherwise: .anything(.ask))
    let (store, backend) = routingStore([bot])
    await store.routeApproval(request("rm /tmp/x", bot: bot, action: "command"), for: bot, backend: backend)
    #expect(await backend.recordedCalls().contains("approval:false"))
    #expect(bot.approvalAudit.last?.outcome == .denied && bot.approvalAudit.last?.decidedBy.hasPrefix("rule:") == true)
    await store.routeApproval(request("ls", bot: bot), for: bot, backend: backend)
    #expect(store.approvals.count == 1 && bot.approvalAudit.last?.rule == "Anything else: Anything → Ask me")
}
