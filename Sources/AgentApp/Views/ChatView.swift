import SwiftUI

struct ChatView: View {
    @EnvironmentObject private var store: AppStore; @ObservedObject var bot: Bot; @State private var draft = ""
    @StateObject private var intake = AttachmentIntake(); @StateObject private var dictation = VoiceDictation()
    @State private var viewport = ChatViewport()
    @State private var selection = MessageSelection()
    /// The messages between bots that are unfolded, while this chat is on screen.
    @StateObject private var folds: ChatFolds
    @Environment(\.grokHistoryExpanded) private var historyExpanded
    /// `unfolded`: cards that start unfolded (renders); the app starts every card folded.
    init(bot: Bot, unfolded: Set<UUID> = []) { self.bot = bot; _folds = StateObject(wrappedValue: ChatFolds(open: unfolded)) }
    var body: some View {
        let shown = bot.messages.filter { !$0.isSilent }
        let _ = viewport.show(bot.id, order: shown.map(\.id))
        let appStore = store, botName = bot.name
        let _ = selection.show(rows: shown) { appStore.copiedMessage($0, botName: botName) }
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                ShowSidebarItem()
                BotAvatar(bot: bot, size: 30, motion: .focus, isWorking: store.isWorking(bot), probe: "chat_header")
                Button { store.showInfo.toggle() } label: { Text(bot.name).font(.system(size: 14, weight: .semibold)) }.buttonStyle(.plain)
                if let main = store.herdrMainBotLabel(bot) { HerdrMainBotStar(label: main, size: 11) }
                // A Herdr bot's model by the server's name for it: the running agent's, else the one its next agent starts on.
                if bot.backend == .herdr, let model = store.herdrAgentReadings[bot.id]?.short { Text(model).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).help("The model \(bot.name) runs on") }
                // Whether its agent is running: ready for a message, or still starting. Nothing while it answers.
                if bot.backend == .herdr, !store.isWorking(bot), let readiness = store.herdrReadiness[bot.id] { HerdrReadinessMark(readiness: readiness).transition(.opacity).id(readiness.word) }
                if let members = bot.archivedMembers { Text("Archived group · \(members.joined(separator: ", "))").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1) }
                Spacer()
            }.animation(.easeInOut(duration: 0.2), value: store.herdrReadiness[bot.id]?.word)
            .padding(.horizontal, ChromeMetrics.headerPadding).frame(height: 54).windowDragStrip(probe: "chat_header")
                // The bot's own colour, as a soft wash behind its name: each chat is recognisably its bot's.
                .background(LinearGradient(colors: [bot.tint.opacity(0.13), bot.tint.opacity(0.03)], startPoint: .leading, endPoint: .trailing)).background(AppColor.chat)
            Rectangle().fill(AppColor.separator).frame(height: 0.5)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        Color.clear.frame(height: 20)
                        if bot.grokSourceID != nil { GrokHistoryView(bot: bot, expanded: historyExpanded) }
                        if bot.messages.isEmpty && bot.grokSourceID == nil { ChatWelcome(bot: bot) }
                        let openers = Self.openers(shown)
                        ForEach(shown) { message in
                            MessageView(message: message, repliedMessage: message.replyToID.flatMap { id in bot.messages.first { $0.id == id } },
                                        actionTarget: .bot(botID: bot.id), reply: { store.replyTo = message }, author: openers.contains(message.id) ? bot : nil).id(message.id).chatRow(message.id, in: viewport)
                                .selectableMessage(message.id, in: selection)
                        }
                        ChatBottomMarker(viewport: viewport, conversationID: bot.id)
                    }.frame(maxWidth: 720).frame(maxWidth: .infinity).messageSelectionContent(selection).environment(\.chatFolds, folds)
                }.id(bot.id).background(AppColor.chat)
                // ⌘/⇧-click picks rows, ⌘C copies them; another conversation starts with none picked.
                .messageSelection(selection).onChange(of: bot.id) { _, _ in selection.clear(); folds.state.foldAll() }
                // Opens where it was left; new rows and streaming text follow only at the bottom.
                .overlay(alignment: .bottom) { JumpToLatestButton(scroll: store.chatScroll, conversationID: bot.id, proxy: proxy) }
                .task(id: bot.id) { await viewport.open(bot.id, model: store.chatScroll, proxy: proxy) }
                .onChange(of: shown.last?.content) { _, _ in viewport.grew(proxy: proxy) }
                .onChange(of: shown.count) { old, new in viewport.arrived(new - old, proxy: proxy) }
                .onChange(of: store.scrollTarget) { _, target in
                    guard let target else { return }
                    DispatchQueue.main.async { proxy.scrollTo(target, anchor: .center); store.scrollTarget = nil }
                }
            }
            if let reply = store.replyTo { HStack { Image(systemName: "arrowshape.turn.up.left"); Text("Replying to \(reply.role == .user ? "you" : bot.name): \(store.displayLine(reply))").lineLimit(1); Spacer(); Button { store.replyTo = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 28).padding(.top, 8).frame(maxWidth: 768) }
            if bot.isReadOnlyArchive {
                Text("Imported from Grok Bot. You can read this chat, but not write in it.").font(.system(size: 12)).foregroundStyle(.secondary).padding(14).frame(maxWidth: .infinity).background(AppColor.chat)
            } else {
                // What needs the person waits here, above the message box: an agent that asks something in its
                // terminal; and what the main bot asks: new bots (Create or Not now), additions to "About you"
                // (Remember or Don't save), and, once, the offer to get to know them.
                VStack(spacing: 8) {
                    if bot.backend == .herdr { HerdrPromptCard(bot: bot) }
                    if store.createsHerdrBots(bot) {
                        HerdrIntroOffer(bot: bot)
                        HerdrAboutYouCard(bot: bot)
                        HerdrBotRequestCard(manager: bot)
                    }
                }.padding(.top, store.createsHerdrBots(bot) || store.herdrPrompts[bot.id] != nil ? 8 : 0).frame(maxWidth: .infinity).background(AppColor.chat)
                composer.background(AppColor.chat)
            }
        }.background(AppColor.chat)
            .dropDestination(for: URL.self) { urls, _ in
                let files = urls.filter(\.isFileURL)
                guard !files.isEmpty, !bot.isReadOnlyArchive else { return false }
                attach(files); return true
            }
            .task(id: bot.id) { UISmokeProbe.renderedChats.insert(bot.id); draft = store.drafts.text(for: bot.id)
                // The chat is on screen: its agent is started ahead of the first message when it has none.
                if bot.backend == .herdr, store.launchWorkEnabled { Task { await store.refreshHerdrAgentReading(for: bot) }; await store.herdrChatShown(bot) } }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                if bot.backend == .herdr, store.launchWorkEnabled { store.herdrChatReturned(bot) }
            }
            .onChange(of: draft) { _, value in store.drafts.set(value, for: bot.id) }
            .onChange(of: store.pendingComposerAttachment) { _, _ in takePendingAttachment() }
    }
    /// The replies that open a run of the bot's own rows (the first after something the person, or the app, wrote):
    /// they carry the bot's face and name, so a long chat always shows who is talking.
    static func openers(_ shown: [ChatMessage]) -> Set<UUID> {
        var found: Set<UUID> = [], previous: MessageRole?
        for message in shown where message.role != .system {
            if message.role == .assistant, previous != .assistant { found.insert(message.id) }
            previous = message.role
        }
        return found
    }

    private var composer: some View {
        // The main bot's "+" menu: its one action writes a request for a new bot into the composer.
        ComposerView(text: $draft, attachments: $intake.items, isStreaming: store.isStreaming(in: bot), canSteer: store.canSteer(in: bot), hint: store.steerHint ?? store.herdrFirstReplyHint(for: bot),
                     send: send, stop: { store.stop(bot) }, attach: attach, pasteImage: { data, name in if let item = store.prepareAttachment(imageData: data, name: name) { intake.items.append(item) } },
                     reading: intake.reading, cancelReading: intake.cancel, removeAttachment: { intake.remove($0, store: store) },
                     manageActions: store.createsHerdrBots(bot) ? [.newBot, .getToKnowMe] : [],
                     manage: { action in if let request = action.request { draft = request } else { store.chatScroll.toBottom(bot.id); store.startHerdrIntro(for: bot, again: true) } },
                     dictationContext: store.dictationIsSetUp ? "\(bot.id):chat" : nil,
                     wantsFocus: store.composerFocus == bot.id, tookFocus: { store.composerFocus = nil }, recipient: bot.name, dictation: dictation)
    }
    /// Media tab → Attach puts a saved document into this chat's composer.
    private func takePendingAttachment() {
        guard let pending = store.pendingComposerAttachment, pending.botID == bot.id else { return }
        intake.items.append(pending.attachment); store.pendingComposerAttachment = nil
    }
    private func attach(_ urls: [URL]) { intake.attach(urls, store: store) }
    private func send() {
        let value = draft; guard !intake.isReading, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !intake.items.isEmpty else { return }
        // Sending always goes to the bottom. During a turn the attachments go too (the message waits for it).
        store.chatScroll.toBottom(bot.id)
        if store.send(text: value, attachments: intake.items) { draft = ""; intake.items = [] }
    }
}
