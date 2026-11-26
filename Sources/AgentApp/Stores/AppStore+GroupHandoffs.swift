import Foundation

extension AppStore {
    static let groupHandoffSourceKey = "groupHandoffSource"

    static let groupHandoffReturnKey = "groupHandoffReturn"
    static let groupHandoffResultKey = "groupHandoffResult"

    /// Resolve a return against the recorded dispatch, even if names have changed since the handoff.
    private func handoffOrigin(_ source: String?, reviewer: Bot, requester: Bot) -> (GroupChat, ChatMessage)? {
        guard let source else { return nil }
        let fields = source.components(separatedBy: "/")
        guard fields.count == 3, UUID(uuidString: fields[2]) == requester.id,
              let groupID = UUID(uuidString: fields[0]), let triggerID = UUID(uuidString: fields[1]),
              let group = groups.first(where: { $0.id == groupID }),
              group.memberIDs.contains(reviewer.id), group.memberIDs.contains(requester.id),
              herdrPeers(of: reviewer).contains(where: { $0.id == requester.id }),
              let trigger = group.messages.first(where: { $0.id == triggerID }),
              trigger.metadata[Self.groupHandoffSourceKey + "." + requester.id.uuidString] == reviewer.id.uuidString.lowercased()
        else { return nil }
        return (group, trigger)
    }

