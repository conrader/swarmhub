import Foundation
import Testing
@testable import AgentApp

// P13 Part D: plain threads keep their parent's lock (fork, then lock), "Code in thread" locks the fork to the Coding
// choice and fails closed, and the Coding controls (editor, shared-supplier hint). Synthetic gateway only.

private let alpha = ModelChoice(provider: "lab-one", model: "model-alpha")!
private let beta = ModelChoice(provider: "lab-one", model: "model-beta")!
private let routed = ModelChoice(provider: "router", model: "relay/model-1")!
private let unlisted = ModelChoice(provider: "lab-one", model: "model-unlisted")!

/// Jarvis with a started main chat (its features read, so threads are offered), selected.
@MainActor private func chatting(_ shape: CatalogShape, configure: (AppStore, Bot) -> Void = { _, _ in }) async throws -> (store: AppStore, jarvis: Bot, state: E2EServer.State) {
    let (store, jarvis, _, _, state, _) = applyStore(shape)
    configure(store, jarvis)
    try await sendAndWait(store, jarvis, "hi E2E-PARENT")
    store.refreshFeatures(for: jarvis)
    try await waitUntil { store.canFork(jarvis) }
    return (store, jarvis, state)
}

@MainActor private func reply(_ bot: Bot) throws -> ChatMessage { try #require(bot.messages.last { $0.role == .assistant }) }
private func forkThenLock(_ state: E2EServer.State) -> [String] {
    state.requests().filter { $0.method == "POST" && ($0.path.hasSuffix("/fork") || $0.path.contains("agentapp_thread_")) }.map { "\($0.method) \($0.path)" }
}

@Test(arguments: CatalogShape.allCases) @MainActor func aPlainThreadWithNoLockAnywhereSendsNoLock(shape: CatalogShape) async throws {
    let (store, jarvis, state) = try await chatting(shape)
    store.replyInThread(to: try reply(jarvis), in: jarvis)
    try await waitUntil { store.openThread(in: jarvis) != nil }
    let thread = try #require(store.openThread(in: jarvis))
    #expect(lockPosts(state).isEmpty && thread.modelLock == nil && thread.role == nil && thread.headerTitle == "Thread")
    #expect(store.codingThreadChoice(for: jarvis) == nil, "no Coding setting: no Code in thread")
}

@Test(arguments: CatalogShape.allCases) @MainActor func aPlainThreadForksThenLocksToItsParentsRecordedLock(shape: CatalogShape) async throws {
    let (store, jarvis, state) = try await chatting(shape) { store, _ in store.modelDefaults.conversation = beta }
    let parentLock = try #require(jarvis.hermesModelLock)
    store.replyInThread(to: try reply(jarvis), in: jarvis)
    try await waitUntil { store.openThread(in: jarvis) != nil }
    let thread = try #require(store.openThread(in: jarvis)), fork = try #require(thread.hermesSessionID)
    let session = try #require(jarvis.hermesSessionID)
    #expect(forkThenLock(state) == ["POST /p/grok-jarvis/api/sessions/\(session)/fork", "POST /p/grok-jarvis/api/sessions/\(fork)/model"], "fork, then lock")
    #expect(lockPosts(state).last?.body["model"] as? String == "model-beta" && lockPosts(state).last?.body["provider"] as? String == "lab-one")
    #expect(thread.modelLock == HermesModelLock(sessionID: fork, provider: "lab-one", model: "model-beta", origin: parentLock.origin) && thread.role == nil)
    #expect(jarvis.hermesModelLock == parentLock, "the main chat's lock is untouched")
}

@Test(arguments: CatalogShape.allCases) @MainActor func codeInThreadLocksTheForkToTheCodingChoice(shape: CatalogShape) async throws {
    let (store, jarvis, state) = try await chatting(shape) { store, jarvis in
        store.modelDefaults.coding = alpha; jarvis.modelSettings = .init(coding: .choice(routed))
    }
    #expect(store.codingThreadChoice(for: jarvis) == routed, "the bot's Coding pick wins over the default")
    store.codeInThread(to: try reply(jarvis), in: jarvis)
    try await waitUntil { store.openThread(in: jarvis) != nil || store.errorMessage != nil }
    let thread = try #require(store.openThread(in: jarvis)), fork = try #require(thread.hermesSessionID)
    #expect(Array(forkThenLock(state).suffix(1)) == ["POST /p/grok-jarvis/api/sessions/\(fork)/model"] && forkThenLock(state).first?.hasSuffix("/fork") == true)
    #expect(Set(lockPosts(state).last?.body.keys ?? [:].keys) == ["model", "provider"] && lockPosts(state).last?.body["model"] as? String == "relay/model-1")
    #expect(thread.role == .coding && thread.modelLock?.origin == .coding && thread.headerTitle == "Coding · relay/model-1")
    #expect(jarvis.hermesModelLock == nil, "the main chat stays on the conversation model")
    try await sendAndWait(store, jarvis, "code E2E-CODE")
    #expect(state.requests().last?.path == "/p/grok-jarvis/api/sessions/\(fork)/chat/stream" && Set(state.requests().last?.body?.keys ?? [:].keys) == ["input", "instructions"])
    let saved = try String(decoding: JSONEncoder().encode(store.storeFile), as: UTF8.self)
    #expect(saved.contains(#""role":"coding""#) && !saved.contains("jarvis-key-77"), "slug and id strings only")
}

@Test(arguments: CatalogShape.allCases) @MainActor func aRefusedCodingLockLeavesNoThreadAndAnError(shape: CatalogShape) async throws {
    let (store, jarvis, state) = try await chatting(shape) { store, _ in store.modelDefaults.coding = routed }
    state.with { $0.lockStatus = 409 }
    store.codeInThread(to: try reply(jarvis), in: jarvis)
    try await waitUntil { store.errorMessage != nil }
    #expect(store.errorMessage == "Could not start a coding thread: Hermes cannot route relay/model-1 for this thread and will not fall back to the default.")
    #expect(jarvis.threads.isEmpty && store.openThreadID == nil, "no half-open thread")
    #expect(forkThenLock(state).count == 2, "the fork happened; its orphan on the box is harmless")
}

@Test(arguments: CatalogShape.allCases) @MainActor func codeInThreadRefusesAnUnofferedPairBeforeForking(shape: CatalogShape) async throws {
    let (store, jarvis, state) = try await chatting(shape) { _, jarvis in jarvis.modelSettings = .init(coding: .choice(unlisted)) }
    #expect(store.codingThreadChoice(for: jarvis) == unlisted, "not checked yet: the button shows")
    store.codeInThread(to: try reply(jarvis), in: jarvis)
    try await waitUntil { store.errorMessage != nil }
    #expect(store.errorMessage == "Could not start a coding thread: " + ModelRoleReason.notOffered("model-unlisted").text)
    #expect(forkThenLock(state).isEmpty && jarvis.threads.isEmpty)
    #expect(store.codingThreadChoice(for: jarvis) == nil, "once the list is loaded the button hides")
    jarvis.modelSettings = .init(coding: .choice(alpha))
    #expect(store.codingThreadChoice(for: jarvis) == nil, "the chat already runs the Coding model")
}

@Test(arguments: CatalogShape.allCases) @MainActor func anUnpinnedChatIsNotOnItsLastReplysModel(shape: CatalogShape) async throws {
    // P30: the row names only the model the last reply ran on; an unpinned chat's next reply runs the agent default.
    let (store, jarvis, state) = try await chatting(shape)
    let session = try #require(jarvis.hermesSessionID)
    #expect(jarvis.hermesModelLock == nil)
    state.with { $0.sessionModels[session] = "model-beta" }
    await store.loadServerInfo(for: jarvis, force: true)
    #expect(store.currentModel(for: jarvis)?.model == "model-alpha" && store.currentModel(for: jarvis)?.lastReplyModel == "model-beta")
    jarvis.modelSettings = .init(coding: .choice(beta))
    #expect(store.codingThreadChoice(for: jarvis) == beta, "the last reply ran on beta, but the chat is not on it")
}

@Test(arguments: CatalogShape.allCases) @MainActor func theEditorOffersTheCodingRole(shape: CatalogShape) {
    let catalog = HermesModelOptions.parse(catalogPayload(shape)).catalog(profile: "grok-jarvis")
    func model(_ setting: ModelSetting, appDefault: ModelChoice?) -> RoleModelEditorModel {
        RoleModelEditorModel(isNew: false, savedBackend: .hermes, pendingBackend: .hermes, catalog: .loaded(catalog), hasEntry: true, autoLoad: true,
                             appDefault: appDefault, setting: setting, role: .coding)
    }
    let plain = model(.inherit, appDefault: nil)
    #expect(plain.leading.map(\.title) == ["Same as conversation"] && plain.leading.map(\.setting) == [.box] && plain.label == "Same as conversation" && plain.canChoose)
    let withDefault = model(.inherit, appDefault: routed)
    #expect(withDefault.leading.map(\.title) == ["\(AppConstants.name) default (relay/model-1)", "Same as conversation"] && withDefault.label == "\(AppConstants.name) default (relay/model-1)")
    #expect(model(.box, appDefault: routed).label == "Same as conversation" && model(.choice(beta), appDefault: nil).label == "model-beta")
    #expect(model(.choice(unlisted), appDefault: nil).warning == "model-unlisted isn't offered by this agent. A new chat stops until you change it.")
    #expect(model(.inherit, appDefault: unlisted).leading.first?.title == "\(AppConstants.name) default (model-unlisted) — not offered by this agent")
}

@Test @MainActor func editorFieldsKeepTheCodingRoleAndABackendChangeClearsIt() {
    let bot = Bot(name: "Jarvis", backend: .hermes, hermesProfile: "grok-jarvis")
    bot.modelSettings = .init(coding: .choice(routed))
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore([:]), defaults: isolatedDefaults())
    var fields = BotEditorFields(bot: bot)
    #expect(fields.codingModel == .choice(routed))
    fields.conversationModel = .box; fields.apply(to: bot, store: store, avatarTouched: false)
    #expect(bot.modelSettings == .init(conversation: .box, coding: .choice(routed)))
    fields.backend = .mock; fields.apply(to: bot, store: store, avatarTouched: false)
    #expect(bot.modelSettings == nil, "no stale Hermes pair stays on another backend")
}

