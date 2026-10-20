import Foundation
import Testing
import SwarmHubCore
import SwarmHubCoordination
@testable import AgentApp

/// P6b: the Mac's model defaults, coding order, team policy, manager text, orientation defaults and copy read
/// SwarmHubCore's `AppConfig` (the resolution iOS uses too; bundle decoding, wrong types, kill switches and an
/// unreachable host are covered by `AppConfigTests` there). Compiled config: every resolved value is today's. A bundle's
/// values change them without a build, and this install's own choices still win.
@MainActor struct AppConfigWiringTests {
    func makeStore() -> AppStore {
        AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    }

    static var bundled: AppConfig {
        var config = AppConfig.compiled
        config.codingOrder = "codex,claude,hermes"
        config.conversationModel = .init(provider: "TEST-provider", model: "TEST-chat-1")
        config.codingModel = .init(provider: "TEST-provider", model: "TEST-coder-1")
        config.teamActions = ["assign", "requestReview"]
        config.teamLimits.tasks = 20; config.teamLimits.reviewRounds = 3
        config.managerTemplate = "TEST manager core for {{MANAGER}}"
        config.managerRecipes = ["box": "TEST box recipe"]
        config.botPrompt.coordinator = "none"; config.botPrompt.quietHoursStart = 23 * 60; config.botPrompt.quietHoursEnd = 7 * 60
        config.codingOrderHelp = "TEST coding help"
        return config
    }

    static let compiledTeamActions = TeamPolicy(originID: UUID(), decision: "", members: [], ownerDeviceID: "").actions

    /// The compiled values in SwarmHubCore are exactly the constants the app compiled in before P6b.
    @Test func compiledConfigEqualsTheAppsOwnConstants() {
        let compiled = AppConfig.compiled
        #expect(compiled.codingOrder == CodingOrder.standard.rawValue && compiled.codingOrderHelp == CodingOrder.help)
        #expect(Set(compiled.teamActions) == Self.compiledTeamActions && compiled.teamActions == compiled.teamActions.sorted())
        #expect(TeamLimits(compiled.teamLimits) == TeamLimits() && TeamLimits(compiled.teamLimits).isValid)
        #expect(compiled.botPrompt.quietHoursStart == QuietHours.defaultStart && compiled.botPrompt.quietHoursEnd == QuietHours.defaultEnd)
        #expect(compiled.conversationModel == nil && compiled.codingModel == nil)
        #expect(compiled.managerTemplate == nil && compiled.managerTemplateOpenClaw == nil && compiled.managerRecipes.isEmpty)
        // Every order the app knows is one a bundle may name, and reads back as itself.
        let store = makeStore()
        for order in CodingOrder.allCases {
            store.appConfig.codingOrder = order.rawValue
            #expect(store.configuredCodingOrder == order)
        }
    }

