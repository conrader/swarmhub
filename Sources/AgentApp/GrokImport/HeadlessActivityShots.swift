import AppKit
import SwiftUI

/// P27 shots of `--render-setup`: a manager's chat with the SwarmHub-skills install banner and a reply still working
/// (the live activity line), and a finished reply's steps row folded and open. P29: the working reply's row folded (with its
/// chevron) and open (the steps so far, the last one running). A throwaway in-memory store with
/// synthetic steps; no network, no Keychain.
@MainActor enum HeadlessActivityShots {
    static let chatSize = NSSize(width: 820, height: 620)
    static let rowSize = NSSize(width: 720, height: 420)
    static let names = ["p27-install-banner-live-line", "p27-steps-folded", "p27-steps-open", "p29-working-folded", "p29-working-open"]

    static func sampleActivity(start: Date, running: Bool) -> ToolActivity {
        var activity = ToolActivity()
        let steps: [(String, String?, Bool)] = [
            ("skills_list", nil, false), ("terminal", "hermes profile list", false), ("read_file", "~/.hermes/swarmhub-model.log", false),
            ("terminal", "hermes -p research config set model.default …", false), ("terminal", "hermes -p writer config set model.default …", true),
            ("terminal", "cat ~/.hermes/swarmhub-model.log", false)
        ]
        for (index, step) in steps.enumerated() {
            let at = start.addingTimeInterval(Double(index) * 12 + 3)
            activity.apply(ToolEvent(phase: .started, name: step.0, preview: step.1), at: at)
            if !(running && index == steps.count - 1) { activity.apply(ToolEvent(phase: step.2 ? .failed : .completed, name: step.0), at: at.addingTimeInterval(8)) }
        }
        if !running { activity.finish(at: start.addingTimeInterval(292)) }
        return activity
    }

    static func render(write: (String, Data?) -> Void, png: @MainActor (AnyView, AppStore, NSSize) async -> Data?) async {
        // P28 D6: a mock backend, so the chat's capability read never leaves the Mac with the synthetic key.
        let store = SetupPreview.makeStore(backendFactory: { _ in MockBackend() }); store.isSetupPreview = false
        let jarvis = Bot(name: "Jarvis", persona: "You are Jarvis.", backend: .hermes, hermesProfile: "grok-jarvis")
        jarvis.canManageBots = true
        store.keyStore.setKey("synthetic", for: AppStore.keyAccount(forProfile: "grok-jarvis"))
        let now = Date.now
        let finished = ChatMessage(role: .assistant, content: "Done: 5 of 6 bots now use the new model; **writer** FAILED (unknown provider).", createdAt: now.addingTimeInterval(-900))
        finished.activity = sampleActivity(start: finished.createdAt, running: false)
        let working = ChatMessage(role: .assistant, content: "", createdAt: now.addingTimeInterval(-72), isStreaming: true)
        working.activity = sampleActivity(start: working.createdAt, running: true)
        jarvis.messages = [ChatMessage(role: .user, content: "switch all agents to the new model", createdAt: now.addingTimeInterval(-960)), finished,
                           ChatMessage(role: .user, content: "check the log again", createdAt: now.addingTimeInterval(-73)), working]
        store.bots = [jarvis]; store.selectedBot = jarvis
        write(names[0], await png(AnyView(ChatView(bot: jarvis)), store, chatSize))
        for (name, row, open) in [(names[1], finished, false), (names[2], finished, true), (names[3], working, false), (names[4], working, true)] {
            var message = MessageView(message: row); message.stepsExpanded = open
            let view = VStack(alignment: .leading, spacing: 0) { message; Spacer() }
            write(name, await png(AnyView(view.frame(width: rowSize.width, height: rowSize.height, alignment: .topLeading).background(AppColor.chat)), store, rowSize))
        }
    }
}
