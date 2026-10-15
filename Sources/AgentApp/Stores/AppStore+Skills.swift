import Foundation

/// P31: why an Install was refused before anything was sent.
enum SkillInstallError: LocalizedError, Equatable {
    case markerInFile(skill: String, path: String)
    var errorDescription: String? {
        switch self {
        case .markerInFile(let skill, let path): "Can’t install \(skill): its file \(path) contains SWARMHUB_EOF, which would cut it short on the box."
        }
    }
}

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

    /// The bundled skills meant for this bot: `swarmhub-manager` only for its connection's manager; the others (P31:
    /// `swarmhub-coding`) for every Hermes bot.
    func skills(for bot: Bot) -> [BundledSkill] {
        guard bot.backend == .hermes, !bot.isReadOnlyArchive else { return [] }
        return skillLibrary.filter { $0.name != SkillLibrary.managerSkill || isManager(bot) }
    }

    /// P31 D1: this bot's coding agent order (its own, else the SwarmHub-wide default, else Claude Code first).
    func codingOrder(for bot: Bot) -> CodingOrder {
        CodingOrder.resolve(bot: bot.modelSettings?.codingAgent, appDefault: modelDefaults.codingAgent).order
    }

    func skillState(_ skill: BundledSkill, for bot: Bot) -> SkillInstallState {
        SkillLibrary.state(installed: bot.installedSkills[skill.name], bundled: skill.version, installedVariant: bot.installedSkillVariants[skill.name],
                           wantedVariant: SkillLibrary.variant(of: skill, codingOrder: codingOrder(for: bot)))
    }

    /// The banner above a bot's composer: for its connection's manager, the first of its skills (its own
    /// `swarmhub-manager` first) that needs installing or updating; for any other bot (P31), an installed skill that
    /// needs updating, e.g. after its coding order changed (a missing one is offered in the editor only). Hidden while
    /// "Not now" covers that version and variant.
    func skillBanner(for bot: Bot) -> (skill: BundledSkill, state: SkillInstallState)? {
        let manages = isManager(bot)
        guard manages || manager(for: bot) != nil else { return nil }
        let ordered = skills(for: bot).sorted { ($0.name == SkillLibrary.managerSkill ? 0 : 1) < ($1.name == SkillLibrary.managerSkill ? 0 : 1) }
        for skill in ordered {
            let state = skillState(skill, for: bot)
            guard state.needsAction, manages || state != .missing else { continue }
            guard bot.skillBannerSnoozed != snoozeKey(skill, for: bot) else { continue }
            return (skill, state)
        }
        return nil
    }

    /// "Not now": hidden until a newer bundled version ships (or, P31, the skill's variant changes again).
    func snoozeSkillBanner(for bot: Bot) {
        guard let banner = skillBanner(for: bot) else { return }
        bot.skillBannerSnoozed = snoozeKey(banner.skill, for: bot); objectWillChange.send(); save()
    }

    /// The bare version for a skill without a variant (what P27 stored), else name, version and variant.
    private func snoozeKey(_ skill: BundledSkill, for bot: Bot) -> String {
        guard let variant = SkillLibrary.variant(of: skill, codingOrder: codingOrder(for: bot)) else { return skill.version.description }
        return "\(skill.name) \(skill.version) \(variant)"
    }

    /// Plain words for the banner and the editor.
    static func skillBannerText(bot: String, state: SkillInstallState) -> String {
        state == .missing ? "SwarmHub’s instructions for \(bot) need installing" : "SwarmHub’s instructions for \(bot) need updating"
    }

    // MARK: Install

    /// Install pressed (banner or editor): the bot's connection manager gets one management turn that writes every skill
    /// meant for `bot`. False when there is no manager, nothing to install, or another turn is still running; a skill
    /// whose content cannot travel in the heredoc also says so in `errorMessage`.
    @discardableResult func installSkills(for bot: Bot) -> Bool {
        guard let manager = manager(for: bot), isIdle(manager) else { return false }
        let profile = bot.hermesProfile ?? "default"
        let instructions: String
        do {
            guard let text = try skillInstallInstructions(skills(for: bot), profile: profile, botName: bot.name, codingOrder: codingOrder(for: bot)) else { return false }
            instructions = text
        } catch {
            SwarmhubBlock.log.error("Skill install refused: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription; return false
        }
        pendingSkillInstalls[manager.id] = SkillInstallTurn(profile: profile, instructions: instructions)
        managementExchanges[manager.id] = nil
        open(manager); openThreadID = nil
        guard send(text: "Install SwarmHub’s instructions for \(bot.name).") else { pendingSkillInstalls[manager.id] = nil; return false }
        return true
    }

    /// The install turn's instructions: Konrad's press is the yes, then for each skill `mkdir -p`, a quoted heredoc per
    /// file (SKILL.md rendered for this bot, then its extra files as shipped), `chmod 755` for `scripts/`, and the
    /// `skills_installed` block to end with (P31: with each skill's variant, e.g. the coding order). Nil when a skill cannot
    /// be rendered; throws when a file contains the heredoc end marker, which would cut the file short on the box.
    func skillInstallInstructions(_ skills: [BundledSkill], profile: String, botName: String, codingOrder: CodingOrder = .standard) throws -> String? {
        guard let install = try skillInstallCommands(skills, profile: profile, codingOrder: codingOrder) else { return nil }
        return """
        Konrad pressed Install in SwarmHub to install SwarmHub’s instructions (skills) for \(botName) (profile `\(profile)`). \
        That press is his yes: do not ask again. Run exactly these commands in your terminal with the shell (not the file tool), \
        change nothing else, then reply in one short line and end with the block below.
        ````sh
        \(install.commands.joined(separator: "\n"))
        ````
        ```swarmhub
        \(install.op)
        ```
        """
    }

    /// One profile's part of an install turn: its shell commands and its `skills_installed` op (P42: shared by the
    /// all-bots install). Nil when a skill cannot be rendered or the profile name is not valid.
    func skillInstallCommands(_ skills: [BundledSkill], profile: String, codingOrder: CodingOrder = .standard) throws -> (commands: [String], op: String)? {
        guard !skills.isEmpty, HermesKeyPaste.isValidProfileName(profile) else { return nil }
        var commands: [String] = []
        for skill in skills {
            guard let content = SkillLibrary.render(skill, forProfile: profile, managerTemplate: managerTemplateOverride ?? Self.bundledManagerTemplate,
                                                    codingOrder: codingOrder) else { return nil }
            let folder = SkillLibrary.installPath(skill.name, profile: profile)
            let files = [SkillFile(path: "SKILL.md", content: content)] + skill.files.map { SkillLibrary.render($0, forProfile: profile) }
            if let clash = files.first(where: { $0.content.contains(Self.heredocEnd) }) { throw SkillInstallError.markerInFile(skill: skill.name, path: clash.path) }
            let folders = Set(files.map { ($0.path as NSString).deletingLastPathComponent }.filter { !$0.isEmpty })
            commands.append("mkdir -p " + ([folder] + folders.sorted().map { "\(folder)/\($0)" }).joined(separator: " "))
            for file in files {
                let text = file.content.hasSuffix("\n") ? file.content : file.content + "\n"
                commands.append("cat > \(folder)/\(file.path) <<'\(Self.heredocEnd)'\n\(text)\(Self.heredocEnd)")
            }
            let executables = files.filter(\.isExecutable).map { "\(folder)/\($0.path)" }
            if !executables.isEmpty { commands.append("chmod 755 " + executables.joined(separator: " ")) }
        }
        let listed = skills.map { skill in
            let variant = SkillLibrary.variant(of: skill, codingOrder: codingOrder).map { #","variant":"\#($0)""# } ?? ""
            return #"{"name":"\#(skill.name)","version":"\#(skill.version)"\#(variant)}"#
        }.joined(separator: ",")
        return (commands, #"{"op":"skills_installed","bot":"\#(profile)","skills":[\#(listed)]}"#)
    }

    /// The core manager text (the skill's SKILL.md body).
    static var bundledManagerTemplate: String? { BotManagerText.template() }

    /// P31 C: what a quiet or pressed box/accounts turn cuts its recipe from: the override (tests), else that recipe file
    /// only, never the whole manager text.
    func managerRecipeTemplate(_ recipe: BotManagerText.Recipe) -> String? { managerTemplateOverride ?? BotManagerText.recipe(recipe) }

    /// Records a `skills_installed` op for the bot bound to `profile` on the manager's connection: only library skills,
    /// never newer than this build ships (the reply carries names and versions only; the content is never read from it).
    func recordInstalled(_ installed: [SwarmhubOp.InstalledSkill], profile: String, manager: Bot) {
        guard let bot = boundBot(profile, manager: manager) else { return }
        for row in installed {
            guard let skill = skillLibrary.first(where: { $0.name == row.name }), let version = SkillVersion(row.version) else { continue }
            bot.installedSkills[row.name] = min(version, skill.version).description
            bot.installedSkillVariants[row.name] = row.variant
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
        let variants = bot.installedSkillVariants.filter { record[$0.key] != nil }
        guard record != bot.installedSkills || variants != bot.installedSkillVariants else { return }
        bot.installedSkills = record; bot.installedSkillVariants = variants; objectWillChange.send(); save()
    }
}
