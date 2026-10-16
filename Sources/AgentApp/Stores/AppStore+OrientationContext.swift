import Foundation

/// P49: what the orientation turn tells a new bot, read from the store: its own card, its installed SwarmHub skills and
/// connected apps (P48 names), the other bots, the coordinator and the quiet hours. Never a key, never the whole SOUL.
extension AppStore {
    /// The bots that can coordinate: Hermes bots in use (not samples, archives or retired ones).
    var coordinatorCandidates: [Bot] {
        bots.filter { $0.backend == .hermes && !$0.isReadOnlyArchive && !$0.isDemo && !$0.retiredOnBox && !$0.isGrokHistoryOnly }
    }

    /// The default: the bot named Jarvis when there is exactly one, else the manager bot, else none. Never `bot` itself.
    func defaultCoordinator(for bot: Bot?) -> Bot? {
        let candidates = coordinatorCandidates
        let jarvises = candidates.filter { $0.name.trimmingCharacters(in: .whitespaces).lowercased() == "jarvis" }
        if jarvises.count == 1, jarvises[0] !== bot { return jarvises[0] }
        let manager = bot.flatMap { manager(for: $0) } ?? candidates.first(where: isManager)
        return manager === bot ? nil : manager
    }

    func orientationCoordinator(for bot: Bot) -> Bot? { defaultCoordinator(for: bot) }

    var quietHours: QuietHours { QuietHours() }

    /// The team (group chat name) the coordinator works in now, when it is a member of a running team.
    func coordinatorTeam(_ coordinator: Bot) -> String? {
        let team = workflows.values.filter { $0.isTeam && !$0.isFinished }.sorted { $0.createdAt < $1.createdAt }
            .first { workflowMembers($0).contains(coordinator) }
        return team.flatMap { workflow in groups.first { $0.id == workflow.groupID }?.name }
    }

    func orientationContext(for bot: Bot) -> OrientationContext {
        var context = OrientationContext(userName: userName, name: bot.name, profile: bot.backend == .hermes ? bot.hermesProfile ?? "default" : nil,
                                         description: bot.botDescription.trimmingCharacters(in: .whitespacesAndNewlines))
        let box = bot.boxInstructions?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let persona = bot.persona.trimmingCharacters(in: .whitespacesAndNewlines)
        let instructions = !box.isEmpty ? box : persona == Bot.defaultPersona ? "" : persona
        (context.instructionsTitle, context.instructionsLines) = OrientationPrompt.excerpt(instructions)
        context.skills = bot.installedSkills.keys.sorted()
        context.apps = connectedApps.enabledAccounts(for: bot.id).sorted { $0.key < $1.key }
            .map { "\(connectedApps.appName($0.key)) (\($0.value.joined(separator: ", ")))" }
        let teammate = { (other: Bot) in
            OrientationContext.Teammate(name: other.name, profile: other.backend == .hermes ? other.hermesProfile ?? "default" : nil,
                                        description: other.botDescription.isEmpty ? other.title : other.botDescription)
        }
        context.teammates = bots.filter { $0 !== bot && !$0.isReadOnlyArchive && !$0.isDemo && !$0.retiredOnBox && !$0.isGrokHistoryOnly }.map(teammate)
        if let coordinator = orientationCoordinator(for: bot) {
            context.coordinator = teammate(coordinator); context.coordinatorTeam = coordinatorTeam(coordinator)
        }
        context.timeZone = heartbeatTimeZone; context.quietHours = quietHours
        return context
    }
}
