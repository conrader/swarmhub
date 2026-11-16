import SwiftUI

struct ChatView: View {
    @EnvironmentObject private var store: AppStore; @ObservedObject var bot: Bot; @State private var draft = ""
    @StateObject private var intake = AttachmentIntake(); @StateObject private var dictation = VoiceDictation()
    @State private var viewport = ChatViewport()
    @State private var selection = MessageSelection()
    @Environment(\.grokHistoryExpanded) private var historyExpanded
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
                if bot.backend == .herdr, let model = store.herdrAgentReadings[bot.id]?.short { Text(model).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).help("The model this bot's agent runs on") }
                if let members = bot.archivedMembers { Text("Archived group · \(members.joined(separator: ", "))").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1) }
                Spacer()
            }.padding(.horizontal, ChromeMetrics.headerPadding).frame(height: 54).windowDragStrip(probe: "chat_header").background(AppColor.chat)
            Rectangle().fill(AppColor.separator).frame(height: 0.5)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        Color.clear.frame(height: 20)
                        if bot.grokSourceID != nil { GrokHistoryView(bot: bot, expanded: historyExpanded) }
                        if bot.messages.isEmpty && bot.grokSourceID == nil { ChatWelcome(bot: bot) }
                        ForEach(shown) { message in
                            MessageView(message: message, repliedMessage: message.replyToID.flatMap { id in bot.messages.first { $0.id == id } },
                                        actionTarget: .bot(botID: bot.id), reply: { store.replyTo = message }).id(message.id).chatRow(message.id, in: viewport)
                                .selectableMessage(message.id, in: selection)
                        }
                        ChatBottomMarker(viewport: viewport, conversationID: bot.id)
                    }.frame(maxWidth: 720).frame(maxWidth: .infinity).messageSelectionContent(selection)
                }.id(bot.id).background(AppColor.chat)
                // ⌘/⇧-click picks rows, ⌘C copies them; another conversation starts with none picked.
                .messageSelection(selection).onChange(of: bot.id) { _, _ in selection.clear() }
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
                Text("Read-only archive imported from Grok Bot.").font(.system(size: 12)).foregroundStyle(.secondary).padding(14).frame(maxWidth: .infinity).background(AppColor.chat)
            } else {
                // The main bot's requests for new bots wait here for Create or Dismiss.
                if store.createsHerdrBots(bot) { HerdrBotRequestCard(manager: bot).padding(.top, 8).frame(maxWidth: .infinity).background(AppColor.chat) }
                composer.background(AppColor.chat)
            }
        }.background(AppColor.chat)
            .dropDestination(for: URL.self) { urls, _ in
                let files = urls.filter(\.isFileURL)
                guard !files.isEmpty, !bot.isReadOnlyArchive else { return false }
                attach(files); return true
            }
            .task(id: bot.id) { UISmokeProbe.renderedChats.insert(bot.id); draft = store.drafts.text(for: bot.id)
                if bot.backend == .herdr, store.launchWorkEnabled { await store.refreshHerdrAgentReading(for: bot) } }
            .onChange(of: draft) { _, value in store.drafts.set(value, for: bot.id) }
            .onChange(of: store.pendingComposerAttachment) { _, _ in takePendingAttachment() }
    }
    private var composer: some View {
        // The main bot's "+" menu: its one action writes a request for a new bot into the composer.
        ComposerView(text: $draft, attachments: $intake.items, isStreaming: store.isStreaming(in: bot), canSteer: store.canSteer(in: bot), hint: store.steerHint ?? store.herdrFirstReplyHint(for: bot),
                     send: send, stop: { store.stop(bot) }, attach: attach, pasteImage: { data, name in if let item = store.prepareAttachment(imageData: data, name: name) { intake.items.append(item) } },
                     reading: intake.reading, cancelReading: intake.cancel, removeAttachment: { intake.remove($0, store: store) },
                     manageActions: store.createsHerdrBots(bot) ? [.newBot] : [], manage: { draft = $0.request },
                     dictationContext: "\(bot.id):chat",
                     wantsFocus: store.composerFocus == bot.id, tookFocus: { store.composerFocus = nil }, dictation: dictation)
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
