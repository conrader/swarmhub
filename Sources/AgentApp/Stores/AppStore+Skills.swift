import Foundation
import SwarmHubCore

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
        CodingOrder.resolve(bot: bot.modelSettings?.codingAgent, appDefault: modelDefaults.codingAgent, fallback: configuredCodingOrder).order
    }

    func skillState(_ skill: BundledSkill, for bot: Bot) -> SkillInstallState {
        SkillLibrary.state(installed: bot.installedSkills[skill.name], bundled: skill.version, installedVariant: bot.installedSkillVariants[skill.name],
                           wantedVariant: SkillLibrary.variant(of: skill, codingOrder: codingOrder(for: bot)))
    }

    /// The banner above a bot's composer: for its connection's manager, the first of its skills (its own
    /// `swarmhub-manager` first) that needs installing or updating; for any other bot (P31), an installed skill that
    /// needs updating, e.g. after its coding order changed (a missing one is offered in the editor only). Hidden while
    /// "Not now" covers that version and variant. A skill whose failed install is backing off comes after the others, so
    /// its error still shows when nothing else can be installed.
    func skillBanner(for bot: Bot) -> (skill: BundledSkill, state: SkillInstallState)? {
        let manages = isManager(bot)
        guard manages || manager(for: bot) != nil else { return nil }
        let ordered = skills(for: bot).sorted { ($0.name == SkillLibrary.managerSkill ? 0 : 1) < ($1.name == SkillLibrary.managerSkill ? 0 : 1) }
        let offered = ordered.compactMap { skill -> (skill: BundledSkill, state: SkillInstallState)? in
            let state = skillState(skill, for: bot)
            guard state.needsAction, manages || state != .missing, bot.skillBannerSnoozed != snoozeKey(skill, for: bot),
                  !isModifiedLocally(skill, for: bot) else { return nil }
            return (skill, state)
        }
        return offered.first { !skillInstallBackingOff($0.skill, for: bot) } ?? offered.first
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

    /// Install pressed (banner or editor): the bot's connection manager gets one management turn that writes the skills
    /// meant for `bot` that need it (one whose installed version and variant match is skipped; one whose install failed
    /// waits out its backoff). A staged install hands every skill to the box updater, whose signed bundle (not this
    /// build's fallback copy) decides the versions and skips what is already applied; it sends nothing while any skill
    /// on that connection failed at the bundle's version and backs off (`stagedSkillInstructions`). False when there is no
    /// manager, nothing to install, or another turn is still running; a skill whose content cannot travel in the heredoc
    /// also says so in `errorMessage`. Skill dev mode: `reset` sends that skill alone, replacing the bot's own copy.
    @discardableResult func installSkills(for bot: Bot, reset: BundledSkill? = nil) -> Bool {
        guard let manager = manager(for: bot), isIdle(manager) else { return false }
        let profile = bot.hermesProfile ?? "default"
        let instructions: String
        do {
            if usesStagedSkills(on: connection(of: bot)) {
                guard let text = try stagedSkillInstructions(manager: manager, profiles: [stagedProfile(for: bot,
                    skills: skills(for: bot).map(\.name), reset: reset)]) else { return false }
                instructions = text
            } else {
                let wanted = reset.map { [$0] } ?? skillsToInstall(for: bot)
                guard !wanted.isEmpty, let text = try skillInstallInstructions(wanted, profile: profile, botName: bot.name, codingOrder: codingOrder(for: bot),
                                                                                devMode: bot.skillDevMode, reset: Set(reset.map { [$0.name] } ?? [])) else { return false }
                instructions = text
                noteSkillInstallChecks([(bot, wanted)], manager: manager)
            }
        } catch {
            SwarmhubBlock.log.error("Skill install refused: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription; return false
        }
        pendingSkillInstalls[manager.id] = SkillInstallTurn(profile: profile, instructions: instructions)
        managementExchanges[manager.id] = nil
        open(manager); openThreadID = nil
        guard send(text: reset.map { "Reset \($0.name) to SwarmHub’s bundled version for \(bot.name)." } ?? "Install SwarmHub’s instructions for \(bot.name).") else {
            pendingSkillInstalls[manager.id] = nil; pendingSkillChecks[manager.id] = nil; boxInstallTransport.attempts[manager.id] = nil; return false
        }
        return true
    }

    /// The install turn's instructions: Konrad's press is the yes, then for each skill `mkdir -p`, a quoted heredoc per
    /// file (SKILL.md rendered for this bot, then its extra files as shipped), `chmod 755` for `scripts/`, and the
    /// `skills_installed` block to end with (P31: with each skill's variant, e.g. the coding order). Nil when a skill cannot
    /// be rendered; throws when a file contains the heredoc end marker, which would cut the file short on the box.
    func skillInstallInstructions(_ skills: [BundledSkill], profile: String, botName: String, codingOrder: CodingOrder = .standard,
                                  devMode: Bool = false, reset: Set<String> = []) throws -> String? {
        guard let install = try skillInstallCommands(skills, profile: profile, codingOrder: codingOrder, devMode: devMode, reset: reset) else { return nil }
        let devNote = devMode || !reset.isEmpty ? " Skill dev mode is on: a skill \(botName) changed on this box is kept, not overwritten, and its line says so; that is expected, not an error to fix." : ""
        return """
        Konrad pressed \(reset.isEmpty ? "Install" : "Reset to bundled") in SwarmHub to install SwarmHub’s instructions (skills) for \(botName) (profile `\(profile)`). \
        That press is his yes: do not ask again. Run exactly these commands in your terminal with the shell (not the file tool), \
        change nothing else, then reply in one short line and end with the block below. \
        If swarmhub-messages was installed, report whether its peer plugin activated; if the gateway did not reload it, mention that a reload is needed for held delivery.\(devNote)
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
    func skillInstallCommands(_ skills: [BundledSkill], profile: String, codingOrder: CodingOrder = .standard,
                              devMode: Bool = false, reset: Set<String> = []) throws -> (commands: [String], op: String)? {
        guard !skills.isEmpty, HermesKeyPaste.isValidProfileName(profile) else { return nil }
        var commands: [String] = devMode || !reset.isEmpty ? [SkillDevMode.functionDefinition] : []
        for skill in skills {
            var body: [String] = []
            guard let content = SkillLibrary.render(skill, forProfile: profile, managerTemplate: managerCoreTemplate,
                                                    codingOrder: codingOrder) else { return nil }
            let folder = SkillLibrary.installPath(skill.name, profile: profile)
            let files = [SkillFile(path: "SKILL.md", content: content)] + skill.files.map { SkillLibrary.render(configuredFile($0), forProfile: profile) }
            if let clash = files.first(where: { $0.content.contains(Self.heredocEnd) }) { throw SkillInstallError.markerInFile(skill: skill.name, path: clash.path) }
            let folders = Set(files.map { ($0.path as NSString).deletingLastPathComponent }.filter { !$0.isEmpty })
            body.append("mkdir -p " + ([folder] + folders.sorted().map { "\(folder)/\($0)" }).joined(separator: " "))
            for file in files {
                let text = file.content.hasSuffix("\n") ? file.content : file.content + "\n"
                body.append("cat > \(folder)/\(file.path) <<'\(Self.heredocEnd)'\n\(text)\(Self.heredocEnd)")
            }
            let executables = files.filter(\.isExecutable).map { "\(folder)/\($0.path)" }
            if !executables.isEmpty { body.append("chmod 755 " + executables.joined(separator: " ")) }
            if skill.name == "swarmhub-messages" {
                body.append("python3 \(folder)/scripts/peer-runtime.py install \(profile)")
                body.append("hermes -p \(profile) plugins enable swarmhub-peer")
                body.append("python3 \(folder)/scripts/peer-runtime.py start")
            }
            commands += SkillDevMode.wrap(body, skill: skill.name, profile: profile, files: files, devMode: devMode, reset: reset.contains(skill.name))
        }
        let listed = skills.map { skill in
            let variant = SkillLibrary.variant(of: skill, codingOrder: codingOrder).map { #","variant":"\#($0)""# } ?? ""
            return #"{"name":"\#(skill.name)","version":"\#(skill.version)"\#(variant)}"#
        }.joined(separator: ",")
        return (commands, #"{"op":"skills_installed","bot":"\#(profile)","skills":[\#(listed)]}"#)
    }

    /// The core manager text (the skill's SKILL.md body).
    static var bundledManagerTemplate: String? { BotManagerText.template() }

    /// P31 C: what a quiet or pressed box/accounts turn cuts its recipe from: the override (tests), else (P6b) the bundle's
    /// `prompts.managerRecipe.<name>`, else that recipe file only, never the whole manager text.
    func managerRecipeTemplate(_ recipe: BotManagerText.Recipe) -> String? {
        managerTemplateOverride ?? appConfig.managerRecipes[recipe.rawValue] ?? BotManagerText.recipe(recipe)
    }

    /// P6b: a skill's `references/<recipe>.md` with the bundle's recipe text when it has one, so an installed manager skill
    /// carries the same recipes SwarmHub's own turns use; every other file as shipped.
    private func configuredFile(_ file: SkillFile) -> SkillFile {
        guard let recipe = BotManagerText.Recipe.allCases.first(where: { $0.referencePath == file.path }),
              let text = appConfig.managerRecipes[recipe.rawValue] else { return file }
        return SkillFile(path: file.path, content: text)
    }

    /// Records a `skills_installed` op for the bot bound to `profile` on the manager's connection: only library skills,
    /// never newer than this build ships (the reply carries names and versions only; the content is never read from it).
    func recordInstalled(_ installed: [SwarmhubOp.InstalledSkill], profile: String, manager: Bot) {
        guard !usesStagedSkills(on: connection(of: manager)) else { return }
        guard let bot = boundBot(profile, manager: manager) else { return }
        for row in installed {
            guard let skill = skillLibrary.first(where: { $0.name == row.name }), let version = SkillVersion(row.version) else { continue }
            bot.installedSkills[row.name] = min(version, skill.version).description
            bot.installedSkillVariants[row.name] = row.variant
            if bot.skillsModifiedLocally.contains(row.name) { bot.skillsModifiedLocally.remove(row.name) }
        }
    }

    // MARK: Confirm from the box

    /// Opening the editor's SwarmHub skills section: when `GET /v1/skills` answers, its `swarmhub` category becomes the
    /// record (a version the description advertises, else the recorded one; a library skill not listed is missing).
    /// A 500 (stock 0.22.0) or any other failure keeps the record silently. A box still advertising an older version than
    /// the manager reported installing counts as a failed install of the bundled one.
    func refreshInstalledSkills(for bot: Bot) async {
        if usesStagedSkills(on: connection(of: bot)) { await refreshStagedSkills(for: bot); return }
        guard bot.backend == .hermes, !skills(for: bot).isEmpty, let backend = try? backend(for: bot) as? HermesBackend,
              let listed = try? await backend.skills() else { return }
        let ours = listed.filter { $0.category == SkillLibrary.category }
        var record: [String: String] = [:]
        for skill in skillLibrary {
            guard let row = ours.first(where: { $0.name == skill.name }) else { continue }
            let advertised = (row.version ?? SkillLibrary.advertisedVersion(in: row.description)).flatMap(SkillVersion.init)
            if let box = advertised, box < skill.version, let claimed = bot.installedSkills[skill.name].flatMap(SkillVersion.init), box < claimed {
                noteSkillInstallFailure(skill.name, version: skill.version.description, variant: SkillLibrary.variant(of: skill, codingOrder: codingOrder(for: bot)),
                                        reason: "The manager reported v\(claimed) installed, but the box still has v\(box).", on: bot)
            }
            record[skill.name] = advertised.map { min($0, skill.version).description } ?? bot.installedSkills[skill.name] ?? "0.0.0"
        }
        let variants = bot.installedSkillVariants.filter { record[$0.key] != nil }
        guard record != bot.installedSkills || variants != bot.installedSkillVariants else { return }
        bot.installedSkills = record; bot.installedSkillVariants = variants; objectWillChange.send(); save()
    }
}
