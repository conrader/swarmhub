import AppKit
import SwiftUI
import Testing
@testable import AgentApp

// P33: the agent panel's seven tabs. Which tab each Overview pointer opens, the OpenClaw tab set, the shortcuts, and the
// compact tab bar fitting the panel's 300 pt minimum. Synthetic stores only.

@MainActor private func plainStore() -> AppStore {
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    store.bots = []; store.groups = []; store.selectedBot = nil; store.selectedGroup = nil
    return store
}

@Test func tabsComeInTheBriefsOrder() {
    #expect(AgentInfoTab.allCases == [.overview, .model, .skills, .activity, .routines, .media, .computer])
    #expect(AgentInfoTab.allCases.map(\.rawValue) == ["Overview", "Model", "Skills", "Activity", "Routines", "Media", "Computer"])
}

@MainActor @Test func hermesShowsEveryTabAndOpenClawOnlyTabsWithContent() {
    let store = plainStore()
    let hermes = Bot(name: "Ada", backend: .hermes, hermesProfile: "ada")
    #expect(store.infoTabs(for: hermes) == AgentInfoTab.allCases)
    let claw = Bot(name: "Alpha", backend: .openClaw); claw.openClaw = .init(gatewayID: "gw-1", agentID: "agent-alpha")
    #expect(store.infoTabs(for: claw) == [.overview, .model, .media, .computer])
    #expect(store.infoTabs(for: claw) == HeadlessInspector.openClawTabs, "the inspector render covers what a fresh OpenClaw agent shows")
    claw.skills = ["research"]
    claw.approvalAudit.append(ApprovalAuditEntry(approvalID: UUID(), actionKind: "exec", outcome: .approved, decidedBy: "You", reason: "ok"))
    claw.routines.append(BotRoutine(name: "Daily", schedule: "0 8 * * *", prompt: "Summarise", isEnabled: true, importKind: .cron))
    #expect(store.infoTabs(for: claw) == AgentInfoTab.allCases)
    // A tab this agent hides falls back to Overview without forgetting the choice.
    let fresh = Bot(name: "Beta", backend: .openClaw)
    store.infoTab = .skills
    #expect(store.visibleInfoTab(for: fresh) == .overview && store.visibleInfoTab(for: hermes) == .skills && store.infoTab == .skills)
}

@MainActor @Test func approvalPointerOpensActivity() {
    let store = plainStore(), bot = Bot(name: "Ada", backend: .hermes, hermesProfile: "ada")
    store.bots = [bot]
    #expect(store.infoPointers(for: bot).isEmpty)
    store.approvals.append(ApprovalRequest(id: UUID(), title: "Approve", summary: "command", draft: nil, botID: bot.id))
    #expect(store.infoPointers(for: bot) == [InfoPointer(text: "1 approval waiting", tab: .activity)])
    store.approvals.append(ApprovalRequest(id: UUID(), title: "Approve", summary: "command", draft: nil, botID: bot.id))
    #expect(store.infoPointers(for: bot).map(\.text) == ["2 approvals waiting"])
    store.showInfo = false; store.infoTab = .media
    store.openInfoTab(store.infoPointers(for: bot)[0].tab)
    #expect(store.showInfo && store.infoTab == .activity)
}

@MainActor @Test func skillsPointerOpensSkillsForTheManagerOnly() {
    let store = plainStore()
    store.skillLibraryOverride = [BundledSkill(name: SkillLibrary.managerSkill, version: SkillVersion("1.2.0")!, template: "x")]
    let manager = Bot(name: "Jarvis", backend: .hermes, hermesProfile: "grok-jarvis"); manager.canManageBots = true
    let plain = Bot(name: "Plain", backend: .hermes, hermesProfile: "plain")
    store.bots = [manager, plain]
    #expect(store.infoPointers(for: manager) == [InfoPointer(text: "SwarmHub skills: not installed", tab: .skills)])
    manager.installedSkills = [SkillLibrary.managerSkill: "1.1.0"]
    #expect(store.infoPointers(for: manager) == [InfoPointer(text: "SwarmHub skills: update available", tab: .skills)])
    manager.installedSkills = [SkillLibrary.managerSkill: "1.2.0"]
    #expect(store.infoPointers(for: manager).isEmpty)
    #expect(store.infoPointers(for: plain).isEmpty, "a missing skill on a non-manager is offered in the editor only, like the banner")
}

@MainActor @Test func roleMismatchPointerOpensModel() async throws {
    let (store, jarvis, _, _, state, _) = applyStore(CatalogShape.allCases[0])
    jarvis.hermesSessionID = "s1"; state.with { $0.sessionModels["s1"] = "model-alpha" }
    jarvis.modelSettings = .init(conversation: .choice(ModelChoice(provider: "lab-one", model: "model-beta")!))
    await store.loadServerInfo(for: jarvis)
    #expect(store.modelRolesRow(for: jarvis).mismatch != nil)
    #expect(store.infoPointers(for: jarvis).first == InfoPointer(text: "Model differs from this bot's role", tab: .model))
}

@MainActor @Test func shortcutsKeepTheOldKeysAndGiveTheNewTabsTheNextOnes() {
    #expect([AppCommand.overview, .routines, .media, .computer, .members].map { String($0.key.character) } == ["1", "2", "3", "4", "5"])
    #expect([AppCommand.model, .skills, .activity].map(\.shortcutText) == ["⌘6", "⌘7", "⌘8"])
    #expect(AppCommand.members.infoTab == .overview, "members live at the bottom of Overview now")
    #expect(AgentInfoTab.allCases.allSatisfy { tab in AppCommand.allCases.contains { $0.infoTab == tab } })
    let store = plainStore(), bot = Bot(name: "Ada", backend: .hermes, hermesProfile: "ada")
    store.bots = [bot]; store.open(bot); store.showInfo = false
    for (command, tab) in [(AppCommand.model, AgentInfoTab.model), (.skills, .skills), (.activity, .activity), (.members, .overview)] {
        command.performWorkspaceAction(in: store)
        #expect(store.showInfo && store.infoTab == tab)
    }
    // An OpenClaw agent without skills does not offer ⌘7.
    let claw = Bot(name: "Alpha", backend: .openClaw); store.bots.append(claw); store.open(claw)
    #expect(!AppCommand.skills.isEnabled(in: store) && !AppCommand.activity.isEnabled(in: store) && AppCommand.model.isEnabled(in: store))
}

/// The symbol + caption bar fits 300 pt: every caption at the regular weight plus the widest one selected (semibold),
/// the item padding, the bar's insets and a 2 pt minimum gap. The captions are `.fixedSize()`, so this is what keeps
/// them from overflowing; the 300 pt renders show the same.
@Test func compactTabBarFitsThePanelMinimum() {
    func width(_ text: String, _ weight: NSFont.Weight) -> CGFloat { ceil((text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 9, weight: weight)]).width) }
    let captions = AgentInfoTab.allCases.map(\.caption)
    let regular = captions.map { width($0, .regular) + 4 }
    let selectedExtra = captions.map { width($0, .semibold) - width($0, .regular) }.max() ?? 0
    let needed = regular.reduce(0, +) + selectedExtra + 2 * CGFloat(captions.count - 1) + 16
    #expect(needed <= 300, "needs \(needed) pt")
}
