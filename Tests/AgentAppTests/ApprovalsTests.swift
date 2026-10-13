import Foundation
import Testing
@testable import AgentApp

@Test func approvalKeepsHermesRunIdentity() throws {
    let botID = UUID()
    let value = ApprovalRequest(id: UUID(), title: "Approve", summary: "command", draft: nil, command: "command", runID: "run-1", requestID: "req-1", botID: botID, profile: "research", sessionID: "session-1")
    let restored = try JSONDecoder().decode(ApprovalRequest.self, from: JSONEncoder().encode(value))
    #expect(restored.runID == "run-1")
    #expect(restored.requestID == "req-1")
    #expect(restored.botID == botID)
    #expect(restored.profile == "research")
    #expect(restored.sessionID == "session-1")
    #expect(restored.hasKnownCommand)
    #expect(!ApprovalRequest(id: UUID(), title: "Unknown", summary: "Command unknown", draft: nil).hasKnownCommand)
}

@Test func approvalRulesMatchInOrderWithWildcards() {
    let broad = ApprovalRule(name: "Broad", actionPattern: "read*", commandPattern: "*", outcome: .ask)
    let narrow = ApprovalRule(name: "Narrow", actionPattern: "read_file", commandPattern: "*/Public/?otes.txt", outcome: .allow)
    #expect(broad.matches(action: "READ_FILE", command: "/tmp/secret"))
    #expect(narrow.matches(action: "read_file", command: "/Users/me/Public/Notes.txt"))
    #expect(!narrow.matches(action: "delete_file", command: "/Users/me/Public/Notes.txt"))
    #expect([broad, narrow].first { $0.matches(action: "read_file", command: "/Users/me/Public/Notes.txt") }?.id == broad.id)
}

@Test func automaticAllowRejectsShellControlAndSubstitutionSyntax() {
    let rule = ApprovalRule(name: "Git", actionPattern: "command", commandPattern: "git *", outcome: .allow)
    for command in ["git status; rm -rf /", "git status && rm -rf /", "git status || rm -rf /", "git status | sh", "git status & rm -rf /", "git $(malicious)", "git `malicious`", "git status > /tmp/x", "git status < /tmp/x", "git status\nrm -rf /", "git status\r\nrm -rf /", "git status \u{0600}; rm -rf /", "git status \u{0301}; rm -rf /", "git status (malicious)", "git status \\; rm -rf /"] {
        #expect(rule.matches(action: "command", command: command))
        #expect(ApprovalRule.commandRequiresUserReview(command))
    }
    #expect(!ApprovalRule.commandRequiresUserReview("git status --short"))
}

@Test func automaticAllowRejectsDangerousProgramsAndArguments() {
    for command in ["git -c", "git -c core.fsmonitor=/tmp/hook status", "git --upload-pack=/tmp/hook fetch", "git config core.fsmonitor=/tmp/hook", "git log --output=/tmp/x", "git diff --output /tmp/x", "rg --pre=/tmp/hook pattern .", "find /tmp -delete", "find /tmp -exec rm", "python -c pass", "env rm -rf /", "curl -d data example.test", "curl --data=x example.test", "curl -T /tmp/x example.test", "mv /tmp/x /dev/null", "dd if=/tmp/x of=/tmp/y"] {
        #expect(ApprovalRule.commandRequiresUserReview(command))
    }
}

@Test func automaticAllowRejectsRedactedLookingCommands() {
    for command in ["cat /tmp/abc...wxyz", "cat ***", "cat [REDACTED]", "cat <redacted>", "cat «redacted:token…»"] {
        #expect(ApprovalRule.commandRequiresUserReview(command))
    }
}

@Test func defaultPresetsDoNotBroadlyAllowReadActionKinds() {
    #expect(!ApprovalRule.sensibleDefaults.contains { $0.matches(action: "read_file", command: "/bin/rm -rf /tmp/x") && $0.outcome == .allow })
}