    /// One shared answer and one continuation in the original group runtime. The requester's private chat
    /// keeps its exchange receipt without starting a competing turn.
    func returnGroupHandoff(_ source: String?, from reviewer: Bot, to requester: Bot, answer: String,
                            summary: RunSummary?, receiptMetadata: [String: String]) -> Bool {
        guard let source, let (group, trigger) = handoffOrigin(source, reviewer: reviewer, requester: requester) else { return false }
        let settled = Self.groupHandoffResultKey + "." + requester.id.uuidString
        guard trigger.metadata[settled] == nil else { return true }
        let result = ChatMessage(role: .assistant, content: answer,
                                 metadata: [Self.groupHandoffResultKey: source, TurnWaitCopy.recipients: requester.id.uuidString],
                                 replyToID: trigger.id, authorID: reviewer.id, turnState: .finished)
        result.runSummary = summary
        trigger.metadata[settled] = result.id.uuidString
        guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            group.messages.append(ChatMessage(role: .system, content: reviewer.name + " finished the handoff without an answer."))
            save()
            return true
        }
        group.messages.append(result)
        var metadata = receiptMetadata
        metadata[HerdrBotRelay.Key.kind] = HerdrBotRelay.answer
        metadata[HerdrBotRelay.Key.asker] = requester.id.uuidString.lowercased()
        metadata[HerdrBotRelay.Key.name] = reviewer.name
        metadata[Self.herdrExchangeEndedKey] = "1"
        requester.messages.append(ChatMessage(role: .user, content: HerdrBotRelay.reply(from: reviewer.name, answer), metadata: metadata))
        groupReplyArrived(result, state: .finished, from: reviewer, in: group)
        result.metadata[TurnWaitCopy.key] = "waiting"
        let next = QueuedNextMessage(conversation: group, bubble: result, kind: .turn)
        guard enqueueNextMessage(next) else {
            result.metadata[TurnWaitCopy.key] = nil
            addWarning("The review arrived. The follow-up for " + requester.name + " could not be queued.", in: group, after: result)
            save()
            return true
        }
        save()
        sendQueuedNextMessage()
        return true
    }

    func recordUnfinishedGroupHandoff(_ part: ChatMessage?, from reviewer: Bot) {
        guard let part, let raw = part.metadata[HerdrBotRelay.Key.asker], let id = UUID(uuidString: raw),
              let requester = bots.first(where: { $0.id == id }),
              let (group, trigger) = handoffOrigin(part.metadata[Self.groupHandoffReturnKey], reviewer: reviewer, requester: requester)
        else { return }
        let key = Self.groupHandoffResultKey + "." + requester.id.uuidString
        guard trigger.metadata[key] == nil else { return }
        let notice = ChatMessage(role: .system, content: reviewer.name + " stopped before returning a review to " + requester.name + ".", replyToID: trigger.id)
        trigger.metadata[key] = notice.id.uuidString
        group.messages.append(notice)
    }

    /// The source group authorizes a specific peer. Delivery uses the ordinary, attributed bot message queue.
    func deliverGroupHandoff(in group: GroupChat, from bot: Bot, trigger: ChatMessage, reply: ChatMessage,
                             configured: [TeamHandoff<UUID>]) {
        guard !configured.isEmpty,
              let request = HerdrBotRequest.objects(in: TurnReplyText.complete(reply, in: group)).first(where: { $0["op"] as? String == "group_handoff" })
        else { return }
        let key = Self.groupHandoffSourceKey
        let sentKey = key + "." + bot.id.uuidString
        guard trigger.metadata[sentKey] == nil else { return }
        func receipt(_ text: String) { group.messages.append(ChatMessage(role: .system, content: text)) }
        guard let raw = request["recipient"] as? String, let id = UUID(uuidString: raw),
              let task = (request["task"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !task.isEmpty,
              groups.contains(where: { $0 === group }), group.memberIDs.contains(bot.id), group.memberIDs.contains(id),
              configured.contains(where: { $0.recipient == id && group.workflows[bot.id]?.handoffs.contains($0) == true }),
              bot.backend == .herdr, !bot.documentReadOnly, !bot.isReadOnlyArchive,
              let peer = herdrPeers(of: bot).first(where: { $0.id == id }), herdrTakesMessages(peer) else {
            receipt("Handoff from " + bot.name + " could not be sent. Check the group rule and the recipient’s workspace and message settings.")
            return
        }
        let delivery = [group.id, trigger.id, bot.id].map(\.uuidString).joined(separator: "/")
        let times = Self.herdrMessageTimesKey(bot.id)
        guard herdrAllowed(times, limit: HerdrBotRelay.messageLimit) else {
            receipt(bot.name + " reached its bot messaging limit. The task was not sent to " + peer.name + ".")
            return
        }
        let sender = bot.id.uuidString.lowercased(), receiver = peer.id.uuidString.lowercased()
        let metadata = [key: delivery, Self.groupHandoffReturnKey: delivery, HerdrBotRelay.ExchangeKey.chain: HerdrBotRelay.joined([sender, receiver]),
                        HerdrBotRelay.ExchangeKey.rounds: HerdrBotRelay.joined(rounds: [HerdrBotRelay.pair(sender, receiver): 1])]
        let skills = group.workflows[id]?.skills.map { "Skill · " + $0.name + "\n" + $0.instructions } ?? []
        let text: String
        var attachments = [ChatAttachment]()
        do {
            let backend = try? herdrBackend(for: peer)
            let destination = "Return your review to " + bot.name + " in the group “" + group.name + "”."
            let envelope = HerdrBotRelay.message(from: bot.name, "").utf8.count
            let inlineLimit = backend.map { groupMessageBudget($0, hasFiles: false) } ?? HerdrClient.messageBytes
            let fileLimit = backend.map { groupMessageBudget($0, hasFiles: true) } ?? HerdrClient.messageBytes
            let workflow = skills.isEmpty ? "" : skills.joined(separator: "\n\n") + "\n\n"
            let delivery = try TeamWorkflowDelivery(workflow: workflow, message: task + "\n\n" + destination,
                inlineLimit: inlineLimit - envelope, fileLimit: fileLimit - envelope, occupiedNames: [])
            text = HerdrBotRelay.message(from: bot.name, delivery.text)
            if let file = delivery.file {
                attachments = [.init(id: UUID(), kind: .text, name: file.name, mimeType: file.mime,
                                     byteCount: file.data.count, text: String(decoding: file.data, as: UTF8.self))]
            }
        } catch { receipt("Handoff to " + peer.name + " could not be sent. " + error.localizedDescription); return }
        trigger.metadata[sentKey] = receiver
        guard herdrPassOn(text, to: peer, kind: HerdrBotRelay.message, asker: bot, name: bot.name, extra: metadata, attachments: attachments) else {
            trigger.metadata[sentKey] = nil
            receipt("Handoff to " + peer.name + " could not be delivered.")
            return
        }
        herdrCount(times)
        receipt(bot.name + " handed a task to " + peer.name + ".\n" + task)
    }
}
