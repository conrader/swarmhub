import Foundation

/// A Herdr bot that may create bots (its "Can create other bots" switch, the same `canManageBots` flag the older
/// backends' manager uses). On Herdr a bot is only this app's record, so the bot does nothing on the server: it asks
/// in its reply (`HerdrBotRequest`), the chat shows each request, and the bot is added only when the person accepts.
extension AppStore {
    /// How to ask, with the avatar words the app can draw. Sent to the agent by `HerdrBackend`.
    static let herdrCreationNote = HerdrBotRequest.note(shapes: AvatarShape.grok, colours: AvatarColour.allCases.map(\.rawValue))
    /// `UserDefaults`: the requests already created or dismissed, as `<message id>#<name>`, newest last.
    static let herdrHandledRequestsKey = "herdrBotRequestsHandled", herdrHandledRequestsKept = 200

    func createsHerdrBots(_ bot: Bot) -> Bool { bot.backend == .herdr && bot.canManageBots && !bot.isReadOnlyArchive }

    /// One request waiting for the person's answer. `taken`: a Herdr bot with that name is already on the server.
    struct PendingHerdrBot: Identifiable, Equatable {
        let id: String; let request: HerdrBotRequest; let taken: Bool
    }

    /// The requests in the bot's newest finished reply that were neither created nor dismissed. An older reply's
    /// requests are no longer offered once the bot has answered again; nothing is offered while it is still answering.
    func pendingHerdrBots(for bot: Bot) -> [PendingHerdrBot] {
        guard createsHerdrBots(bot), isIdle(bot),
              let reply = bot.messages.last(where: { $0.role == .assistant && $0.presentation == .text }), !reply.isStreaming else { return [] }
        let handled = Set(defaults.stringArray(forKey: Self.herdrHandledRequestsKey) ?? [])
        let names = Set(herdrBots(on: herdrServer(for: bot)).map { $0.name.lowercased() })
        return HerdrBotRequest.requests(in: reply.content).compactMap { request in
            let id = Self.herdrRequestID(reply.id, request)
            return handled.contains(id) ? nil : PendingHerdrBot(id: id, request: request, taken: names.contains(request.name.lowercased()))
        }
    }

    static func herdrRequestID(_ messageID: UUID, _ request: HerdrBotRequest) -> String { "\(messageID.uuidString.lowercased())#\(request.name.lowercased())" }

    /// The person said no (or the name is taken): the request is not offered again.
    func dismissHerdrBot(_ pending: PendingHerdrBot) {
        let handled = (defaults.stringArray(forKey: Self.herdrHandledRequestsKey) ?? []).filter { $0 != pending.id } + [pending.id]
        defaults.set(Array(handled.suffix(Self.herdrHandledRequestsKept)), forKey: Self.herdrHandledRequestsKey)
        objectWillChange.send()
    }

    /// The person accepted: a new Herdr bot on the asking bot's server, with the requested name, avatar and
    /// instructions. `templates` are the server's (the caller read them; empty when it could not): a requested runtime
    /// that matches one is used, otherwise the new bot runs like the bot that asked. Never called without a press.
    @discardableResult func createHerdrBot(_ pending: PendingHerdrBot, manager: Bot, templates: [HerdrClient.Template] = [],
                                           offered: [HerdrClient.Template.Model] = []) -> Bot? {
        guard createsHerdrBots(manager), !pending.taken else { dismissHerdrBot(pending); return nil }
        let request = pending.request, server = herdrServer(for: manager)
        let bot = Bot(name: request.name, title: "Created by \(manager.name)", persona: request.instructions.isEmpty ? Bot.defaultPersona : request.instructions, backend: .herdr)
        if request.shape != nil || request.colour != nil {
            bot.avatarMark = AvatarLook.effectiveMark(shape: request.shape, colour: request.colour, seed: bot.avatarSeed); bot.avatarMarkMigrated = false
        }
        bots.append(bot)
        setHerdrServer(server.id, for: bot)
        if let template = HerdrBotRequest.template(for: request.runtime, in: templates) {
            // Another agent program: its own first model, or the requested one when the server offers it.
            setHerdrTemplate(template.name, for: bot)
            setHerdrModel(offered.first { $0.id == request.model }?.id ?? Self.starterModel(offered: offered) ?? "", for: bot)
        } else {
            setHerdrTemplate(defaults.string(forKey: HerdrBackend.botTemplateKey(manager.id)) ?? "", for: bot)
            setHerdrModel(herdrModel(for: manager), for: bot)
        }
        dismissHerdrBot(pending)
        notice(AppOnlyLine.created.render(manager.name, bot.name), in: manager)
        return bot
    }

    /// Reads what the server can start, then creates the bot. A server that cannot be read still gets the bot, running
    /// like the one that asked.
    @discardableResult func acceptHerdrBot(_ pending: PendingHerdrBot, manager: Bot) async -> Bot? {
        var templates: [HerdrClient.Template] = [], offered: [HerdrClient.Template.Model] = []
        if pending.request.runtime != nil, let client = try? herdrClient(for: herdrServer(for: manager)) {
            templates = (try? await client.workspace().templates.filter { $0.error == nil }) ?? []
            if let template = HerdrBotRequest.template(for: pending.request.runtime, in: templates) { offered = (try? await client.models(for: template)) ?? template.models ?? [] }
        }
        return createHerdrBot(pending, manager: manager, templates: templates, offered: offered)
    }
}
