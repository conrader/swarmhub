import Foundation

/// P31 D+E: each box's bot models and capacity, read by the connection's manager in quiet turns ("Check") and kept in
/// store.json; a sub-agent model change and the coding job limit are asked in the manager's own chat, where the manager
/// asks Konrad first. Hermes stays vanilla: read-only shell recipes, `hermes config set` through the P30 recipe and
/// `~/.hermes/swarmhub/coding.conf`.
extension AppStore {
    func boxReadings(on target: String) -> BoxReadings { boxReadings[target] ?? BoxReadings() }

    /// The Overview's and Settings' Sub-agents line for one Hermes bot.
    func subAgentLine(for bot: Bot, delegationOff: Bool) -> SubAgentLine {
        let readings = boxReadings(on: connection(of: bot))
        return SubAgentLine(models: readings.models(for: bot.hermesProfile ?? "default"), reportedAt: readings.modelsAt, delegationOff: delegationOff)
    }

    /// Stores `models` and `box_capacity` ops for `connection`; true when the ops held one.
    @discardableResult func absorbBoxReadings(_ ops: [SwarmhubOp], connection target: String) -> Bool {
        var readings = boxReadings(on: target), found = false
        for op in ops {
            switch op {
            case .models(let rows): readings.models = rows; readings.modelsAt = now(); found = true
            case .boxCapacity(let report): readings.capacity = report; readings.capacityAt = now(); found = true
            default: continue
            }
        }
        guard found else { return false }
        boxReadings[target] = readings
        objectWillChange.send(); save()
        return true
    }

    // MARK: Quiet checks

    /// "Check" on a Sub-agents line: the manager runs "Bot models" in a quiet turn.
    @discardableResult func checkModels(on target: String) async -> Bool {
        await runBoxCheck(.models(target), on: target, recipe: .models, request: "Report each bot's model and coding model for \(AppConstants.name).",
                          instructions: BoxReadingsTurns.modelsInstructions)
    }

    /// "Check" on the capacity block: the manager runs "Box capacity" in a quiet turn.
    @discardableResult func checkCapacity(on target: String) async -> Bool {
        await runBoxCheck(.capacity(target), on: target, recipe: .capacity, request: "Report this box's capacity for \(AppConstants.name).",
                          instructions: BoxReadingsTurns.capacityInstructions)
    }

    private func runBoxCheck(_ check: BoxCheck, on target: String, recipe: BotManagerText.Recipe, request: String,
                             instructions make: (String) -> String?) async -> Bool {
        guard !boxChecks.contains(check) else { return false }
        guard let manager = ensureManager(on: target), manager.backend == .hermes, let backend = try? backend(for: manager),
              let template = managerRecipeTemplate(recipe), let instructions = make(template) else {
            boxCheckProblems[check] = BoxReadingsCopy.noManager; return false
        }
        boxChecks.insert(check); boxCheckProblems[check] = nil
        let ops = await quietBoxTurn(backend, persona: manager.outboundPersona, request: request, instructions: instructions)
        boxChecks.remove(check)
        let wanted = ops?.contains { op in
            switch (op, check) {
            case (.models, .models), (.boxCapacity, .capacity): true
            default: false
            }
        } == true
        if let ops { absorbBoxReadings(ops, connection: target) }
        if !wanted { boxCheckProblems[check] = BoxReadingsCopy.noAnswer }
        return wanted
    }

    // MARK: Asked in the manager's chat

    /// The sheet's "Ask <manager>": one visible turn carrying the P30 recipe for sub-agents. The manager asks Konrad
    /// first; when its log reads DONE the lines refresh (`refreshModelsAfterRecipe`).
    @discardableResult func requestSubAgentModel(_ change: SubAgentModelChange, manager: Bot) -> Bool {
        guard let core = managerCoreTemplate,
              let instructions = BoxReadingsTurns.subAgentInstructions(change, core: core) else { return false }
        return startRecipeTurn(change.request, instructions: instructions, manager: manager)
    }

    /// "Use advised" / "Set limit…": one visible turn; the manager asks first, writes `SLOTS` and reports the capacity
    /// again, which updates the block.
    @discardableResult func requestCodingLimit(_ slots: Int, on target: String) -> Bool {
        guard let manager = ensureManager(on: target), let template = managerRecipeTemplate(.capacity),
              let instructions = BoxReadingsTurns.limitInstructions(slots, template: template) else { return false }
        let jobs = slots == 1 ? "1 coding job" : "\(slots) coding jobs"
        return startRecipeTurn("Let this box run \(jobs) at a time.", instructions: instructions, manager: manager)
    }

    /// Opens the manager's chat and sends `request`; that turn and its follow-ups carry `instructions`.
    private func startRecipeTurn(_ request: String, instructions: String, manager: Bot) -> Bool {
        guard isManager(manager), manager.backend == .hermes, isIdle(manager) else { return false }
        managementExchanges[manager.id] = ManagementExchange(openedAt: now(), awaitingOpening: true, recipe: instructions)
        open(manager); openThreadID = nil
        guard send(text: request) else { managementExchanges[manager.id] = nil; return false }
        return true
    }
}

/// P31 D: what a bot's Coding model line (`delegation.model`) says. Sub-agents turned off (P11 `delegation` toolset) wins; a pin shows with
/// the day it was reported; no pin means the bot's own model; no report yet keeps the box-only text and offers Check.
struct SubAgentLine: Equatable {
    let text: String
    let offersCheck: Bool

    init(models: BotModels?, reportedAt: Date?, delegationOff: Bool) {
        if delegationOff { text = ModelRoleReason.subAgentsOff.text; offersCheck = false; return }
        guard let models else { text = "Coding model: \(ModelRoleReason.boxOnly.text)"; offersCheck = true; return }
        offersCheck = false
        if !models.subModel.isEmpty {
            text = "Coding model: \(models.subModel)" + (reportedAt.map { " (reported \(BoxReadingsCopy.day($0)))" } ?? "")
        } else {
            text = "Coding model: same as this bot" + (models.model.isEmpty ? "" : " (\(models.model))")
        }
    }
}
