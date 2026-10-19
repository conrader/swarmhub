import Foundation

/// Gap closures after live pass 4: managed approvals become real cards (P07) and secret requests open the secret-entry
/// sheet (P06). Both hook into the end of a finished 1:1 or thread turn (`AppStore+Turns.swift`).
extension AppStore {
    /// Every approval block in a finished reply becomes one card, in the chat of the deciding role's bot when that
    /// profile is a bot here (the owner reads it there), else in the submitting bot's chat. A task already on a card
    /// never gets a second one, so redelivered fences are harmless.
    func routeManagedApprovals(in reply: ChatMessage, bot: Bot) {
        guard bot.backend == .hermes else { return }
        for item in ManagedApproval.parse(in: reply.finalText) {
            guard !approvals.contains(where: { $0.requestID == item.task }) else { continue }
            let decider = item.decider.flatMap { boundBot($0, manager: bot) } ?? bot
            guard !decider.approvalAudit.contains(where: { $0.approvalID == item.cardID && ($0.outcome == .approved || $0.outcome == .denied) }) else { continue }
            var request = item.request(botID: decider.id, profile: item.decider)
            if item.decider != (decider.hermesProfile ?? "default") {
                request.routeNote = "Add the deciding profile \(item.decider ?? "(missing)") on this box before sending a decision."
            }
            approvals.append(request)
            appendAudit(to: decider, approval: request, outcome: .asked, decidedBy: "system",
                        reason: "Managed \(item.kind) action \(item.task) awaits the \(item.gate).", rule: request.rule)
        }
    }

    /// The user's choice on a managed card is sent as the deciding bot's own turn with the exact `swarmctl decide`
    /// command: that gateway's HERMES_HOME is what swarmctl verifies. The card leaves the list only when the turn was
    /// accepted; the audit and a system line record the choice. The result of the command is the bot's reply.
    func decideManagedAction(_ approval: ApprovalRequest, approved: Bool) {
        guard approvals.contains(where: { $0.id == approval.id }),
              let botID = approval.botID, let presenter = bots.first(where: { $0.id == botID }), let task = approval.requestID else {
            errorMessage = "This approval no longer names a bot that can decide it."; return
        }
        guard let actor = approval.profile, presenter.backend == .hermes,
              let decider = boundBot(actor, manager: presenter) else {
            errorMessage = "The deciding profile is not connected on this box. Add it before sending a decision."; return
        }
        let text = ManagedApproval.decisionTurn(task: task, actor: actor, approved: approved, title: approval.title)
        let metadata = [AutomationKey.display: (approved ? "Approve " : "Deny ") + task]
        guard send(text: text, bot: decider, conversation: decider, replyToID: nil, waitWhenFull: true, metadata: metadata) else {
            errorMessage = "The decision could not be sent to \(decider.name); try again when its chat is free."; return
        }
        approvals.removeAll { $0.id == approval.id }
        appendAudit(to: decider, approval: approval, outcome: approved ? .approved : .denied, decidedBy: "user",
                    reason: "User chose " + (approved ? "approve" : "deny") + "; sent as \(decider.name)'s turn to run swarmctl decide.", rule: approval.rule)
        decider.messages.append(ChatMessage(role: .system, content: "Decision sent (\(approved ? "approve" : "deny")): " + approval.title + ". Awaiting the managed runtime result."))
        objectWillChange.send(); save()
    }

    /// The first secret request in a finished reply opens the sheet (one at a time; a later request waits for the
    /// next reply that repeats it).
    func routeSecretRequests(in reply: ChatMessage, bot: Bot, conversation: any Conversation) {
        guard secretRequest == nil, let request = SecretRequest.parse(in: reply.finalText).first else { return }
        secretRequest = SecretRequestPrompt(botID: bot.id, conversationID: conversation.id, request: request)
    }

    /// Writes the typed value to a 0600 file and tells the bot the path. Returns false (with `errorMessage`) when the
    /// file could not be written or the chat is busy; the value is dropped either way.
    @discardableResult func provideSecret(_ prompt: SecretRequestPrompt, value: String) -> Bool {
        let threadID: UUID? = prompt.conversationID == prompt.botID ? nil : prompt.conversationID
        guard let (bot, conversation) = actionConversation(.bot(botID: prompt.botID, threadID: threadID)) else {
            errorMessage = "The chat that asked for the secret is gone."; return false
        }
        let url: URL
        do { url = try SecretFileWriter.write(value, name: prompt.request.name, in: secretFolder) } catch {
            errorMessage = "Could not store the secret: \(error.localizedDescription)"; return false
        }
        let sent = send(text: SecretFileWriter.message(for: prompt.request, at: url), bot: bot, conversation: conversation, replyToID: nil,
                        waitWhenFull: true, metadata: [AutomationKey.display: "Secret path for \(prompt.request.name)"])
        if !sent { errorMessage = "The secret is stored at \(url.path), but the path could not be sent while the chat is busy." }
        return sent
    }
}
