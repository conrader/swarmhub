import Foundation
import SwarmHubCore
import SwarmHubCoordination

/// P6b (CORE-PLAN §1.2): the bundle-configurable settings this Mac uses, resolved by SwarmHubCore's `AppConfig` exactly as
/// on iOS (no per-platform resolution). Read once per launch from the bundle the update client installed; never fetches,
/// so an unreachable update host changes nothing. This install's own choices still win over a bundle default.
extension AppStore {
    static let launchConfig = AppConfig.load()

    /// The SwarmHub-wide coding order while this install has not chosen one: the bundle's, else Claude Code first.
    var configuredCodingOrder: CodingOrder { CodingOrder(rawValue: appConfig.codingOrder) ?? .standard }

    /// This install's model defaults with each unset role filled from the bundle; what P13 resolution reads.
    var effectiveModelDefaults: ModelDefaults { modelDefaults.filled(from: appConfig) }

    /// A new team's delegation actions (only ever a subset of `TeamPolicy`'s compiled ones) and limits.
    var configuredTeamActions: Set<String> { Set(appConfig.teamActions) }
    var configuredTeamLimits: TeamLimits { TeamLimits(appConfig.teamLimits) }

    /// The Hermes manager core text: tests' override, else the bundle's `prompts.managerTemplate`, else the bundled resource.
    var managerCoreTemplate: String? { managerTemplateOverride ?? appConfig.managerTemplate ?? Self.bundledManagerTemplate }
}

extension TeamLimits {
    init(_ config: AppConfig.TeamLimits) {
        self.init()
        tasks = config.tasks; reviewRounds = config.reviewRounds; handoffDepth = config.handoffDepth
        operations = config.operations; parallelTasks = config.parallelTasks; activeSeconds = TimeInterval(config.activeSeconds)
    }
}
