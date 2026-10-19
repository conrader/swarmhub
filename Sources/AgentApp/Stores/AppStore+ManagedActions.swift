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
            Task { @MainActor in
                do {
                    let record = try await managedRuntime(bot, verb: "get", task: item.task)
                    guard record.id == item.task, record.awaiting,
                          let actor = record.decider, let decider = boundBot(actor, manager: bot) else { return }
                    // The fence is only a notification. Card content comes entirely from the runtime.
                    let request = try record.request(botID: decider.id)
                    if approvals.contains(where: { $0.requestID == record.id && $0.botID == decider.id }) {
                        // A notification must never replace a reviewed/persisted binding or uncertain decision.
                        return
                    } else {
                        approvals.append(request)
                        appendAudit(to: decider, approval: request, outcome: .asked, decidedBy: "system",
                                    reason: "Runtime confirmed pending operation.", rule: request.rule)
                    }
                    save()
                } catch { errorMessage = error.localizedDescription }
            }
        }
    }

    func managedRuntime(_ bot: Bot, verb: String, task: String, input: Data? = nil) async throws -> ManagedRecord {
        if let managedControl { return try await managedControl(bot, verb, task, input) }
        let address = bot.hermesBaseURL ?? defaults.string(forKey: "hermesBaseURL") ?? AppConstants.defaultHermesURL
        let profile = bot.hermesProfile ?? "default"
        if let host = URL(string: address)?.host, !["localhost", "127.0.0.1", "::1"].contains(host) {
            guard !prefixIgnoredHermesProfiles.contains(profile) else { throw ManagedControlError.unsent("This profile is unavailable.") }
            let account = Self.keyAccount(forProfile: profile)
            let key = keyStore.key(for: account)
            if key.isEmpty, keyStore.needsReentry(account) { throw ManagedControlError.unsent(KeychainStore.reenterMessage) }
            return try await ManagedRemoteControl.request(address: address, profile: profile, key: key,
                                                          verb: verb, task: task, input: input, session: hermesSession)
        }
        return try await ManagedLocalControl.request(
            address: address, profile: profile, verb: verb, task: task, input: input,
            home: managedHome ?? FileManager.default.homeDirectoryForCurrentUser)
    }

    /// Keep the persisted pending card until an authoritative runtime receipt confirms the decision.
    /// Every retry queries first, including after a restart or an uncertain transport acknowledgement.
    func decideManagedAction(_ approval: ApprovalRequest, approved: Bool) {
        guard !managedDecisionsInFlight.contains(approval.id) else { return }
        guard let index = approvals.firstIndex(where: { $0.id == approval.id }),
              let original = approvals[index].managedRecord, original == approval.managedRecord, let botID = approval.botID,
              let bot = bots.first(where: { $0.id == botID }), approval.profile == original.decider else {
            errorMessage = "This card has no verified runtime operation. Refresh its notification."; return
        }
        // A lost ACK retains the user's original choice, including across app restarts.
        if let previous = approvals[index].managedDecision, previous != approved {
            errorMessage = "The earlier decision is still awaiting a receipt. Retry that decision to reconcile it."
            return
        }
        let sendDecision = approvals[index].decisionPending != true
        managedDecisionsInFlight.insert(approval.id)
        approvals[index].decisionPending = true; save()
        Task { @MainActor in
            defer { managedDecisionsInFlight.remove(approval.id) }
            await reconcileManagedDecision(approval, bot: bot, approved: approved, original: original, sendDecision: sendDecision)
        }
    }

    private func reconcileManagedDecision(_ approval: ApprovalRequest, bot: Bot, approved: Bool, original: ManagedRecord, sendDecision: Bool) async {
        let earlierChoice = approvals.first(where: { $0.id == approval.id })?.managedDecision
        do {
            if let binding = original.remoteBinding {
                let address = bot.hermesBaseURL ?? defaults.string(forKey: "hermesBaseURL") ?? AppConstants.defaultHermesURL
                guard try ManagedRemoteControl.origin(address: address) == binding.origin,
                      (bot.hermesProfile ?? "default") == binding.profile else { throw ManagedControlError.invalidRecord }
            }
            var receipt = try await managedRuntime(bot, verb: "get", task: original.id)
            if !receipt.confirms(approved, original: original) {
                guard receipt.sameOperation(as: original), receipt.awaiting else { throw ManagedControlError.invalidRecord }
                if sendDecision {
                    var body: [String: Any] = ["approved": approved, "fingerprint": original.fingerprint, "gate": original.gate]
                    if let binding = original.remoteBinding {
                        body["binding"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(binding))
                    }
                    let input = try JSONSerialization.data(withJSONObject: body)
                    // Persist immediately before dispatch. A crash or lost reply from this point is uncertain.
                    guard let index = approvals.firstIndex(where: { $0.id == approval.id }) else { return }
                    approvals[index].managedDecision = approved; save()
                    receipt = try await managedRuntime(bot, verb: "decide", task: original.id, input: input)
                }
            }
            guard receipt.confirms(approved, original: original) else { throw ManagedControlError.rejected }
            approvals.removeAll { $0.id == approval.id }
            appendAudit(to: bot, approval: approval, outcome: approved ? .approved : .denied, decidedBy: "user",
                        reason: "Runtime confirmed bound decision.", rule: approval.rule)
        } catch ManagedControlError.retired(let task, let origin, let runtime, let reason) {
            if task == original.id, let binding = original.remoteBinding,
               binding.origin == origin, binding.runtime == runtime {
                approvals.removeAll { $0.id == approval.id }
                appendAudit(to: bot, approval: approval, outcome: .asked, decidedBy: "system",
                            reason: "Approval card retired: runtime reports \(reason). No decision was confirmed.", rule: approval.rule)
            } else {
                if let index = approvals.firstIndex(where: { $0.id == approval.id }) { approvals[index].decisionPending = false }
                errorMessage = ManagedControlError.invalidRecord.localizedDescription
            }
        } catch {
            if let index = approvals.firstIndex(where: { $0.id == approval.id }) {
                approvals[index].decisionPending = false
                if let controlError = error as? ManagedControlError, case .unsent = controlError {
                    approvals[index].managedDecision = earlierChoice
                }
            }
            errorMessage = error.localizedDescription
        }
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
