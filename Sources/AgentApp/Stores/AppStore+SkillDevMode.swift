import Foundation

/// Skill dev mode (Mac, per bot; see `SkillDevMode`): the toggle, which skills show as modified locally, Reset to bundled,
/// and what the box reported keeping. Off, nothing here changes an install: no skill reads as modified, no marker is
/// taken from terminal output, and the commands and profiles.json sent are those of before.
extension AppStore {
    func setSkillDevMode(_ on: Bool, for bot: Bot) {
        guard bot.skillDevMode != on else { return }
        bot.skillDevMode = on
        if !on { bot.skillsModifiedLocally = [] } // off: the next install overwrites them, as it always did
        objectWillChange.send(); save()
    }

    /// The box kept this skill because the bot changed it there: shown as "modified locally", never offered or sent as an
    /// update (only Reset to bundled replaces it).
    func isModifiedLocally(_ skill: BundledSkill, for bot: Bot) -> Bool {
        bot.skillDevMode && bot.skillsModifiedLocally.contains(skill.name)
    }

    /// Reset to bundled: one install turn for this skill alone that replaces the bot's copy with the bundled one (on a
    /// staged connection, the signed bundle's), deletes its dev-overrides folder and records the new baseline.
    @discardableResult func resetSkillToBundled(_ skill: BundledSkill, for bot: Bot) -> Bool {
        guard skills(for: bot).contains(where: { $0.name == skill.name }) else { return false }
        return installSkills(for: bot, reset: skill)
    }

    /// The staged profile row for `bot`: dev mode and a reset only when set, so with dev mode off the row is as before.
    func stagedProfile(for bot: Bot, skills names: [String], reset: BundledSkill? = nil) -> StagedInstall.Profile {
        .init(name: profile(of: bot), coding_order: codingOrder(for: bot).argument, skills: names,
              dev_mode: bot.skillDevMode ? true : nil, reset: reset.map { [$0.name] })
    }

    /// A legacy install turn's terminal result: each marker the dev-mode guard printed for a skill this turn asked for,
    /// on a bot with dev mode on, is what the box did with it (kept, or the guard failed and nothing was written).
    func noteSkillDevTool(_ tool: ToolEvent, manager: Bot) {
        guard tool.phase == .completed || tool.phase == .failed, let output = tool.result, output.contains("SWARMHUB_DEV_"),
              let checks = pendingSkillChecks[manager.id] else { return }
        for (outcome, key) in SkillDevMode.outcomes(in: output) {
            guard let check = checks.first(where: { "\($0.profile)/\($0.skill)" == key }),
                  bots.first(where: { $0.id == check.botID })?.skillDevMode == true else { continue }
            skillDevOutcomes[manager.id, default: [:]][key] = outcome
        }
    }

    /// A finished reply's `skills_installed` op without the skills the box kept or did not write this turn (the block
    /// was written before that). Taken when the reply ends, before `finishSkillInstallChecks` consumes the outcomes;
    /// the op itself is applied later, in a task.
    func withoutSkillDevOutcomes(_ op: SwarmhubOp, manager: Bot) -> SwarmhubOp {
        guard case .skillsInstalled(let profile, let rows) = op, let outcomes = skillDevOutcomes[manager.id], !outcomes.isEmpty else { return op }
        return .skillsInstalled(bot: profile, skills: rows.filter { outcomes["\(profile)/\($0.name)"] == nil })
    }
}
