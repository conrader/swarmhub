import Foundation

/// P42 7: every bot gets the messaging skill. Settings and the manager's banner offer "Install SwarmHub skills on all
/// bots": one confirmation, then one management turn in which the manager writes `swarmhub-messages` and
/// `swarmhub-feedback` into each profile on its connection that lacks them (or has an older version). Bots that have
/// it use bot-msg instead of `hermes -p … chat`.
extension AppStore {
    static let messagingSkills: Set<String> = ["swarmhub-messages", "swarmhub-feedback"]

    /// One bot on the manager's connection, the messaging skills it still needs, and those a press sends now.
    struct SkillGap: Identifiable, Equatable {
        let bot: Bot; let skills: [BundledSkill]
        /// `skills` without those whose failed install waits out its backoff (still missing, never counted as done).
        let installable: [BundledSkill]
        var id: UUID { bot.id }
        static func == (a: SkillGap, b: SkillGap) -> Bool {
            a.bot.id == b.bot.id && a.skills.map(\.name) == b.skills.map(\.name) && a.installable.map(\.name) == b.installable.map(\.name)
        }
    }

    /// The messaging skills `bot` lacks or has older than this build ships, including one whose install failed; not one
    /// it modified locally in skill dev mode (that copy is the bot's own until Reset to bundled).
    func missingMessagingSkills(for bot: Bot) -> [BundledSkill] {
        skills(for: bot).filter { Self.messagingSkills.contains($0.name) && skillState($0, for: bot).needsAction && !isModifiedLocally($0, for: bot) }
    }

    /// Every Hermes bot on `manager`'s connection (the manager too) that needs one of them, in sidebar order. A bot whose
    /// install failed stays listed while it backs off; it only has nothing to send yet.
    func messagingSkillGaps(manager: Bot) -> [SkillGap] {
        guard isManager(manager), manager.backend == .hermes else { return [] }
        let target = connection(of: manager)
        return bots.filter { $0.backend == .hermes && !$0.isReadOnlyArchive && connection(of: $0) == target }.compactMap { bot in
            let missing = missingMessagingSkills(for: bot)
            return missing.isEmpty ? nil : SkillGap(bot: bot, skills: missing, installable: skillsToInstall(for: bot, among: missing))
        }
    }

    /// Every connection's manager with gaps (Settings lists them all).
    var managersWithSkillGaps: [Bot] { bots.filter { isManager($0) && !messagingSkillGaps(manager: $0).isEmpty } }

    /// The all-bots button works: the manager is idle and some gap is not backing off.
    func canInstallSkillsOnAllBots(manager: Bot) -> Bool {
        isIdle(manager) && messagingSkillGaps(manager: manager).contains { !$0.installable.isEmpty }
    }

    /// When a backoff on `manager`'s connection ends, so the all-bots views redraw and offer the press again.
    func messagingRetryDates(manager: Bot) -> [Date] {
        messagingSkillGaps(manager: manager).flatMap { skillRetryDates($0.skills, for: $0.bot) }.sorted()
    }

    /// One bot and the messaging skills it needs whose install failed and waits out its backoff: why, and when Retry is back.
    struct SkillWait: Identifiable {
        let bot: Bot; let skills: [BundledSkill]; let retryAt: Date; let reason: String
        var id: UUID { bot.id }
    }

    /// Every Hermes bot (on `manager`'s connection, else on any) with a needed messaging skill whose failed install is
    /// backing off; the gaps leave those out, so without this a failed bot would read as having the skills.
    func messagingSkillWaits(manager: Bot? = nil) -> [SkillWait] {
        let target = manager.map { connection(of: $0) }
        return bots.filter { $0.backend == .hermes && !$0.isReadOnlyArchive && (target == nil || connection(of: $0) == target) }.compactMap { bot in
            let waiting = skills(for: bot).filter {
                Self.messagingSkills.contains($0.name) && skillState($0, for: bot).needsAction && skillInstallBackingOff($0, for: bot)
            }
            guard let first = waiting.compactMap({ skillInstallFailure($0, for: bot) }).min(by: { $0.retryAt < $1.retryAt }) else { return nil }
            return SkillWait(bot: bot, skills: waiting, retryAt: first.retryAt, reason: first.reason)
        }
    }

