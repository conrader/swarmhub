import SwiftUI

struct ChatView: View {
    @EnvironmentObject private var store: AppStore; @ObservedObject var bot: Bot; @State private var draft = ""
    private var intake: AttachmentIntake { store.attachmentIntake(for: bot.id) }
    @State private var verifyingAttachmentSupport = false
    @StateObject private var viewport = ChatViewport()
    @State private var selection = MessageSelection()
    @State private var terminal: HerdrTerminalTarget?
    /// The messages between bots that are unfolded, while this chat is on screen.
    @StateObject private var folds: ChatFolds
    @Environment(\.grokHistoryExpanded) private var historyExpanded
    /// `unfolded`: cards that start unfolded (renders); the app starts every card folded.
    init(bot: Bot, unfolded: Set<UUID> = []) { self.bot = bot; _folds = StateObject(wrappedValue: ChatFolds(open: unfolded)) }
    var body: some View {
        let shown = bot.messages.filter { !$0.isSilent }
        let _ = viewport.show(bot.id, order: shown.map(\.id), model: store.chatScroll)
        let appStore = store, botName = bot.name
        let _ = selection.show(rows: shown, conversation: bot.id, body: appStore.transcriptBody) { appStore.copiedMessage($0, botName: botName) }
        let coding = store.hasActiveCodingAgent(bot)
        let answering = store.isAnswering(bot)
        let session = store.herdrTerminalSession(for: bot)
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                ShowSidebarItem()
                BotAvatar(bot: bot, size: 30, motion: .focus, isWorking: answering, probe: "chat_header",
                          hasActiveCodingAgent: coding, mainBotLabel: store.herdrMainBotLabel(bot))
                Button { store.showInfo.toggle() } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(bot.name).font(.system(size: 14, weight: .semibold))
                        if !bot.title.isEmpty, bot.title != Bot.placeholderTitle {
                            Text(verbatim: bot.title).font(.caption).foregroundStyle(.secondary)
                        }
                    }.lineLimit(1)
                }.buttonStyle(.plain).accessibilityLabel(bot.name)
                if bot.backend == .herdr, !answering, let readiness = store.herdrReadiness[bot.id],
                   readiness != .ready || store.herdrPresence(for: bot)?.isActive != true {
                    HerdrReadinessMark(readiness: readiness).transition(.opacity).id(readiness.word)
                }
                if let members = bot.archivedMembers { Text("Archived group · \(members.joined(separator: ", "))").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1) }
                Spacer(minLength: 2)
                if bot.backend == .herdr, !bot.isReadOnlyArchive {
                    ChatModelButton(reading: store.herdrAgentReadings[bot.id], usage: store.herdrPresence(for: bot)?.usage) { store.openInfoTab(.model) }
                }
                if let session {
                    ChatTerminalPreviewButton(server: store.herdrServer(for: bot),
                                              target: LiveTerminal(agent: session, title: bot.name))
                    Button("Terminal", systemImage: "terminal") { terminal = HerdrTerminalTarget(agent: session) }
                        .buttonStyle(.bordered).controlSize(.small).fixedSize()
                        .accessibilityLabel("Open terminal for \(bot.name)").accessibilityIdentifier("chat.bot.terminal")
                }
                ShowDetailsItem()
            }.animation(.easeInOut(duration: 0.2), value: store.herdrReadiness[bot.id]?.word)
            .padding(.horizontal, ChromeMetrics.headerPadding).frame(height: 54).windowDragStrip(probe: "chat_header")
                // The bot's own colour, as a soft wash behind its name: each chat is recognisably its bot's.
                .background(LinearGradient(colors: [bot.tint.opacity(0.13), bot.tint.opacity(0.03)], startPoint: .leading, endPoint: .trailing)).background(AppColor.chat)
            Rectangle().fill(AppColor.separator).frame(height: 0.5)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        ChatTopMarker()
                        if !viewport.hasEarlier, bot.grokSourceID != nil {
                            GrokHistoryView(bot: bot, expanded: historyExpanded, page: viewport.archivePage, showPage: viewport.showArchive)
                                .id(viewport.archivePage == nil ? 0 : viewport.revision)
                        }
                        if bot.messages.isEmpty && bot.grokSourceID == nil { ChatWelcome(bot: bot) }
                        if bot.showsReleaseNotesExample, draft.isEmpty {
                            Button("Draft release notes") {
                                draft = ReleaseNotesExample.prompt
                                store.composerFocus = bot.id
                            }.buttonStyle(.bordered).help("Edit the example changes or send them as written.")
                        }
                        let openers = Self.openers(shown)
                        if viewport.hasEarlier { HistoryPageButton(earlier: true, action: viewport.earlier) }
                        ForEach(shown[viewport.range]) { message in
                            MessageView(message: message, repliedMessage: message.replyToID.flatMap { id in bot.messages.first { $0.id == id } },
                                        actionTarget: .bot(botID: bot.id), reply: { store.replyTo = message }, author: openers.contains(message.id) ? bot : nil).id(message.id).chatRow(message.id)
                                .selectableMessage(message.id, in: selection)
                        }
                        if viewport.hasLater { HistoryPageButton(earlier: false, action: viewport.later) }
                        ChatBottomMarker()
                    }.frame(maxWidth: 720).frame(maxWidth: .infinity).messageSelectionContent(selection).environment(\.chatFolds, folds)
                }.trackChatViewport(viewport).id(bot.id).background(AppColor.chat)
                // ⌘/⇧-click picks rows, ⌘C copies them; another conversation starts with none picked.
                .messageSelection(selection, viewport: viewport).onChange(of: bot.id) { _, _ in selection.clear(); folds.state.foldAll() }
                // Opens where it was left; new rows and streaming text follow only at the bottom.
                // What the person writes with and what waits for them float at the bottom: the transcript passes beneath.
                .floatingBar(edge: .bottom, backing: AppColor.chat) { bottomBar }
                .task(id: viewport.revision) { await viewport.position(proxy: proxy) }
                .onChange(of: shown.last?.content) { _, _ in if !selection.characters.holdsScroll { viewport.grew(proxy: proxy) } }
                .onChange(of: shown.count) { old, new in viewport.arrived(new - old, follow: !selection.characters.holdsScroll) }
                .task(id: store.scrollTarget) { await viewport.reveal(store.scrollTarget, in: store) }
            }
        }.background(AppColor.chat)
            .sheet(item: $terminal) { target in HerdrTerminalSheet(bot: bot, agent: target.agent, title: target.title) }
            .onChange(of: bot.id) { _, _ in terminal = nil }
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

    /// Under the transcript: whom a reply answers, what waits for the person, and the message box. One group, so
    /// that glass surfaces standing close together are drawn together. "Jump to latest" hangs above it.
    private var bottomBar: some View {
        VStack(spacing: 0) {
            if let reply = store.replyTo { HStack { Image(systemName: "arrowshape.turn.up.left"); Text("Replying to \(reply.role == .user ? "you" : bot.name): \(store.displayLine(reply))").lineLimit(1); Spacer(); Button { store.replyTo = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 28).padding(.top, 8).frame(maxWidth: 768) }
            if bot.isReadOnlyArchive {
                Text(bot.retiredBackend.map { "Read-only chat from \($0)." } ?? "Read-only chat from Grok Bot.").font(.system(size: 12)).foregroundStyle(.secondary).padding(14).frame(maxWidth: .infinity)
            } else {
                let helpers = store.herdrHelpers[bot.id]?.inChat ?? []
                // What needs the person waits here, above the message box: an agent that asks something in its
                // terminal; and what the main bot asks: new bots (Create or Not now), additions to "About you"
                // (Remember or Don't save), and, once, the offer to get to know them.
                VStack(spacing: 8) {
                    if bot.backend == .herdr {
                        if store.herdrTerminalSession(for: bot) == nil, store.herdrPrompts[bot.id] == nil, store.herdrReadiness[bot.id]?.isBlocked == true {
                            Button("View terminal") { Task { await store.viewHerdrTerminal(for: bot) } }
                                .buttonStyle(.link).font(.caption)
                        }
                        let server = store.herdrServer(for: bot)
                        HerdrChatApprovals(bot: bot, server: server).id(bot.id.uuidString + server.id + server.address)
                    }
                    if store.createsHerdrBots(bot) {
                        if !bot.messages.isEmpty { HerdrIntroOffer(bot: bot) }
                        HerdrAboutYouCard(bot: bot)
                        HerdrBotRequestCard(manager: bot)
                        HerdrModelChangeCard(manager: bot)
                    }
                    if bot.backend == .herdr, !helpers.isEmpty {
                        HerdrCodingAgentCard(helpers: helpers, tint: bot.colours, openTerminal: { helper in
                            terminal = HerdrTerminalTarget(agent: helper.ref, title: "\(bot.name) · \(helper.name)")
                        }, openDetails: { helper in store.open(helper, of: bot) })
                    }
                }.padding(.top, store.createsHerdrBots(bot) || store.herdrPrompts[bot.id] != nil || !helpers.isEmpty ? 8 : 0).frame(maxWidth: .infinity)
                if let goal = bot.goal {
                    GoalStatusView(bot: bot, goal: goal)
                }
                composer
            }
        }
        .frame(maxWidth: .infinity).glassGroup(spacing: 4)
        .overlay(alignment: .top) { JumpToLatestButton(scroll: store.chatScroll, conversationID: bot.id, action: viewport.latest).alignmentGuide(.top) { $0[.bottom] } }
    }

    private var composer: some View {
        // The main bot's "+" menu: its one action writes a request for a new bot into the composer.
        AttachmentComposer(intake: intake) { attachments in
                     ComposerView(text: $draft, attachments: attachments, isStreaming: store.isStreaming(in: bot), canSteer: store.canSteer(in: bot), awaitingSteer: store.turn(in: bot)?.awaitingSteerCapability == true, hint: store.steerHint ?? store.herdrFirstReplyHint(for: bot),
                     send: send, stop: { store.stop(bot) }, attach: attach, pasteImage: { data, name in if let item = store.prepareAttachment(imageData: data, name: name) { intake.items.append(item) } },
                     reading: intake.reading, cancelReading: intake.cancel, removeAttachment: { intake.remove($0, store: store) },
                     manageActions: store.createsHerdrBots(bot) ? [.newBot, .getToKnowMe] : [],
                     manage: { action in if let request = action.request { draft = request } else { store.chatScroll.toBottom(bot.id); store.startHerdrIntro(for: bot, again: true) } },
                     wantsFocus: store.composerFocus == bot.id, tookFocus: { store.composerFocus = nil }, recipient: bot.name,
                     offersGoal: bot.backend == .herdr && !bot.isDemo && !bot.isReadOnlyArchive,
                     goalCommand: { command in
                         let notice = store.handleGoalCommand(command, in: bot, attachments: intake.items)
                         if case .start = command, notice == nil { intake.items = []; store.replyTo = nil }
                         return notice
                     })
        }
    }
    /// Media tab → Attach puts a saved document into this chat's composer.
    private func takePendingAttachment() {
        guard let pending = store.pendingComposerAttachment, pending.botID == bot.id else { return }
        intake.items.append(pending.attachment); store.pendingComposerAttachment = nil
    }
    private func attach(_ urls: [URL]) { intake.attach(urls, store: store) }
    private func send() {
        guard store.openConversation === bot else { return }
        let value = draft, items = intake.items
        guard !verifyingAttachmentSupport, !intake.isReading,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !items.isEmpty else { return }
        if items.isEmpty || !store.isIdle(bot) { submit(value, items: items); return }
        verifyingAttachmentSupport = true
        Task {
            defer { verifyingAttachmentSupport = false }
            guard await store.confirmHerdrAttachments([bot]), store.selectedGroup == nil && store.selectedBot?.id == bot.id,
                  value == draft, items == intake.items else { return }
            submit(value, items: items)
        }
    }

    private func submit(_ value: String, items: [ChatAttachment]) {
        store.chatScroll.toBottom(bot.id)
        if store.send(text: value, attachments: items) { draft = ""; intake.items = [] }
    }
}

struct ChatModelButton: View {
    let reading: HerdrAgentReading?
    var usage: HerdrClient.SessionUsage? = nil
    let openSettings: () -> Void

    var body: some View {
        Button(action: openSettings) {
            HStack(spacing: 4) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(reading?.headerModel ?? "Model settings")
                    if let next = reading?.pendingTarget {
                        Text("Next direct turn · \(next)").foregroundStyle(.primary)
                    } else if let percent = usage?.contextPercent {
                        Text("Context \(percent)%").foregroundStyle(.secondary).monospacedDigit()
                    } else if let cost = usage?.estimatedCost {
                        Text("Est. \(cost)").foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                Image(systemName: "chevron.right").font(.caption2)
            }
            .lineLimit(1)
            .font(.caption)
        }
        .buttonStyle(.bordered).controlSize(.small)
        .accessibilityIdentifier("chat.bot.model")
        .accessibilityHint("Open this bot’s model settings")
        .help(reading?.summary ?? "Open this bot’s model settings")
    }
}