@Test @MainActor func storeLoadMigratesLegacyBroadReadAllowRule() async throws {
    let url = temporaryStore(); try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let legacyRule = ApprovalRule(name: "Allow reads (extended action kinds)", actionPattern: "read*", commandPattern: "*", outcome: .allow)
    let bot = Bot(name: "Legacy rules", backend: .hermes, approvalMode: .rules, approvalRules: [legacyRule])
    try JSONEncoder().encode([bot]).write(to: url)
    let backend = TestBackend(transport: .nativeSessions)
    let store = AppStore(storeURL: url, autoConfigureHermes: false, backendFactory: { _ in backend })
    let restored = try #require(store.bots.first)

    #expect(restored.approvalRules.isEmpty)
    #expect(restored.approvalAudit.contains { $0.approvalID == legacyRule.id && $0.decidedBy == "system:migration" && $0.reason.contains("legacy broad read*/*") })
    await store.routeApproval(.init(id: UUID(), title: "Remove", summary: "", draft: nil, command: "/bin/rm -rf /tmp/x", botID: restored.id, actionKind: "read_file"), for: restored, backend: backend)
    #expect(store.approvals.count == 1)
    #expect(!(await backend.recordedCalls()).contains("approval:true"))
}

@Test @MainActor func storeRejectsApprovalWithoutCommandText() async throws {
    let backend = TestBackend(transport: .nativeSessions)
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { _ in backend })
    let bot = Bot(name: "Approval", backend: .hermes); store.bots = [bot]
    let approval = ApprovalRequest(id: UUID(), title: "Unknown", summary: "Command unknown", draft: nil, botID: bot.id)

    store.decide(approval, approved: true)
    await Task.yield()

    #expect(!(await backend.recordedCalls()).contains { $0.hasPrefix("approval:") })
    #expect(store.errorMessage?.contains("without command text") == true)
}


@Test @MainActor func ruleAutoApprovesAndAuditPersistsWithoutCommand() async throws {
    let url = temporaryStore()
    let backend = TestBackend(transport: .nativeSessions, streamMode: .approvalThenFinish)
    let store = AppStore(storeURL: url, autoConfigureHermes: false, backendFactory: { _ in backend })
    let bot = Bot(name: "Rules", backend: .hermes, hermesSessionID: "s1")
    bot.approvalMode = .rules; bot.approvalRules = [.init(name: "Test allow", actionPattern: "command", commandPattern: "cat /tmp/x", outcome: .allow)]
    store.bots = [bot]; store.selectedBot = bot; store.send(text: "go")
    try await waitUntil { await backend.recordedCalls().contains("approval:true") }
    #expect(store.approvals.isEmpty)
    #expect(bot.approvalAudit.map(\.outcome).contains(.requested)); #expect(bot.approvalAudit.map(\.outcome).contains(.approved))
    store.save()
    let restored = AppStore(storeURL: url, autoConfigureHermes: false)
    let audit = try #require(restored.bots.first?.approvalAudit)
    #expect(audit.count >= 2); #expect(!String(data: try JSONEncoder().encode(audit), encoding: .utf8)!.contains("/tmp/x"))
}

@Test @MainActor func unsafeAllowRuleFallsBackToAsk() async {
    let backend = TestBackend(transport: .nativeSessions)
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { _ in backend })
    let bot = Bot(name: "Rules", backend: .hermes); bot.approvalMode = .rules
    bot.approvalRules = [.init(name: "Git", actionPattern: "command", commandPattern: "git *", outcome: .allow)]
    store.bots = [bot]
    let request = ApprovalRequest(id: UUID(), title: "Injected", summary: "", draft: nil, command: "git status; rm -rf /", botID: bot.id)
    await store.routeApproval(request, for: bot, backend: backend)
    #expect(store.approvals.map(\.id).contains(request.id)); #expect(!(await backend.recordedCalls()).contains("approval:true"))
}

@Test @MainActor func defaultPresetsRejectCRLFInjectionAtStoreBoundary() async {
    let backend = TestBackend(transport: .nativeSessions)
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { _ in backend })
    let bot = Bot(name: "Rules", backend: .hermes); bot.approvalMode = .rules; store.bots = [bot]
    for command in ["cat /tmp/x\r\nrm -rf ~", "git status\r\nrm -rf ~"] {
        let request = ApprovalRequest(id: UUID(), title: "Injected", summary: "", draft: nil, command: command, botID: bot.id)
        await store.routeApproval(request, for: bot, backend: backend)
        #expect(store.approvals.contains { $0.id == request.id })
    }
    #expect(!(await backend.recordedCalls()).contains("approval:true"))
}

