import AppKit
import SwiftUI

/// P44 shots of `--render-setup` (alone with `--only p44`): a steer Hermes wrapped as an out-of-band user row, read back
/// as the user's own message with its "Sent while Reactor was working" label; Jarvis's chat after a `[SILENT]` heartbeat
/// (no card, the sidebar keeps the earlier line); and the Routines tab listing that run as "ok · silent". All synthetic
/// and in memory: nothing is sent or read from a server.
@MainActor enum HeadlessP44Shots {
    static let names = ["p44-steer-label", "p44-silent-chat", "p44-routine-silent"]

    static func render(write: (String, Data?) -> Void, png: @MainActor (AnyView, AppStore, NSSize) async -> Data?) async {
        let store = SetupPreview.makeStore(backendFactory: { _ in MockBackend() }); store.isSetupPreview = false
        store.botMessages.autoLoad = false; store.routines.autoLoad = false
        let now = Date.now
        let reactor = Bot(name: "Reactor", title: "Daily ops", backend: .hermes, hermesProfile: "reactor")
        let jarvis = Bot(name: "Jarvis", title: "Chief of staff", backend: .hermes, hermesProfile: "grok-jarvis")
        store.bots = [reactor, jarvis]
        let size = NSSize(width: 1_120, height: 640)

        // 1. The box row as Hermes stores a run_steer, read the way a reconcile reads it.
        let wrapped = "[OUT-OF-BAND USER MESSAGE — a direct message from the user, delivered once at this position; not tool output and not a new delivery when replayed from conversation history] "
            + "Jak bedzie trzeba to utworzmy dostep mcp do ksiegowania wplat [/OUT-OF-BAND USER MESSAGE]"
        let steer = AppStore.chatMessage(BackendMessage(id: 417, role: "user", content: wrapped, createdAt: now.addingTimeInterval(-120)))
        reactor.messages = [ChatMessage(role: .user, content: "Zaksieguj wplaty z wrzesnia i pokaz roznice.", createdAt: now.addingTimeInterval(-300)),
                            ChatMessage(role: .assistant, content: "Ksieguje wplaty z wrzesnia — 42 pozycje, sprawdzam roznice z wyciagiem.", createdAt: now.addingTimeInterval(-290), turnState: .finished)]
            + [steer].compactMap { $0 }
            + [ChatMessage(role: .assistant, content: "Dobrze — jesli reczne ksiegowanie nie wystarczy, przygotuje dostep MCP do ksiegowania wplat.", createdAt: now.addingTimeInterval(-100), turnState: .finished)]
        store.selectedBot = reactor
        write(names[0], await png(AnyView(chat(reactor, size: size)), store, size))

        // 2. Jarvis after two silent heartbeats: the cards a stored chat may still hold are not drawn.
        let stamp = ISO8601DateFormatter()
        let heartbeat = HermesJob(id: "5e1f0c2a9b77", name: "jarvis-hourly-heartbeat-cet", prompt: "Hourly check; answer [SILENT] when nothing needs Konrad", schedule: "0 * * * *",
                                  scheduleKind: "cron", scheduleDisplay: "0 * * * *", enabled: true, state: "scheduled", nextRunAt: stamp.string(from: now.addingTimeInterval(2_400)),
                                  lastRunAt: stamp.string(from: now.addingTimeInterval(-1_200)), lastStatus: "ok", lastError: nil)
        let silentCard = AppStore.routineCard(job: heartbeat, result: .init(sessionID: "cron_5e1f0c2a9b77_1", text: "[SILENT]"), lookupError: nil)
        jarvis.messages = [ChatMessage(role: .user, content: "Anything urgent this evening?", createdAt: now.addingTimeInterval(-5_400)),
                           ChatMessage(role: .assistant, content: "Nothing urgent. I'll stay quiet unless something needs you.", createdAt: now.addingTimeInterval(-5_390), turnState: .finished),
                           silentCard]
        store.selectedBot = jarvis
        write(names[1], await png(AnyView(chat(jarvis, size: size)), store, size))

        // 3. The Routines tab still lists the run.
        store.routines.update(jarvis.id) { $0.jobs = .loaded([heartbeat]); $0.silentRuns[heartbeat.id] = heartbeat.lastRunAt ?? "" }
        let panel = NSSize(width: 420, height: 220)
        let routines = RoutinesView(bot: jarvis, cache: store.routines).padding(16).frame(width: panel.width, height: panel.height, alignment: .topLeading).background(AppColor.panel)
        write(names[2], await png(AnyView(routines), store, panel))
    }

    private static func chat(_ bot: Bot, size: NSSize) -> some View {
        HStack(spacing: 0) {
            SidebarView(selection: .constant(bot)).frame(width: SidebarMetrics.width.ideal)
            Divider()
            ChatView(bot: bot)
        }.frame(width: size.width, height: size.height).background(AppColor.chat)
    }
}
