import Foundation

extension AppStore {
    static let groupHandoffSourceKey = "groupHandoffSource"

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
        let metadata = [key: delivery, HerdrBotRelay.ExchangeKey.chain: HerdrBotRelay.joined([sender, receiver]),
                        HerdrBotRelay.ExchangeKey.rounds: HerdrBotRelay.joined(rounds: [HerdrBotRelay.pair(sender, receiver): 1])]
        let skills = group.workflows[id]?.skills.map { "Skill · " + $0.name + "\n" + $0.instructions } ?? []
        let text = HerdrBotRelay.message(from: bot.name, (skills + [task]).joined(separator: "\n\n"))
        do { try HerdrClient.validateMessage(text) }
        catch { receipt("Handoff to " + peer.name + " could not be sent. " + error.localizedDescription); return }
        trigger.metadata[sentKey] = receiver
        guard herdrPassOn(text, to: peer, kind: HerdrBotRelay.message, asker: bot, name: bot.name, extra: metadata) else {
            trigger.metadata[sentKey] = nil
            receipt("Handoff to " + peer.name + " could not be delivered.")
            return
        }
        herdrCount(times)
        receipt(bot.name + " handed a task to " + peer.name + ".\n" + task)
    }
}
