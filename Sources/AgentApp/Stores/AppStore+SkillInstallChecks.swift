import Foundation

/// A SwarmHub skill install that did not land, kept per bot and skill for the version and variant it asked for. 0.6.0:
/// Hermes's guard refused a heredoc, nothing was recorded, the banner came back and every press re-sent all the skills.
/// A newer bundled version or another variant starts clean.
struct SkillInstallFailure: Codable, Equatable {
    var version: String
    var variant: String?
    var count: Int
    var lastAt: Date
    var reason: String

    /// No retry before this: 15 minutes after the first failure, doubling with each one, at most a day.
    var retryAt: Date { lastAt.addingTimeInterval(min(900 * pow(2, Double(max(count, 1) - 1)), 86_400)) }
}

/// One skill an install turn asked the manager to write, checked against that turn's `skills_installed` block.
struct SkillInstallCheck: Equatable {
    let botID: UUID; let profile: String; let skill: String; let version: SkillVersion; let variant: String?
}

extension AppStore {
    /// The failure recorded for this skill's bundled version and this bot's variant; nil when there is none.
    func skillInstallFailure(_ skill: BundledSkill, for bot: Bot) -> SkillInstallFailure? {
        guard let failure = bot.skillInstallFailures[skill.name], failure.version == skill.version.description,
              failure.variant == SkillLibrary.variant(of: skill, codingOrder: codingOrder(for: bot)) else { return nil }
        return failure
    }

    /// True while a failed install of this version waits out its backoff: it is neither sent again nor offered.
    func skillInstallBackingOff(_ skill: BundledSkill, for bot: Bot) -> Bool {
        skillInstallFailure(skill, for: bot).map { now() < $0.retryAt } ?? false
    }

    /// The skills an install press may send for `bot`: those that need it and are not backing off. A skill whose
    /// installed version and variant already match is never sent again.
    func skillsToInstall(for bot: Bot, among skills: [BundledSkill]? = nil) -> [BundledSkill] {
        (skills ?? self.skills(for: bot)).filter { skillState($0, for: bot).needsAction && !skillInstallBackingOff($0, for: bot) }
    }

    /// Remembers what the install turn about to be sent asks for.
    func noteSkillInstallChecks(_ wanted: [(bot: Bot, skills: [BundledSkill])], manager: Bot) {
        pendingSkillChecks[manager.id] = wanted.flatMap { bot, skills in
            skills.map { SkillInstallCheck(botID: bot.id, profile: profile(of: bot), skill: $0.name, version: $0.version,
                                           variant: SkillLibrary.variant(of: $0, codingOrder: codingOrder(for: bot))) }
        }
    }

    /// The manager's install turn ended. Each skill its block reports at the version and variant asked for clears its
    /// failure; every other one is a failure with the reason (the turn's error, or the start of the reply), and the
    /// error is shown once.
    func finishSkillInstallChecks(manager: Bot, reply: ChatMessage, end: TurnEnd) {
        guard let checks = pendingSkillChecks.removeValue(forKey: manager.id), !checks.isEmpty else { return }
        var reported: [String: [SwarmhubOp.InstalledSkill]] = [:]
        if case .completed = end {
            for case .skillsInstalled(let profile, let rows) in SwarmhubBlock.ops(in: reply.content) ?? [] { reported[profile, default: []] += rows }
        }
        let reason = Self.skillInstallFailureReason(end, reply: reply)
        var failed: [String] = []
        for check in checks {
            guard let bot = bots.first(where: { $0.id == check.botID }) else { continue }
            let landed = reported[check.profile]?.contains {
                $0.name == check.skill && (SkillVersion($0.version).map { $0 >= check.version } ?? false) && (check.variant == nil || $0.variant == check.variant)
            } ?? false
            if landed { bot.skillInstallFailures[check.skill] = nil; continue }
            noteSkillInstallFailure(check.skill, version: check.version.description, variant: check.variant, reason: reason, on: bot)
            failed.append("\(check.skill) for \(bot.name)")
        }
        if !failed.isEmpty { errorMessage = "SwarmHub’s instructions were not installed (\(failed.joined(separator: ", "))): \(reason)" }
        objectWillChange.send(); save()
    }

    /// Counts one more failure of this version and variant (a different one starts at one) and logs it.
    func noteSkillInstallFailure(_ skill: String, version: String, variant: String?, reason: String, on bot: Bot) {
        let previous = bot.skillInstallFailures[skill].flatMap { $0.version == version && $0.variant == variant ? $0.count : nil } ?? 0
        bot.skillInstallFailures[skill] = SkillInstallFailure(version: version, variant: variant, count: previous + 1, lastAt: now(), reason: reason)
        SwarmhubBlock.log.error("Skill install failed: \(skill, privacy: .public) \(version, privacy: .public) on \(bot.hermesProfile ?? "default", privacy: .public) (\(previous + 1)x)")
    }

    /// Why the turn did not confirm the install, in one line: the turn's own failure, else the start of the reply.
    static func skillInstallFailureReason(_ end: TurnEnd, reply: ChatMessage) -> String {
        switch end {
        case .stoppedByUser: return "The install turn was stopped."
        case .failedByBox(let why): return "The install turn failed: \(why)"
        case .error(let error): return "The install turn failed: \(error.localizedDescription)"
        case .endedWithoutTerminal: return "The install turn ended before it finished."
        case .completed:
            let said = SwarmhubBlock.visibleText(reply.finalText).split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            let line = said.count > 160 ? String(said.prefix(159)) + "…" : said
            return line.isEmpty ? "The manager did not confirm the install." : "The manager did not confirm the install: “\(line)”"
        }
    }

    /// Plain words for a failure: what failed, how often, why, and when it may be retried.
    func skillFailureText(_ failure: SkillInstallFailure, skill: BundledSkill) -> String {
        let times = failure.count > 1 ? " \(failure.count) times" : ""
        let retry = now() < failure.retryAt ? " Retry after \(failure.retryAt.formatted(date: .omitted, time: .shortened))." : ""
        return "Installing \(skill.name) v\(failure.version) failed\(times). \(failure.reason)\(retry)"
    }
}
