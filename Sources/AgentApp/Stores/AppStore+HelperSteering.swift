import Foundation

/// Keep the destination the person chose even if a workspace later reuses a terminal address or helper name.
struct HelperSteeringTarget {
    let selection: HerdrHelperSelection
    let server: HerdrServer
    let core: String
    let owner: HerdrClient.AgentRef
    let name: String
    let task: String

    struct ID: Hashable {
        let parent: HerdrHelperParent
        let server: HerdrServer
        let core: String
        let owner: HerdrClient.AgentRef
        let provider: HerdrClient.ChildRuntime?
        let helperID: String
    }

    var id: ID {
        .init(parent: selection.parent, server: server, core: core, owner: owner,
              provider: selection.native?.thread.provider, helperID: selection.helperID)
    }

    var routeKey: String {
        // Length prefixes preserve arbitrary provider IDs and avoid collisions with separators in names.
        let fields = [selection.botID.uuidString, server.id, core, owner.address, String(owner.createdMs),
                      selection.groupRuntime ?? "", selection.native?.thread.provider.rawValue ?? "workspace", selection.helperID]
        return fields.map { "\($0.utf8.count):" + $0 }.joined()
    }

    func instructions(in messages: [ChatMessage]) -> [ChatMessage] {
        let key = routeKey
        return messages.filter { $0.role == .user && $0.metadata[HelperGuidanceKey.route] == key }
    }

    var reference: String {
        let session = selection.native.map { $0.thread.provider.label + " thread " } ?? "workspace session "
        return "\(session)\(selection.helperID), owner \(owner.address)/\(owner.createdMs), core \(core)"
    }
}

@MainActor final class HelperSteeringDraft: ObservableObject {
    let target: HelperSteeringTarget
    @Published var text = ""
    init(_ target: HelperSteeringTarget) { self.target = target }
}

extension AppStore {
    func steeringTarget(_ selection: HerdrHelperSelection, of bot: Bot) -> HelperSteeringTarget? {
        guard selection.archive == nil, selection.botID == bot.id, !bot.isReadOnlyArchive,
              herdrHelperReads[selection.parent] != .unavailable, let list = herdrHelpers[selection.parent] else { return nil }
        let server = herdrServer(for: bot)
        let name: String
        let task: String
        if let native = selection.native {
            guard server == native.server, list.core == native.core, list.parent == native.owner,
                  let thread = list.nativeThreads.first(where: { $0.id == selection.helperID && $0.provider == native.thread.provider })
            else { return nil }
            name = thread.name
            task = HelperAssignment.readable(thread.task) ?? ""
        } else {
            guard let helper = list.sidebarSessions.first(where: { $0.id == selection.helperID }) else { return nil }
            name = helper.name
            task = helper.assignment ?? ""
        }
        return .init(selection: selection, server: server, core: list.core, owner: list.parent, name: name, task: task)
    }

    func beginHelperSteering(_ selection: HerdrHelperSelection, of bot: Bot) -> Bool {
        if selection.archive != nil { return openHelperParent(selection, of: bot) }
        guard let target = steeringTarget(selection, of: bot), openHelperParent(selection, of: bot),
              let chat = openConversation else { return false }
        let current = helperSteeringDrafts[chat.id]
        if current?.target.id == target.id { return true }
        if let current, !current.text.isEmpty {
            inactiveHelperInstructions[current.target.id] = current.text
        }
        let draft = HelperSteeringDraft(target)
        draft.text = inactiveHelperInstructions.removeValue(forKey: target.id) ?? ""
        helperSteeringDrafts[chat.id] = draft
        return true
    }

    func submitHelperSteering(in chatID: UUID) -> Bool {
        guard let draft = helperSteeringDrafts[chatID], openConversation?.id == chatID,
              let bot = bots.first(where: { $0.id == draft.target.selection.botID }) else { return false }
        let words = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return false }
        let target = draft.target
        guard let current = steeringTarget(target.selection, of: bot),
              current.id == target.id else {
            errorMessage = "The selected helper session is no longer available. Your instruction is still here."
            return false
        }
        guard deliverHelperGuidance(words, target: target, of: bot) else { return false }
        helperSteeringDrafts.removeValue(forKey: chatID)
        composerFocus = chatID
        return true
    }

    func sendHelperMessage(_ text: String, to target: HelperSteeringTarget, of bot: Bot) -> Bool {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, steeringTarget(target.selection, of: bot)?.id == target.id else { return false }
        return deliverHelperGuidance(words, target: target, of: bot)
    }

    private func deliverHelperGuidance(_ words: String, target: HelperSteeringTarget, of bot: Bot) -> Bool {
        let owner = delegatingSession(for: target.selection).map { "the helper delegated by “\($0.helper.name)” named" } ?? "your helper"
        let prefix = "Please steer \(owner) “\(target.name)” (\(target.reference)) with this instruction:"
        let metadata = [HelperGuidanceKey.route: target.routeKey, HelperGuidanceKey.helper: target.name, HelperGuidanceKey.prefix: prefix]
        if let runtime = target.selection.groupRuntime {
            guard let group = groupOwningHelper(target.selection, of: bot),
                  HerdrBackend.groupRuntimeName(sessionID: turnSessionID(in: group, bot: bot), botID: bot.id) == runtime
            else { return false }
            return send(text: words, to: group, recipientIDs: [bot.id], queueChoice: true, usesComposerReply: false, metadata: metadata)
        }
        if SampleWorkspace.isCoordinator(bot) {
            guard persistenceEnabled, storeRestoreOffer == nil else { return false }
            let user = ChatMessage(role: .user, content: words, metadata: metadata)
            let reply = ChatMessage(role: .assistant, content: "I saved your instruction with the \(target.name) sample session.",
                                    metadata: [TurnKey.forUser: user.id.uuidString])
            bot.messages.append(contentsOf: [user, reply])
            save()
            if turns.saveFailing {
                bot.messages.removeAll { $0 === user || $0 === reply }
                return false
            }
            chatScroll.toBottom(bot.id)
            return true
        }
        return send(text: words, bot: bot, conversation: bot, replyToID: nil, waitWhenFull: true, metadata: metadata)
    }

    func guidanceMessages(for selection: HerdrHelperSelection, of bot: Bot) -> [ChatMessage] {
        guard let target = steeringTarget(selection, of: bot) else { return [] }
        let messages = selection.groupRuntime == nil ? bot.messages : groupOwningHelper(selection, of: bot)?.messages ?? []
        return target.instructions(in: messages)
    }

    func latestGuidance(for selection: HerdrHelperSelection, of bot: Bot) -> ChatMessage? {
        guidanceMessages(for: selection, of: bot).last
    }

    func guideHelper(_ helper: HerdrClient.Helper, selection: HerdrHelperSelection, of bot: Bot, instruction: String) -> Bool {
        let words = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, selection.native == nil, selection.helperID == helper.id,
              let target = steeringTarget(selection, of: bot),
              herdrHelpers[selection.parent]?.helpers.contains(where: { $0.id == helper.id && $0.isLive }) == true,
              deliverHelperGuidance(words, target: target, of: bot) else { return false }
        return openHelperParent(selection, of: bot)
    }
}

enum HelperGuidanceKey {
    static let route = "helperGuidanceRoute"
    static let helper = "helperGuidanceName"
    static let prefix = "helperGuidanceRequestPrefix"
}
