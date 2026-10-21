import Foundation

/// P42 7: every bot gets the messaging skill. Settings and the manager's banner offer "Install SwarmHub skills on all
/// bots": one confirmation, then one management turn in which the manager writes `swarmhub-messages` and
/// `swarmhub-feedback` into each profile on its connection that lacks them (or has an older version). Bots that have
/// it use bot-msg instead of `hermes -p … chat`.
extension AppStore {
    static let messagingSkills: Set<String> = ["swarmhub-messages", "swarmhub-feedback"]

    /// One bot on the manager's connection and the messaging skills it still needs.
    struct SkillGap: Identifiable, Equatable {
        let bot: Bot; let skills: [BundledSkill]
        var id: UUID { bot.id }
        static func == (a: SkillGap, b: SkillGap) -> Bool { a.bot.id == b.bot.id && a.skills.map(\.name) == b.skills.map(\.name) }
    }

    /// The messaging skills `bot` lacks or has older than this build ships (one whose install failed waits out its backoff).
    func missingMessagingSkills(for bot: Bot) -> [BundledSkill] {
        skillsToInstall(for: bot, among: skills(for: bot).filter { Self.messagingSkills.contains($0.name) })
    }

    /// Every Hermes bot on `manager`'s connection (the manager too) that needs one of them, in sidebar order.
    func messagingSkillGaps(manager: Bot) -> [SkillGap] {
        guard isManager(manager), manager.backend == .hermes else { return [] }
        let target = connection(of: manager)
        return bots.filter { $0.backend == .hermes && !$0.isReadOnlyArchive && connection(of: $0) == target }.compactMap { bot in
            let missing = missingMessagingSkills(for: bot)
            return missing.isEmpty ? nil : SkillGap(bot: bot, skills: missing)
        }
    }

    /// Every connection's manager with gaps (Settings lists them all).
    var managersWithSkillGaps: [Bot] { bots.filter { isManager($0) && !messagingSkillGaps(manager: $0).isEmpty } }

    /// The confirmed press: one management turn for every gap. False when there is nothing to install, the manager is
    /// busy, or a file cannot travel in the heredoc (said in `errorMessage`).
    @discardableResult func installSkillsOnAllBots(manager: Bot) -> Bool {
        let gaps = messagingSkillGaps(manager: manager)
        guard !gaps.isEmpty, isIdle(manager) else { return false }
        let instructions: String
        do {
            if usesStagedSkills(on: connection(of: manager)) {
                guard let text = try stagedSkillInstructions(manager: manager, profiles: gaps.map { gap in
                    .init(name: profile(of: gap.bot), coding_order: codingOrder(for: gap.bot).argument, skills: gap.skills.map(\.name))
                }) else { return false }
                instructions = text
            } else {
                guard let text = try allBotsSkillInstructions(gaps) else { return false }
                instructions = text
                noteSkillInstallChecks(gaps.map { ($0.bot, $0.skills) }, manager: manager)
            }
        } catch {
            errorMessage = error.localizedDescription; return false
        }
        pendingSkillInstalls[manager.id] = SkillInstallTurn(profile: profile(of: manager), instructions: instructions)
        managementExchanges[manager.id] = nil
        open(manager); openThreadID = nil
        guard send(text: AllBotsSkillCopy.request(gaps.count)) else {
            pendingSkillInstalls[manager.id] = nil; pendingSkillChecks[manager.id] = nil; boxInstallTransport.attempts[manager.id] = nil; return false
        }
        return true
    }

    /// The turn: Konrad's one confirmation is the yes for every profile; each profile's commands in turn, and one block
    /// listing a `skills_installed` op per profile.
    func allBotsSkillInstructions(_ gaps: [SkillGap]) throws -> String? {
        var commands: [String] = [], ops: [String] = []
        for gap in gaps {
            guard let part = try skillInstallCommands(gap.skills, profile: profile(of: gap.bot), codingOrder: codingOrder(for: gap.bot)) else { return nil }
            commands += part.commands; ops.append(part.op)
        }
        guard !ops.isEmpty else { return nil }
        let names = gaps.map { "\(profile(of: $0.bot)) (\($0.bot.name))" }.joined(separator: ", ")
        return """
        Konrad pressed “\(AllBotsSkillCopy.button)” in SwarmHub and confirmed it once for all of these profiles: \(names). \
        That confirmation is his yes for every one of them: do not ask again. Run exactly these commands in your terminal with \
        the shell (not the file tool), change nothing else, then reply in one short line and end with the block below. \
        Report whether the peer plugins activated; if the gateway did not reload them, mention that a reload is needed for held delivery.
        ````sh
        \(commands.joined(separator: "\n"))
        ````
        ```swarmhub
        [\(ops.joined(separator: ","))]
        ```
        """
    }
}

enum AllBotsSkillCopy {
    static let button = "Install SwarmHub skills on all bots"
    static let title = "SwarmHub skills on all bots"
    static func banner(_ count: Int) -> String {
        count == 1 ? "1 bot is missing SwarmHub’s messaging skills" : "\(count) bots are missing SwarmHub’s messaging skills"
    }
    static func request(_ count: Int) -> String { "Install SwarmHub skills on \(count == 1 ? "1 bot" : "all \(count) bots")." }
    static func missing(_ skills: [BundledSkill]) -> String { "Missing: " + skills.map(\.name).joined(separator: ", ") }
    static let confirm = "The manager writes swarmhub-messages and swarmhub-feedback into each of these bots’ profiles. Hermes itself is not changed."
    static let allSet = "Every bot has SwarmHub’s messaging skills."
    static let needsManager = "Needs a manager bot on the connection to install."
}
