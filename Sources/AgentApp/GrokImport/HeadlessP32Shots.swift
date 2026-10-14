import AppKit
import SwiftUI

/// P32 shots of `--render-setup`: the sample agents' chat on the real draft and choices cards, a Hermes agent's Overview
/// with delegated tasks (from its `delegate_task` steps) and the memory line, and the quick switcher with its first match
/// highlighted, the imported-skill install sheet and a failed steer with "Send as next message". Throwaway in-memory
/// stores with a mock backend; no network, no Keychain.
@MainActor enum HeadlessP32Shots {
    static let names = ["p32-sample-agents-chat", "p32-overview-delegated", "p32-quick-switcher", "p32-imported-skill-install", "p32-failed-steer"]

    static func render(write: (String, Data?) -> Void, png: @MainActor (AnyView, AppStore, NSSize) async -> Data?) async {
        let samples = SetupPreview.makeStore(backendFactory: { _ in MockBackend() }); samples.isSetupPreview = false
        samples.loadDemoData()
        if let atlas = samples.bots.first {
            samples.selectedBot = atlas
            write(names[0], await png(AnyView(ChatView(bot: atlas)), samples, NSSize(width: 820, height: 900)))
        }

        let store = SetupPreview.makeStore(backendFactory: { _ in MockBackend() }); store.isSetupPreview = false
        let ada = Bot(name: "Ada", title: "Research lead", description: "Splits research into tasks for its sub-agents.", backend: .hermes, hermesProfile: "ada")
        let now = Date.now
        let reply = ChatMessage(role: .assistant, content: "The three summaries are in.", createdAt: now.addingTimeInterval(-600))
        var activity = ToolActivity()
        let tasks: [(String, TimeInterval, ToolEvent.Phase)] = [("Summarise the Q3 board pack", 150, .completed), ("Compare the two hosting offers", 95, .completed),
                                                                ("Check the venue contract for a cancellation clause", 12, .failed)]
        for (index, task) in tasks.enumerated() {
            let at = reply.createdAt.addingTimeInterval(Double(index) * 20)
            activity.apply(ToolEvent(phase: .started, name: DelegatedTask.tool, preview: task.0, callID: "\(index)"), at: at)
            activity.apply(ToolEvent(phase: task.2, name: DelegatedTask.tool, callID: "\(index)"), at: at.addingTimeInterval(task.1))
        }
        activity.finish(at: reply.createdAt.addingTimeInterval(200)); reply.activity = activity
        let live = ChatMessage(role: .assistant, content: "", createdAt: now.addingTimeInterval(-40), isStreaming: true)
        var running = ToolActivity(); running.apply(ToolEvent(phase: .started, name: DelegatedTask.tool, preview: "Draft the client update"), at: now.addingTimeInterval(-30))
        live.activity = running
        ada.messages = [ChatMessage(role: .user, content: "research these three", createdAt: now.addingTimeInterval(-620)), reply,
                        ChatMessage(role: .user, content: "and draft the update", createdAt: now.addingTimeInterval(-41)), live]
        store.bots = [ada, Bot(name: "Mira", backend: .hermes, hermesProfile: "mira")]; store.selectedBot = ada
        store.infoTab = .activity  // P33: delegated tasks live in the Activity tab
        write(names[1], await png(AnyView(InfoPanel(bot: ada)), store, NSSize(width: 360, height: 900)))
        write(names[2], await png(AnyView(CommandPaletteView(selectCommand: { _ in }, openSetup: {})), store, NSSize(width: 480, height: 380)))
        await renderItems5And9(write: write, png: png)
    }

    private static func renderItems5And9(write: (String, Data?) -> Void, png: @MainActor (AnyView, AppStore, NSSize) async -> Data?) async {
        let store = SetupPreview.makeStore(backendFactory: { _ in MockBackend() }); store.isSetupPreview = false
        let jarvis = Bot(name: "Jarvis", backend: .hermes, hermesProfile: "grok-jarvis"); jarvis.canManageBots = true
        let skill = ImportedTemplateSkill(name: "Travel Planner", markdown: """
        # Travel Planner

        When asked to plan a trip:
        1. Ask for dates, budget and who is travelling.
        2. Propose two routes with rough costs.
        3. Book nothing without a yes.
        """)
        let trip = Bot(name: "Trip Planner", backend: .hermes, skills: [skill.name], importedSkills: [skill], hermesProfile: "trip-planner")
        store.bots = [trip, jarvis]; store.selectedBot = trip
        write(names[3], await png(AnyView(ImportedSkillInstallSheet(bot: trip, skill: skill)), store, NSSize(width: 560, height: 520)))

        let now = Date.now
        let ada = Bot(name: "Ada", backend: .hermes, hermesProfile: "ada")
        ada.messages = [ChatMessage(role: .user, content: "Summarise the board pack", createdAt: now.addingTimeInterval(-300)),
                        ChatMessage(role: .assistant, content: "Here is the summary: revenue is up 8 %, two hires are pending, and the venue contract needs a decision by Friday.",
                                    createdAt: now.addingTimeInterval(-240), turnState: .finished),
                        ChatMessage(role: .user, content: "Keep it to three bullet points", createdAt: now.addingTimeInterval(-238), metadata: [SteerKey.steer: "failed"]),
                        ChatMessage(role: .system, content: SteerCopy.endedFirst, createdAt: now.addingTimeInterval(-237), metadata: [TurnKey.tone: "warning"])]
        store.bots = [ada]; store.selectedBot = ada
        write(names[4], await png(AnyView(ChatView(bot: ada)), store, NSSize(width: 820, height: 620)))
    }
}