    /// Snapshot of what the store resolves with no bundle: today's behaviour.
    @Test func noBundleResolvesEveryValueAsToday() throws {
        let store = makeStore()
        #expect(store.appConfig == .compiled, "a test store never reads the installed bundle")
        let manager = Bot(name: "Jarvis", backend: .hermes, hermesProfile: "grok-jarvis"), bot = Bot(name: "Coder", backend: .hermes, hermesProfile: "coder")
        store.bots = [manager, bot]
        #expect(store.configuredCodingOrder == .standard && store.codingOrder(for: bot) == .standard)
        #expect(store.effectiveModelDefaults == ModelDefaults())
        #expect(ModelPolicy.resolve(role: .conversation, settings: nil, defaults: store.effectiveModelDefaults) == .init(choice: nil, source: .boxDefault))
        #expect(store.configuredTeamActions == Self.compiledTeamActions && store.configuredTeamLimits == TeamLimits())
        #expect(store.managerCoreTemplate == AppStore.bundledManagerTemplate)
        for recipe in BotManagerText.Recipe.allCases { #expect(store.managerRecipeTemplate(recipe) == BotManagerText.recipe(recipe)) }
        let full = try #require(BotManagerText.fullTemplate())
        #expect(store.managerText(for: manager) == BotManagerText.filled(full, managerProfile: "grok-jarvis"))
        #expect(store.quietHours == QuietHours() && store.orientationCoordinatorChoice == .automatic)
    }

    @Test func bundleValuesChangeResolutionWithoutABuild() throws {
        let store = makeStore()
        store.appConfig = Self.bundled
        let manager = Bot(name: "Jarvis", backend: .hermes, hermesProfile: "grok-jarvis"), bot = Bot(name: "Coder", backend: .hermes, hermesProfile: "coder")
        store.bots = [manager, bot]
        #expect(store.codingOrder(for: bot) == .codexClaudeHermes)
        let conversation = ModelPolicy.resolve(role: .conversation, settings: bot.modelSettings, defaults: store.effectiveModelDefaults)
        #expect(conversation == .init(choice: ModelChoice(provider: "TEST-provider", model: "TEST-chat-1"), source: .appDefault))
        #expect(ModelPolicy.resolve(role: .coding, settings: nil, defaults: store.effectiveModelDefaults).choice?.model == "TEST-coder-1")
        #expect(store.configuredTeamActions == (["assign", "requestReview"] as Set<String>))
        #expect(store.configuredTeamLimits.tasks == 20 && store.configuredTeamLimits.reviewRounds == 3 && store.configuredTeamLimits.isValid)
        #expect(store.managerCoreTemplate == "TEST manager core for {{MANAGER}}")
        #expect(store.managerRecipeTemplate(.box) == "TEST box recipe" && store.managerRecipeTemplate(.accounts) == BotManagerText.recipe(.accounts))
        let text = try #require(store.managerText(for: manager))
        #expect(text.contains("TEST manager core for") && text.contains("TEST box recipe") && !text.contains("{{MANAGER}}"))
        #expect(store.quietHours == QuietHours(start: 23 * 60, end: 7 * 60) && store.orientationCoordinatorChoice == OrientationCoordinatorChoice.none)
        #expect(store.modelDefaults == ModelDefaults(), "bundle values are never written into store.json")
    }

    @Test func installedManagerSkillCarriesTheBundlesTextAndRecipes() throws {
        let store = makeStore()
        store.appConfig = Self.bundled
        let skill = BundledSkill(name: SkillLibrary.managerSkill, version: SkillVersion("1.0.0")!, template: "v{{VERSION}}\n{{MANAGER_TEXT}}",
                                 files: [SkillFile(path: "references/box.md", content: "compiled box"),
                                         SkillFile(path: "references/models.md", content: "compiled models")])
        let install = try #require(try store.skillInstallCommands([skill], profile: "grok-jarvis", codingOrder: .standard))
        let commands = install.commands.joined(separator: "\n")
        #expect(commands.contains("TEST manager core for") && commands.contains("TEST box recipe"))
        #expect(!commands.contains("compiled box") && commands.contains("compiled models"))
    }

    @Test func thisInstallsChoicesWinOverBundleDefaults() {
        let store = makeStore()
        store.appConfig = Self.bundled
        store.modelDefaults = ModelDefaults(conversation: ModelChoice(provider: "local", model: "mine"), codingAgent: .hermesOnly)
        let bot = Bot(name: "Coder", backend: .hermes, hermesProfile: "coder")
        #expect(store.codingOrder(for: bot) == .hermesOnly)
        #expect(store.effectiveModelDefaults.conversation?.model == "mine" && store.effectiveModelDefaults.coding?.model == "TEST-coder-1")
        bot.modelSettings = BotModelSettings(conversation: .box, codingAgent: .claudeOnly)
        #expect(store.codingOrder(for: bot) == .claudeOnly)
        #expect(ModelPolicy.resolve(role: .conversation, settings: bot.modelSettings, defaults: store.effectiveModelDefaults) == .init(choice: nil, source: .boxDefault))
        store.orientationCoordinatorChoice = .automatic
        #expect(store.orientationCoordinatorChoice == .automatic, "an explicit choice survives a bundle default of none")
        store.defaults.set(60, forKey: QuietHours.startKey); store.defaults.set(120, forKey: QuietHours.endKey)
        #expect(store.quietHours == QuietHours(start: 60, end: 120))
    }

    @Test func newTeamsTakeCompiledOrBundleActionsAndLimits() throws {
        let (compiled, _, first) = try WorkflowInteractionTests().fixture()
        compiled.authorizeTeamWorkflow(first)
        let today = try #require(compiled.workflows[first]?.coordination)
        #expect(today.policy.actions == Self.compiledTeamActions && today.limits == TeamLimits())

        let (bundled, _, second) = try WorkflowInteractionTests().fixture()
        bundled.appConfig = Self.bundled
        bundled.authorizeTeamWorkflow(second)
        let team = try #require(bundled.workflows[second]?.coordination)
        #expect(team.policy.actions == (["assign", "requestReview"] as Set<String>) && team.limits.tasks == 20 && team.limits.reviewRounds == 3)
        #expect(team.limits.isValid && team.policy.actions.isSubset(of: Self.compiledTeamActions))
    }
}
