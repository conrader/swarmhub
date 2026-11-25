import Foundation

/// What a Herdr bot's agent runs on, in the server's own names: the agent program and template its next agent starts
/// from, the model that agent starts on, and the model the agent running now was started on. Nothing here is a
/// placeholder: a bot with no template of its own resolves to the one new bots use, and a bot with no model of its
/// own to the first model the server offers for that template, which is also what `HerdrClient.deliver` sends.
/// The app names no model itself. Foundation only, like the rest of the Herdr client.
struct HerdrAgentReading: Equatable, Sendable {
    /// The agent running now, as the bridge recorded its launch.
    enum Running: Equatable, Sendable {
        /// No agent is running.
        case none
        /// Started on this model.
        case model(id: String, label: String)
        /// Started without a model: the agent program picked one, and the server does not say which.
        case unstated
        /// Running, but the server has no record of its launch.
        case unknown
    }

    /// The template the next agent starts from; nil when the server has none it can start (or the bot's own is gone).
    var runtime: HerdrClient.Template?
    /// The bot chose this template itself; false: it is the one new bots use, or the server's first.
    var runtimeIsOwn = false
    /// The model the next agent starts on; nil when the server offers no list and the agent program picks.
    var model: HerdrClient.Template.Model?
    var modelIsOwn = false
    var usesRecommendation = false
    var running = Running.none
    var session: HerdrClient.AgentRef?
    var core: String?
    var activeTemplate: String?
    var confirmed = false
    var autoRestartPending = false
    var reviewDescription: String?

    /// The template a bot starts from: its own, else the one chosen for new bots, else the server's first usable one.
    /// A name the server does not have resolves to nothing, as `deliver` refuses it.
    static func template(own: String?, shared: String?, in usable: [HerdrClient.Template]) -> (template: HerdrClient.Template?, isOwn: Bool) {
        if let own, !own.isEmpty { return (usable.first { $0.name == own }, true) }
        if let shared, !shared.isEmpty { return (usable.first { $0.name == shared }, false) }
        return (usable.first, false)
    }

    /// The default template's own entry in a picker: what "no choice" means for a bot, by name.
    static func defaultLabel(shared: String?, in usable: [HerdrClient.Template]) -> String? {
        template(own: nil, shared: shared, in: usable).template.map { "\($0.label) (default)" }
    }

    /// `offered`: the models the server lists for the resolved template. `agent` and `profiles`: the bot's live agent
    /// and the server's profiles, which hold what each session was launched with.
    init(templates usable: [HerdrClient.Template], ownTemplate: String?, sharedTemplate: String?, ownModel: String?, offered: [HerdrClient.Template.Model],
         agent: HerdrClient.Agent? = nil, profiles: [HerdrClient.Profile] = []) {
        (runtime, runtimeIsOwn) = Self.template(own: ownTemplate, shared: sharedTemplate, in: usable)
        if runtime?.takesModel == true {
            if ownModel == HerdrModelChoice.recommended {
                usesRecommendation = true
                model = HerdrModelChoice.suggested(program: runtime?.modelAgent ?? runtime?.programName, offered: offered)
            } else if let ownModel, !ownModel.isEmpty { model = offered.first { $0.id == ownModel } ?? .init(id: ownModel, label: nil); modelIsOwn = true }
            else { model = HerdrClient.defaultModel(offered: offered).flatMap { id in offered.first { $0.id == id } } }
        }
        guard let agent else { return }
        autoRestartPending = agent.autoRestartPending == true
        reviewDescription = agent.reviewDescription
        self.session = agent.ref; activeTemplate = agent.template
        let session = profiles.lazy.flatMap { $0.sessions ?? [] }.first { $0.address == agent.address && $0.createdMs == agent.createdMs }
        guard let session else { running = .unknown; return }
        guard let id = session.runtime?.modelId, !id.isEmpty else { running = .unstated; return }
        // The label the server's list gives the id; a session saved by id alone repeats the id as its label.
        running = .model(id: id, label: offered.first { $0.id == id }?.label ?? session.runtime?.model ?? id)
    }

