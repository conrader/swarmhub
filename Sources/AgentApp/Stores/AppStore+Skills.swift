import Foundation

/// An Install waiting for the manager's next turn: the bot it is for and the turn's instructions.
struct SkillInstallTurn: Equatable { let profile: String; let instructions: String }

/// P27: SwarmHub skills (`Resources/Skills`) installed into bots' own profiles through their connection's manager bot.
/// Hermes is never changed; the manager writes ordinary SKILL.md files with the shell. The app records name → version
/// per bot from the manager's `skills_installed` block and, when `GET /v1/skills` works, from the box itself.
extension AppStore {
    private static let cachedLibrary = SkillLibrary.bundled()
    static let skillPointer = "Use your swarmhub-manager skill for this; end with a swarmhub block."
    static let heredocEnd = "SWARMHUB_EOF"

    var skillLibrary: [BundledSkill] { skillLibraryOverride ?? Self.cachedLibrary }

    /// The bundled skills meant for this bot: `swarmhub-manager` only for its connection's manager.
    func skills(for bot: Bot) -> [BundledSkill] {
        guard bot.backend == .hermes, !bot.isReadOnlyArchive else { return [] }
        return skillLibrary.filter { $0.name != SkillLibrary.managerSkill || isManager(bot) }
    }

    func skillState(_ skill: BundledSkill, for bot: Bot) -> SkillInstallState {
        SkillLibrary.state(installed: bot.installedSkills[skill.name], bundled: skill.version)
    }

    /// The manager's own `swarmhub-manager` when it needs installing or updating and "Not now" did not hide this version.
    func skillBanner(for bot: Bot) -> (skill: BundledSkill, state: SkillInstallState)? {
        guard isManager(bot), let skill = skills(for: bot).first(where: { $0.name == SkillLibrary.managerSkill }) else { return nil }
        let state = skillState(skill, for: bot)
        guard state.needsAction, bot.skillBannerSnoozed != skill.version.description else { return nil }
        return (skill, state)
    }

    /// "Not now": hidden until a newer bundled version ships.
    func snoozeSkillBanner(for bot: Bot) {
        guard let banner = skillBanner(for: bot) else { return }
        bot.skillBannerSnoozed = banner.skill.version.description; objectWillChange.send(); save()
    }

    /// Plain words for the banner and the editor.
    static func skillBannerText(bot: String, state: SkillInstallState) -> String {
        state == .missing ? "SwarmHub’s instructions for \(bot) need installing" : "SwarmHub’s instructions for \(bot) need updating"
    }

    // MARK: Install

    /// Install pressed (banner or editor): the bot's connection manager gets one management turn that writes every skill
    /// meant for `bot`. False when there is no manager, nothing to install, or another turn is still running.
    @discardableResult func installSkills(for bot: Bot) -> Bool {
        guard let manager = manager(for: bot), isIdle else { return false }
        let profile = bot.hermesProfile ?? "default"
        guard let instructions = skillInstallInstructions(skills(for: bot), profile: profile, botName: bot.name) else { return false }
        pendingSkillInstalls[manager.id] = SkillInstallTurn(profile: profile, instructions: instructions)
        managementExchanges[manager.id] = nil
        open(manager); openThreadID = nil
        guard send(text: "Install SwarmHub’s instructions for \(bot.name).") else { pendingSkillInstalls[manager.id] = nil; return false }
        return true
    }

    /// The install turn's instructions: Konrad's press is the yes, then for each skill `mkdir -p` and a quoted heredoc
    /// with the library's rendered content, and the `skills_installed` block to end with. Nil when a skill cannot be
    /// rendered or its text would close the heredoc early.
    func skillInstallInstructions(_ skills: [BundledSkill], profile: String, botName: String) -> String? {
        guard !skills.isEmpty, HermesKeyPaste.isValidProfileName(profile) else { return nil }
        var commands: [String] = []
        for skill in skills {
            guard let content = SkillLibrary.render(skill, forProfile: profile, managerTemplate: managerTemplateOverride ?? Self.bundledManagerTemplate),
                  !content.components(separatedBy: "\n").contains(Self.heredocEnd) else { return nil }
            let folder = SkillLibrary.installPath(skill.name, profile: profile)
            commands.append("mkdir -p \(folder)\ncat > \(folder)/SKILL.md <<'\(Self.heredocEnd)'\n\(content)\(Self.heredocEnd)")
        }
        let listed = skills.map { #"{"name":"\#($0.name)","version":"\#($0.version)"}"# }.joined(separator: ",")
        return """
        Konrad pressed Install in SwarmHub to install SwarmHub’s instructions (skills) for \(botName) (profile `\(profile)`). \
        That press is his yes: do not ask again. Run exactly these commands in your terminal with the shell (not the file tool), \
        change nothing else, then reply in one short line and end with the block below.
        ````sh
        \(commands.joined(separator: "\n"))
        ````
        ```swarmhub
        {"op":"skills_installed","bot":"\(profile)","skills":[\(listed)]}
        ```
        """
    }

    static var bundledManagerTemplate: String? { BotManagerText.template() }

    /// Records a `skills_installed` op for the bot bound to `profile` on the manager's connection: only library skills,
    /// never newer than this build ships (the reply carries names and versions only; the content is never read from it).
    func recordInstalled(_ installed: [SwarmhubOp.InstalledSkill], profile: String, manager: Bot) {
        guard let bot = boundBot(profile, manager: manager) else { return }
        for row in installed {
            guard let skill = skillLibrary.first(where: { $0.name == row.name }), let version = SkillVersion(row.version) else { continue }
            bot.installedSkills[row.name] = min(version, skill.version).description
        }
    }

    // MARK: Confirm from the box

    /// Opening the editor's SwarmHub skills section: when `GET /v1/skills` answers, its `swarmhub` category becomes the
    /// record (a version the description advertises, else the recorded one; a library skill not listed is missing).
    /// A 500 (stock 0.22.0) or any other failure keeps the record silently.
    func refreshInstalledSkills(for bot: Bot) async {
        guard bot.backend == .hermes, !skills(for: bot).isEmpty, let backend = try? backend(for: bot) as? HermesBackend,
              let listed = try? await backend.skills() else { return }
        let ours = listed.filter { $0.category == SkillLibrary.category }
        var record: [String: String] = [:]
        for skill in skillLibrary {
            guard let row = ours.first(where: { $0.name == skill.name }) else { continue }
            let advertised = (row.version ?? SkillLibrary.advertisedVersion(in: row.description)).flatMap(SkillVersion.init)
            record[skill.name] = advertised.map { min($0, skill.version).description } ?? bot.installedSkills[skill.name] ?? "0.0.0"
        }
        guard record != bot.installedSkills else { return }
        bot.installedSkills = record; objectWillChange.send(); save()
    }
}