    /// Settings' line when there is nothing to install or wait for: "needs a manager" or "every bot has them"; nil while
    /// a connection has gaps or a failed install is waiting (their rows say so).
    var allBotsSkillsSummary: String? {
        guard managersWithSkillGaps.isEmpty, messagingSkillWaits().isEmpty else { return nil }
        let unmanaged = bots.contains { $0.backend == .hermes && manager(for: $0) == nil && !missingMessagingSkills(for: $0).isEmpty }
        return unmanaged ? AllBotsSkillCopy.needsManager : AllBotsSkillCopy.allSet
    }

    /// The confirmed press: one management turn for every gap that is not backing off. False when there is nothing to
    /// install, the manager is busy, or a file cannot travel in the heredoc (said in `errorMessage`).
    @discardableResult func installSkillsOnAllBots(manager: Bot) -> Bool {
        let gaps = messagingSkillGaps(manager: manager).filter { !$0.installable.isEmpty }
        guard !gaps.isEmpty, isIdle(manager) else { return false }
        let instructions: String
        do {
            if usesStagedSkills(on: connection(of: manager)) {
                guard let text = try stagedSkillInstructions(manager: manager, profiles: gaps.map { gap in
                    stagedProfile(for: gap.bot, skills: gap.skills.map(\.name))
                }) else { return false }
                instructions = text
            } else {
                guard let text = try allBotsSkillInstructions(gaps) else { return false }
                instructions = text
                noteSkillInstallChecks(gaps.map { ($0.bot, $0.installable) }, manager: manager)
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
            guard let part = try skillInstallCommands(gap.installable, profile: profile(of: gap.bot), codingOrder: codingOrder(for: gap.bot),
                                                      devMode: gap.bot.skillDevMode) else { return nil }
            commands += part.commands; ops.append(part.op)
        }
        guard !ops.isEmpty else { return nil }
        let names = gaps.map { "\(profile(of: $0.bot)) (\($0.bot.name))" }.joined(separator: ", ")
        let devNote = gaps.contains { $0.bot.skillDevMode } ? " Skill dev mode is on for some of these bots: a skill a bot changed on this box is kept, not overwritten, and its line says so; that is expected, not an error to fix." : ""
        return """
        Konrad pressed “\(AllBotsSkillCopy.button)” in SwarmHub and confirmed it once for all of these profiles: \(names). \
        That confirmation is his yes for every one of them: do not ask again. Run exactly these commands in your terminal with \
        the shell (not the file tool), change nothing else, then reply in one short line and end with the block below. \
        Report whether the peer plugins activated; if the gateway did not reload them, mention that a reload is needed for held delivery.\(devNote)
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
    /// After the bot names while every gap's install failed and backs off.
    static func retry(_ date: Date?) -> String? { date.map { " · install failed, retry after \($0.formatted(date: .omitted, time: .shortened))" } }
    static func missing(_ skills: [BundledSkill]) -> String { "Missing: " + skills.map(\.name).joined(separator: ", ") }
    static func waiting(_ skills: [BundledSkill], retryAt: Date) -> String {
        "Install failed: " + skills.map(\.name).joined(separator: ", ") + " · retry after \(retryAt.formatted(date: .omitted, time: .shortened))"
    }
    static let confirm = "The manager writes swarmhub-messages and swarmhub-feedback into each of these bots’ profiles. Hermes itself is not changed."
    static let allSet = "Every bot has SwarmHub’s messaging skills."
    static let needsManager = "Needs a manager bot on the connection to install."
}