@Test @MainActor func denyRuleResolvesAndNoMatchAsks() async {
    let backend = TestBackend(transport: .nativeSessions)
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { _ in backend })
    let bot = Bot(name: "Rules", backend: .hermes); bot.approvalMode = .rules
    bot.approvalRules = [.init(name: "Deny rm", actionPattern: "command", commandPattern: "rm *", outcome: .deny)]
    store.bots = [bot]
    let denied = ApprovalRequest(id: UUID(), title: "Delete", summary: "", draft: nil, command: "rm /tmp/x", botID: bot.id)
    await store.routeApproval(denied, for: bot, backend: backend)
    let unmatched = ApprovalRequest(id: UUID(), title: "Other", summary: "", draft: nil, command: "git status", botID: bot.id)
    await store.routeApproval(unmatched, for: bot, backend: backend)
    #expect((await backend.recordedCalls()).contains("approval:false")); #expect(store.approvals.map(\.id).contains(unmatched.id))
}

@Test @MainActor func reviewerApproveDenyErrorAndTimeoutRoutesSafely() async {
    for (mode, expectedApproval) in [(TestBackend.StreamMode.response("approve"), true), (.response("deny"), false)] {
        let ownerBackend = TestBackend(transport: .nativeSessions)
        let reviewerBackend = TestBackend(transport: .nativeSessions, streamMode: mode)
        let owner = Bot(name: "Owner", backend: .hermes); let reviewer = Bot(name: "Reviewer", backend: .hermes)
        owner.approvalMode = .reviewer; owner.reviewerBotID = reviewer.id
        let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { $0.id == reviewer.id ? reviewerBackend : ownerBackend })
        store.bots = [owner, reviewer]
        await store.routeApproval(.init(id: UUID(), title: "Review", summary: "cat", draft: nil, command: "cat /tmp/x", botID: owner.id), for: owner, backend: ownerBackend)
        #expect((await ownerBackend.recordedCalls()).contains("approval:\(expectedApproval)"))
        #expect((await reviewerBackend.recordedCalls()).contains { $0.hasPrefix("create:agentapp_review_") })
    }
    for mode in [TestBackend.StreamMode.failure, .hanging] {
        let ownerBackend = TestBackend(transport: .nativeSessions); let reviewerBackend = TestBackend(transport: .nativeSessions, streamMode: mode)
        let owner = Bot(name: "Owner", backend: .hermes); let reviewer = Bot(name: "Reviewer", backend: .hermes)
        owner.approvalMode = .reviewer; owner.reviewerBotID = reviewer.id
        let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { $0.id == reviewer.id ? reviewerBackend : ownerBackend }, reviewerTimeout: .milliseconds(10))
        store.bots = [owner, reviewer]
        await store.routeApproval(.init(id: UUID(), title: "Review", summary: "cat", draft: nil, command: "cat /tmp/x", botID: owner.id), for: owner, backend: ownerBackend)
        #expect(store.approvals.count == 1); #expect(!(await ownerBackend.recordedCalls()).contains { $0.hasPrefix("approval:") })
        if case .hanging = mode { #expect((await reviewerBackend.recordedCalls()).contains("post")) }
    }
}

@Test @MainActor func reviewerUsesMockRoutingAndDestructiveFloor() async {
    let ownerBackend = TestBackend(transport: .nativeSessions); let mockReviewerBackend = TestBackend(transport: .nativeSessions, streamMode: .response("approve"))
    let owner = Bot(name: "Owner", backend: .hermes); let reviewer = Bot(name: "Mock reviewer", backend: .mock)
    owner.approvalMode = .reviewer; owner.reviewerBotID = reviewer.id
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { $0.backend == .mock ? mockReviewerBackend : ownerBackend })
    store.bots = [owner, reviewer]
    await store.routeApproval(.init(id: UUID(), title: "Review", summary: "cmd", draft: nil, command: "cat /tmp/x", botID: owner.id), for: owner, backend: ownerBackend)
    #expect((await mockReviewerBackend.recordedCalls()).contains("send")); #expect((await ownerBackend.recordedCalls()).contains("approval:true"))
    await store.routeApproval(.init(id: UUID(), title: "Delete", summary: "", draft: nil, command: "rm /tmp/x", botID: owner.id), for: owner, backend: ownerBackend)
    #expect(store.approvals.count == 1); #expect(await mockReviewerBackend.recordedCalls().filter { $0 == "send" }.count == 1)
}