@Test(arguments: CatalogShape.allCases) func sharedSupplierHintNamesTheSupplierBothRolesUse(shape: CatalogShape) {
    let catalog = HermesModelOptions.parse(catalogPayload(shape)).catalog(profile: "grok-jarvis")
    #expect(ModelRolesModel.sharedSupplierHint(conversation: alpha, coding: beta, catalog: catalog) == "Both use Lab One; they share its usage limit.")
    #expect(ModelRolesModel.sharedSupplierHint(conversation: nil, coding: beta, catalog: catalog) == "Both use Lab One; they share its usage limit.", "the agent default's supplier")
    #expect(ModelRolesModel.sharedSupplierHint(conversation: alpha, coding: routed, catalog: catalog) == nil)
    #expect(ModelRolesModel.sharedSupplierHint(conversation: alpha, coding: nil, catalog: catalog) == nil, "Coding follows the conversation")
    #expect(ModelRolesModel.sharedSupplierHint(conversation: alpha, coding: beta, catalog: nil) == "Both use lab-one; they share its usage limit.")
    #expect(ModelRolesModel.codingThreadHelp("model-beta").hasPrefix("Opens a thread whose turns \(AppConstants.name) sends run on model-beta. Not covered:"))
    #expect(ModelRolesModel.codingThreadHelp("model-beta").hasSuffix(ModelRoleReason.permanent.text))
}