    static func name(_ model: HerdrClient.Template.Model) -> String { model.label ?? model.id }

    /// The agent program by its friendly name, with "(default)" when the bot did not choose it.
    var runtimeLine: String {
        guard let runtime else { return "None set up on this server" }
        return runtimeIsOwn ? runtime.label : "\(runtime.label) (default)"
    }

    /// The model by the server's name for it, with "(default)" when the bot did not choose it.
    var modelLine: String {
        guard let model else { return Self.programPicks }
        if usesRecommendation { return "\(Self.name(model)) (recommended)" }
        return modelIsOwn ? Self.name(model) : "\(Self.name(model)) (default)"
    }

    static let programPicks = "It picks its own model."
    /// The button that ends the running agent, as the lines below name it.
    static let startFresh = "Start fresh"

    /// What the running agent runs on; nil with none running.
    var runningLine: String? {
        switch running {
        case .none: nil
        case .model(_, let label): confirmed ? "Last confirmed model: \(label)." : "Started on \(label)."
        case .unstated: "Running on a model it picked itself."
        case .unknown: "Running, but the server does not say on which model."
        }
    }

    var changesProgram: Bool {
        guard session != nil, let activeTemplate, let runtime else { return false }
        return activeTemplate != runtime.name
    }

    /// Set when the next agent would start on another model than the running one: what the person has to do for it.
    var pendingLine: String? {
        if changesProgram, let runtime {
            let next = [runtime.label, model.map(Self.name)].compactMap { $0 }.joined(separator: " · ")
            return "Next reply: \(next). Your chat stays here."
        }
        guard let model else { return nil }
        switch running {
        case .model(let id, _) where id != model.id: return "\(Self.name(model)) will answer your next message."
        case .unstated: return "\(Self.name(model)) will answer your next message."
        default: return nil
        }
    }

    /// One short name for a header: the running agent's model, else the one the next agent starts on. nil when
    /// neither is known by name.
    var short: String? {
        if case .model(_, let label) = running { return label }
        if running == .none, let model { return Self.name(model) }
        return nil
    }

    /// Overview's sentences: the agent program, the model, and the running agent when it differs or is unknown.
    var summary: String {
        var parts = ["AI: \(runtimeLine).", "Model: \(modelLine)."]
        if let pendingLine, let runningLine { parts += [runningLine, pendingLine] }
        else if case .model = running, let runningLine { parts.append(runningLine) }
        else if let runningLine, running != .none { parts.append(runningLine) }
        return parts.joined(separator: " ")
    }
}

extension HerdrClient {
    /// Reads what `agentName`'s bot runs on: the server's templates, the models of the resolved one, the bot's live
    /// agent and what it was launched with.
    func agentReading(agentName: String, ownTemplate: String?, sharedTemplate: String?, ownModel: String?) async throws -> HerdrAgentReading {
        let current = try await workspace(), usable = current.templates.filter { $0.error == nil }
        let resolved = HerdrAgentReading.template(own: ownTemplate, shared: sharedTemplate, in: usable).template
        var offered: [Template.Model] = []
        if let resolved, resolved.takesModel { offered = (try? await models(for: resolved)) ?? resolved.models ?? [] }
        let agent = liveAgent(named: agentName, in: current)
        // The profiles only matter for a running agent, and a failed read of them leaves its model unknown, not wrong.
        let saved = agent == nil ? [] : ((try? await profiles()) ?? [])
        var reading = HerdrAgentReading(templates: usable, ownTemplate: ownTemplate, sharedTemplate: sharedTemplate, ownModel: ownModel, offered: offered, agent: agent, profiles: saved)
        reading.core = current.core
        if let agent, let core = current.core, current.templates.first(where: { $0.name == agent.template })?.modelAgent == "OpenCode",
           let live = try? await sessionModel(agent.ref, core: core), let id = live.effective {
            reading.running = .model(id: id, label: offered.first(where: { $0.id == id })?.label ?? id)
            reading.confirmed = true
        }
        return reading
    }
}