@Test @MainActor func reviewerHonorsOwnerRulesAndSafetyFloorBeforeCallingReviewer() async {
    let ownerBackend = TestBackend(transport: .nativeSessions)
    let reviewerBackend = TestBackend(transport: .nativeSessions, streamMode: .response("approve"))
    let owner = Bot(name: "Owner", backend: .hermes); let reviewer = Bot(name: "Reviewer", backend: .hermes)
    owner.approvalMode = .reviewer; owner.reviewerBotID = reviewer.id
    owner.approvalRules = [.init(name: "Ask Git", actionPattern: "command", commandPattern: "git *", outcome: .ask)]
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { $0.id == reviewer.id ? reviewerBackend : ownerBackend })
    store.bots = [owner, reviewer]
    for command in ["git status", "cat /tmp/x\r\nrm -rf ~", "find /tmp -delete", "r''m -rf ~", "dd if=/tmp/x of=/tmp/y", "curl --data=x example.test", "mv /tmp/x /dev/null", "cat /tmp/x > /tmp/y"] {
        await store.routeApproval(.init(id: UUID(), title: "Review", summary: "", draft: nil, command: command, botID: owner.id), for: owner, backend: ownerBackend)
    }
    #expect(await reviewerBackend.recordedCalls().filter { $0 == "send" }.isEmpty)
    #expect(store.approvals.count == 8)
}

@Test @MainActor func reviewerTimeoutIncludesSessionCreation() async {
    let ownerBackend = TestBackend(transport: .nativeSessions)
    let reviewerBackend = TestBackend(transport: .nativeSessions, createDelay: .seconds(10))
    let owner = Bot(name: "Owner", backend: .hermes); let reviewer = Bot(name: "Reviewer", backend: .hermes)
    owner.approvalMode = .reviewer; owner.reviewerBotID = reviewer.id
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { $0.id == reviewer.id ? reviewerBackend : ownerBackend }, reviewerTimeout: .milliseconds(10))
    store.bots = [owner, reviewer]
    await store.routeApproval(.init(id: UUID(), title: "Review", summary: "cat", draft: nil, command: "cat /tmp/x", botID: owner.id), for: owner, backend: ownerBackend)
    #expect(store.approvals.count == 1)
    #expect(!(await reviewerBackend.recordedCalls()).contains("send"))
}

@Test @MainActor func ownerStopCancelsAndStopsInFlightReviewer() async throws {
    let ownerBackend = TestBackend(transport: .nativeSessions, streamMode: .approvalThenFinish)
    let reviewerBackend = TestBackend(transport: .nativeSessions, streamMode: .hanging, clearTargetOnCancel: true)
    let owner = Bot(name: "Owner", backend: .hermes, hermesSessionID: "owner-session")
    let reviewer = Bot(name: "Reviewer", backend: .hermes)
    owner.approvalMode = .reviewer; owner.reviewerBotID = reviewer.id
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { $0.id == reviewer.id ? reviewerBackend : ownerBackend }, reviewerTimeout: .seconds(10))
    store.bots = [owner, reviewer]; store.selectedBot = owner; store.send(text: "go")
    try await waitUntil { await reviewerBackend.recordedCalls().contains("send") }
    store.stop()
    try await waitUntil { await reviewerBackend.recordedCalls().contains("post") }
    #expect(await reviewerBackend.recordedCalls().contains("capture"))
    #expect(await reviewerBackend.recordedCalls().contains("post:run-1"))
}

