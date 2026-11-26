import Foundation

/// Keep the destination the person chose even if a workspace later reuses a terminal address or helper name.
struct HelperSteeringTarget {
    let selection: HerdrHelperSelection
    let server: HerdrServer
    let core: String
    let owner: HerdrClient.AgentRef
    let name: String
    let task: String

    func identifies(_ other: Self) -> Bool {
        server == other.server && core == other.core && owner == other.owner && selection.parent == other.selection.parent
            && selection.native?.thread.provider == other.selection.native?.thread.provider && selection.helperID == other.selection.helperID
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
    private func steeringTarget(_ selection: HerdrHelperSelection, of bot: Bot) -> HelperSteeringTarget? {
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
            task = thread.task
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
        if helperSteeringDrafts[chat.id]?.target.identifies(target) != true {
            helperSteeringDrafts[chat.id] = HelperSteeringDraft(target)
        }
        return true
    }

    func submitHelperSteering(in chatID: UUID) -> Bool {
        guard let draft = helperSteeringDrafts[chatID], openConversation?.id == chatID,
              let bot = bots.first(where: { $0.id == draft.target.selection.botID }) else { return false }
        let words = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return false }
        let target = draft.target
        guard let current = steeringTarget(target.selection, of: bot),
              current.identifies(target) else {
            errorMessage = "The selected helper session is no longer available. Your instruction is still here."
            return false
        }
        guard deliverHelperGuidance(words, target: target, of: bot) else { return false }
        helperSteeringDrafts.removeValue(forKey: chatID)
        composerFocus = chatID
        return true
    }

    private func deliverHelperGuidance(_ words: String, target: HelperSteeringTarget, of bot: Bot) -> Bool {
        let text = "Please steer your helper “\(target.name)” (\(target.reference)) with this instruction:\n\(words)"
        if let runtime = target.selection.groupRuntime {
            guard let group = groupOwningHelper(target.selection, of: bot),
                  HerdrBackend.groupRuntimeName(sessionID: turnSessionID(in: group, bot: bot), botID: bot.id) == runtime
            else { return false }
            return send(text: text, to: group, recipientIDs: [bot.id], queueChoice: true, usesComposerReply: false)
        }
        return send(text: text, bot: bot, conversation: bot, replyToID: nil, waitWhenFull: true)
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
