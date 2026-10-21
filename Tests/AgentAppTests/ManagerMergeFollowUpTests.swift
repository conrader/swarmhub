import Foundation
import Testing
@testable import AgentApp

// P28 merge follow-up (P27 × P26): SwarmHub skills are a Hermes feature. An OpenClaw manager keeps the full
// `manager-openclaw.md` text, never the skill pointer or install instructions; it has no "Change model…", its
// `skills_installed` is ignored, and OpenClaw bots get no install banner or SwarmHub skills section. Fake Gateway only.

private let managerSkill = BundledSkill(name: "swarmhub-manager", version: SkillVersion("1.2.0")!, template: "---\nname: swarmhub-manager\n---\n\n{{MANAGER_TEXT}}\n")

/// Alpha (`agent-alpha`) as its Gateway's manager, Beta bound to `agent-beta`, both recorded as having the current skill.
@MainActor private func clawManagerWithSkill() -> (AppStore, Bot, Bot) {
    let (store, alpha, gateway, _) = clawStore(FakeGateway())
    store.skillLibraryOverride = [managerSkill]
    store.setCanManageBots(alpha, true)
    let beta = Bot(name: "Beta", persona: "", backend: .openClaw); beta.openClaw = .init(gatewayID: gateway.id, agentID: "agent-beta")
    store.bots.append(beta)
    for bot in [alpha, beta] { bot.installedSkills = [managerSkill.name: "1.2.0"] }
    return (store, alpha, beta)
}

@MainActor @Test func anOpenClawManagerGetsTheFullOpenClawTextAndNeverTheSkillPointer() throws {
    let (store, alpha, _) = clawManagerWithSkill()
    let bundled = try #require(BotManagerText.template(for: .openClaw))
    let text = try #require(store.managementText(for: alpha, text: "Create a bot called rapper that raps", conversation: alpha))
    #expect(text == BotManagerText.filled(bundled, managerAgent: "agent-alpha") + "\n\n" + (BotManagerText.connectorBootstrap ?? ""), "the OpenClaw creation carries its connector bootstrap")
    #expect(text != AppStore.skillPointer && !text.contains("swarmhub-manager skill"))
    // A pending Install (Hermes-only) never replaces it either.
    store.pendingSkillInstalls[alpha.id] = SkillInstallTurn(profile: "agent-beta", instructions: "INSTALL-INSTRUCTIONS")
    let next = try #require(store.managementText(for: alpha, text: "yes", conversation: alpha))
    #expect(next == text)

    // Control: a Hermes manager with the same current skill gets the pointer.
    let jarvis = Bot(name: "Jarvis", persona: "", backend: .hermes, hermesProfile: "grok-jarvis"); store.bots.append(jarvis)
    store.setCanManageBots(jarvis, true); jarvis.installedSkills = [managerSkill.name: "1.2.0"]
    #expect(store.managementText(for: jarvis, text: "Create a bot called rapper that raps", conversation: jarvis) == AppStore.skillPointer)
}

@Test func changeModelIsOfferedOnlyToHermesManagers() {
    #expect(!ManageBotsAction.actions(for: .openClaw).contains(.changeModel))
    #expect(ManageBotsAction.actions(for: .openClaw) == ManageBotsAction.allCases.filter { $0 != .changeModel && $0 != .changeSubAgentModel })
    #expect(ManageBotsAction.actions(for: .hermes).contains(.changeModel))
}

@MainActor @Test func skillsInstalledFromAnOpenClawManagerIsIgnored() async {
    let (store, alpha, beta) = clawManagerWithSkill()
    beta.installedSkills = [:]
    await store.apply(.skillsInstalled(bot: "agent-beta", skills: [.init(name: managerSkill.name, version: "1.2.0")]), manager: alpha)
    #expect(beta.installedSkills.isEmpty && alpha.installedSkills == [managerSkill.name: "1.2.0"])
}

@MainActor @Test func openClawBotsHaveNoInstallBannerOrSkillsSection() {
    let (store, alpha, beta) = clawManagerWithSkill()
    for bot in [alpha, beta] { bot.installedSkills = [:] }
    #expect(store.skillBanner(for: alpha) == nil, "no install banner in the OpenClaw manager's chat")
    #expect(store.skills(for: alpha).isEmpty && store.skills(for: beta).isEmpty, "the editor's SwarmHub skills section has nothing to show")
    #expect(!store.installSkills(for: beta))
}