@Test @MainActor func approvalAuditIsCappedAtFiveHundredEntries() async {
    let backend = TestBackend(transport: .nativeSessions)
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { _ in backend })
    let bot = Bot(name: "Audit", backend: .hermes); store.bots = [bot]
    for index in 0..<260 {
        await store.routeApproval(.init(id: UUID(), title: "\(index)", summary: "cmd", draft: nil, command: "cmd", botID: bot.id), for: bot, backend: backend)
    }
    #expect(bot.approvalAudit.count == 500)
}

@Test @MainActor func reviewerEscalationFallsBackToUser() async throws {
    let ownerBackend = TestBackend(transport: .nativeSessions, streamMode: .approvalThenFinish)
    let reviewerBackend = TestBackend(transport: .nativeSessions, streamMode: .response("escalate"))
    let owner = Bot(name: "Owner", backend: .hermes, hermesSessionID: "owner")
    let reviewer = Bot(name: "Reviewer", backend: .hermes, hermesSessionID: "reviewer")
    owner.approvalMode = .reviewer; owner.reviewerBotID = reviewer.id
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { $0.id == reviewer.id ? reviewerBackend : ownerBackend })
    store.bots = [owner, reviewer]; store.selectedBot = owner; store.send(text: "go")
    try await waitUntil { store.approvals.count == 1 }
    #expect(owner.approvalAudit.contains { $0.outcome == .asked && $0.decidedBy == "reviewer:\(reviewer.id.uuidString)" })
    #expect(!(await ownerBackend.recordedCalls()).contains("approval:true"))
}

@Test @MainActor func reviewerApprovalRequestEscalatesAndSelfReviewIsGuarded() async throws {
    let ownerBackend = TestBackend(transport: .nativeSessions, streamMode: .approvalThenFinish)
    let reviewerBackend = TestBackend(transport: .nativeSessions, streamMode: .reviewerApproval)
    let owner = Bot(name: "Owner", backend: .hermes, hermesSessionID: "owner")
    let reviewer = Bot(name: "Reviewer", backend: .hermes)
    owner.approvalMode = .reviewer; owner.reviewerBotID = reviewer.id
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { $0.id == reviewer.id ? reviewerBackend : ownerBackend })
    store.bots = [owner, reviewer]; store.selectedBot = owner; store.send(text: "go")
    try await waitUntil { store.approvals.count == 1 }
    #expect(owner.approvalAudit.contains { $0.reason.contains("escalated") })
    #expect(await reviewerBackend.recordedCalls().contains("approval:false"))
    #expect(await reviewerBackend.recordedCalls().contains("post"))

    let secondBackend = TestBackend(transport: .nativeSessions, streamMode: .approvalThenFinish)
    let selfReview = Bot(name: "Self", backend: .hermes, hermesSessionID: "self"); selfReview.approvalMode = .reviewer; selfReview.reviewerBotID = selfReview.id
    let secondStore = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { _ in secondBackend })
    secondStore.bots = [selfReview]; secondStore.selectedBot = selfReview; secondStore.send(text: "go")
    try await waitUntil { secondStore.approvals.count == 1 }
    #expect(selfReview.approvalAudit.contains { $0.reason.contains("review itself") })
    #expect(await secondBackend.recordedCalls().filter { $0 == "send" }.count == 1)
}

@Test @MainActor func approvalIsScopedAndClearedAtRunEnd() async throws {
    let backend = TestBackend(transport: .nativeSessions, streamMode: .approvalThenFinish)
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { _ in backend })
    let first = Bot(name: "First", backend: .hermes, hermesProfile: "research", hermesSessionID: "s1")
    let second = Bot(name: "Second", backend: .hermes, hermesSessionID: "s2")
    store.bots = [first, second]; store.selectedBot = first; store.send(text: "go")
    try await waitUntil { store.approvals.count == 1 }
    #expect(store.approvals.count == 1); #expect(store.approvals.first?.botID == first.id)
    #expect(store.approvals.first?.profile == "research"); #expect(store.approvals.first?.sessionID == "s1")
    try await waitUntil { store.approvals.isEmpty }; #expect(store.approvals.isEmpty)
}

