import AppKit
import SwiftUI

/// P50 shots of `--render-setup` (alone with `--only p50`): a long chat reopened at its saved middle position with
/// "Jump to latest · 3 new" (three replies arrived below while it was scrolled up), and a first open at the newest
/// message. All synthetic and in memory: nothing is sent or saved.
@MainActor enum HeadlessP50Shots {
    static let names = ["p50-reopened-middle", "p50-first-open-newest"]

    static func render(write: (String, Data?) -> Void, png: @MainActor (AnyView, AppStore, NSSize) async -> Data?) async {
        let store = SetupPreview.makeStore(backendFactory: { _ in MockBackend() }); store.isSetupPreview = false
        store.botMessages.autoLoad = false; store.routines.autoLoad = false; store.botWork.autoStart = false
        let now = Date.now; store.now = { now }
        let atlas = Bot(name: "Atlas", title: "Research", description: "Reads and summarises", backend: .hermes, hermesProfile: "atlas")
        let scout = Bot(name: "Scout", title: "Travel", description: "Plans trips", backend: .hermes, hermesProfile: "scout")
        atlas.avatarName = .robot; scout.avatarName = .octopus
        store.bots = [atlas, scout]
        atlas.messages = transcript(topics: topics, now: now)
        scout.messages = transcript(topics: Array(topics.prefix(8)), now: now)
        let size = NSSize(width: 1_120, height: 720)
        func chat(_ bot: Bot) -> AnyView {
            AnyView(HStack(spacing: 0) {
                SidebarView(selection: .constant(bot)).frame(width: SidebarMetrics.width.ideal)
                Divider()
                ChatView(bot: bot)
            }.frame(width: size.width, height: size.height).background(AppColor.chat))
        }

        // 1. Atlas was left at question 7 last time; three replies arrived below while it was scrolled up.
        let middle = atlas.messages[12]
        store.chatScroll.saw(atlas.id, top: middle.id, atBottom: false)
        for (index, text) in late.enumerated() {
            atlas.messages.append(ChatMessage(role: .assistant, content: text, createdAt: now.addingTimeInterval(Double(index - 3) * 20), turnState: .finished))
        }
        store.chatScroll.arrived(atlas.id, count: late.count)
        store.selectedBot = atlas
        write(names[0], await png(chat(atlas), store, size))

        // 2. Scout has no saved position: it opens at the newest message.
        store.selectedBot = scout
        write(names[1], await png(chat(scout), store, size))
    }

    private static func transcript(topics: [(String, String)], now: Date) -> [ChatMessage] {
        topics.enumerated().flatMap { index, topic in
            let at = now.addingTimeInterval(Double(index - topics.count) * 600)
            return [ChatMessage(role: .user, content: "\(index + 1). \(topic.0)", createdAt: at),
                    ChatMessage(role: .assistant, content: topic.1, createdAt: at.addingTimeInterval(30), turnState: .finished)]
        }
    }

    static let topics: [(String, String)] = [
        ("What changed in the reading list this week?", "Two new papers on retrieval and one long post on evaluation. I tagged all three \"to read\"."),
        ("Summarise the retrieval paper in three lines.", "It reranks passages with a small model, keeps the top eight, and reports a 4-point gain on the long-question set."),
        ("Is the code public?", "Yes, under an MIT licence. The repository has the training script but not the reranker weights."),
        ("Compare it with last month's approach.", "Last month's approach used one larger model and no reranking. This one is cheaper per query and slightly better on long questions."),
        ("Any caveats?", "The evaluation set is small (300 questions), and the gain shrinks on short questions."),
        ("Draft a note for the team.", "Draft: \"New retrieval paper: reranking with a small model, +4 on long questions, code public, weights not yet.\""),
        ("Make it shorter.", "\"Reranking paper: +4 on long questions, code public.\""),
        ("What about the evaluation post?", "It argues for reporting variance across three seeds and shows two leaderboards that flip under that rule."),
        ("Which leaderboards?", "A summarisation board and a code-completion board; the top two entries swap places on both."),
        ("Save both summaries to the project notes.", "Saved under Reading → Week 41, with links to the sources."),
        ("Remind me Friday to read the third one.", "Done: Friday 09:00, \"Read the third paper on the list\"."),
        ("What's left on the list?", "Four items: the third paper, two talks, and a dataset card."),
        ("Order them by length.", "Dataset card (5 min), talk A (20 min), talk B (35 min), the paper (about an hour).")
    ]
    static let late = [
        "The dataset card is up to date: 12,400 rows, licence CC BY 4.0, last refreshed on Monday.",
        "Talk A has slides online; I added the link to the notes.",
        "Talk B's recording is not public yet. I'll check again tomorrow."
    ]
}
