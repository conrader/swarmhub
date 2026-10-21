import SwiftUI

struct ChatView: View {
    @EnvironmentObject private var store: AppStore; @ObservedObject var bot: Bot; @State private var draft = ""
    @StateObject private var intake = AttachmentIntake(); @StateObject private var dictation = VoiceDictation()
    @State private var showProjectContext = false; @State private var viewport = ChatViewport()
    @State private var selection = MessageSelection()
    @Environment(\.grokHistoryExpanded) private var historyExpanded
    var body: some View {
        let thread = store.openThread(in: bot), coding = store.codingThreadChoice(for: bot)
        let incoming = store.isWorking(bot) ? nil : store.workingForOthersLine(for: bot)
        // P51: technical rows read as one folded line; an app request's result row is part of its line.
        let all = bot.messages.filter { !$0.isSilent && !$0.isSilentHeartbeat }, layout = store.technicalLayout(all, botName: bot.name)
        let shown = layout.visible(all), conversationID = thread?.id ?? bot.id
        let threadRows = thread.map { $0.messages.filter { !$0.isSilent && !$0.isSilentHeartbeat } }
        let threadLayout = threadRows.map { store.technicalLayout($0, botName: bot.name) }
        let threadShown = threadRows.map { threadLayout?.visible($0) ?? $0 }
        let arrivals = thread == nil ? [] : store.arrivalsAboveThread(in: bot)
        let parent = thread.flatMap { thread in bot.messages.first { $0.id == thread.parentMessageID } }
        let order = threadShown.map { arrivals.map(\.id) + $0.map(\.id) } ?? shown.map(\.id)
        let _ = viewport.show(conversationID, order: order)
        let appStore = store, botName = bot.name
        let pickable: [ChatMessage] = threadShown.map { rows in arrivals + [parent].compactMap { $0 } + rows } ?? shown
        // Arrivals use the main layout, replies use the thread layout, and the parent is displayed on its own.
        let copyFolds = layout.folds.merging(threadLayout?.folds ?? [:]) { _, reply in reply }
            .merging(store.technicalLayout([parent].compactMap { $0 }, botName: botName).folds) { _, parent in parent }
        let _ = selection.show(rows: pickable) { appStore.copiedMessage($0, botName: botName, fold: copyFolds[$0.id]) }
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                ShowSidebarItem()
                if thread != nil { ThreadBackButton() }
                BotAvatar(bot: bot, size: 30, motion: .focus, isWorking: store.isWorking(bot) || incoming != nil, probe: "chat_header",
                          isWaiting: store.hasPendingApproval(bot))
                Button { store.showInfo.toggle() } label: { Text(bot.name).font(.system(size: 14, weight: .semibold)) }.buttonStyle(.plain)
                if let thread { Text(thread.headerTitle).font(.system(size: 12)).foregroundStyle(.secondary) }
                if let incoming { Text(incoming).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1) }
                if let members = bot.archivedMembers { Text("Archived group · \(members.joined(separator: ", "))").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1) }
                Spacer()
                Button { showProjectContext = true } label: { Image(systemName: "text.book.closed") }.help("Shared project context")
                OpenVoiceButton(name: bot.name, target: .bot(botID: bot.id, threadID: thread?.id),
                                messages: { (thread?.messages ?? bot.messages).map { (role: $0.role.rawValue, text: $0.content) } })
                if store.isManager(bot) {
                    ManageBotsMenu(actions: ManageBotsAction.actions(for: bot.backend), perform: manage) { Label("Manage bots", systemImage: "person.2.badge.gearshape").font(.system(size: 12)) }
                }
            }.padding(.horizontal, ChromeMetrics.headerPadding).frame(height: 54).windowDragStrip(probe: "chat_header").background(AppColor.chat)
            Rectangle().fill(AppColor.separator).frame(height: 0.5)
            AutomationStrip(bot: bot, conversation: thread ?? bot)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        Color.clear.frame(height: 20)
                        if let thread {
                            // P41: an arrival shows here too, whatever thread is open.
                            ForEach(arrivals) { MessageView(message: $0, fold: layout.folds[$0.id]).id($0.id).chatRow($0.id, in: viewport).selectableMessage($0.id, in: selection) }
                            ThreadTranscript(thread: thread, parent: parent, botID: bot.id, botName: bot.name, viewport: viewport, selection: selection) { count in
                                if count > 0 { viewport.arrived(count, proxy: proxy) } else { viewport.grew(proxy: proxy) }
                            }
                        } else {
                            if GrokServerArchive.choice(hasLocalArchive: bot.grokSourceID != nil) == .local { GrokHistoryView(bot: bot, expanded: historyExpanded) }
                            if bot.messages.isEmpty && bot.grokSourceID == nil { ChatWelcome(bot: bot) }
                            ForEach(shown) { message in
                                MessageView(message: message, repliedMessage: message.replyToID.flatMap { id in bot.messages.first { $0.id == id } },
                                            thread: bot.thread(for: message.id), canThread: store.canFork(bot), codingModel: coding?.model,
                                            actionTarget: .bot(botID: bot.id, threadID: nil), fold: layout.folds[message.id], partner: layout.folds[message.id]?.partnerID.flatMap { id in all.first { $0.id == id } },
                                            reply: { store.replyTo = message }, openThread: { store.replyInThread(to: message, in: bot) },
                                            codeInThread: { store.codeInThread(to: message, in: bot) }).id(message.id).chatRow(message.id, in: viewport)
                                    .selectableMessage(message.id, in: selection)
                            }
                        }
                        TeamWorkView(conversationID: thread?.id ?? bot.id)
                        ForEach(store.approvals.filter { $0.botID == bot.id && !($0.sessionID?.hasPrefix("group-") ?? false) }) { request in ApprovalCard(request: request) { store.decide(request, approved: $0) }.id(request.id) }
                        ChatBottomMarker(viewport: viewport, conversationID: conversationID)
                    }.frame(maxWidth: 720).frame(maxWidth: .infinity).messageSelectionContent(selection)
                    // P38 B: an app connection card grants access to the bot of this chat only.
                    .environment(\.connectAppBotID, bot.id)
                }.id(conversationID).background(AppColor.chat)
                // ⌘/⇧-click picks rows, ⌘C copies them; another conversation starts with none picked.
                .messageSelection(selection).onChange(of: conversationID) { _, _ in selection.clear() }
                // P50: opens where it was left; new rows and streaming text follow only at the bottom.
                .overlay(alignment: .bottom) { JumpToLatestButton(scroll: store.chatScroll, conversationID: conversationID, proxy: proxy) }
                .task(id: conversationID) { await viewport.open(conversationID, model: store.chatScroll, proxy: proxy) }
                .onChange(of: shown.last?.content) { _, _ in if thread == nil { viewport.grew(proxy: proxy) } }
                .onChange(of: shown.count) { old, new in if thread == nil { viewport.arrived(new - old, proxy: proxy) } }
                .onChange(of: store.scrollTarget) { _, target in
                    guard let target else { return }
                    DispatchQueue.main.async { proxy.scrollTo(target, anchor: .center); store.scrollTarget = nil }
                }
            }
            if let reply = store.replyTo { HStack { Image(systemName: "arrowshape.turn.up.left"); Text("Replying to \(reply.role == .user ? "you" : bot.name): \(store.technicalLine(reply, botName: bot.name))").lineLimit(1); Spacer(); Button { store.replyTo = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 28).padding(.top, 8).frame(maxWidth: 768) }
            if bot.isReadOnlyArchive {
                Text("Read-only archive imported from Grok Bot.").font(.system(size: 12)).foregroundStyle(.secondary).padding(14).frame(maxWidth: .infinity).background(AppColor.chat)
            } else if bot.isGrokHistoryOnly {
                HistoryOnlyBanner(bot: bot).frame(maxWidth: .infinity).background(AppColor.chat)
            } else if store.needsKey(bot) {
                AddKeyBanner(bot: bot).frame(maxWidth: .infinity).background(AppColor.chat)
            } else {
                if store.isManager(bot) { BotOffersCard(manager: bot).padding(.top, 8).frame(maxWidth: .infinity).background(AppColor.chat) }
                if thread == nil, let banner = store.skillBanner(for: bot) { SkillInstallBanner(bot: bot, skill: banner.skill, state: banner.state).frame(maxWidth: .infinity).background(AppColor.chat) }
                else if thread == nil, store.isManager(bot), bot.backend == .hermes { AllBotsSkillsBanner(manager: bot).frame(maxWidth: .infinity).background(AppColor.chat) }
                if store.mentionSkillOffer == bot.id { MentionSkillOffer(bot: bot).frame(maxWidth: .infinity).background(AppColor.chat) }
                if bot.backend == .openClaw {
                    OpenClawChatGate(status: store.openClawStatus, bot: bot) { composer(thread: thread) }.background(AppColor.chat)
                } else {
                    composer(thread: thread).background(AppColor.chat)
                }
            }
        }.background(AppColor.chat)
            .dropDestination(for: URL.self) { urls, _ in
                let files = urls.filter(\.isFileURL)
                guard !files.isEmpty, !bot.isReadOnlyArchive, !bot.isGrokHistoryOnly else { return false }
                attach(files); return true
            }
            .sheet(isPresented: $showProjectContext) { ProjectContextView(projectID: thread?.id ?? bot.id, members: [bot] + store.mentionTargets(for: bot)) }
            // P06 gap: a bot's secret request opens the entry sheet in its own chat; the bot gets the file path only.
            .sheet(item: Binding(get: { store.secretRequest?.botID == bot.id ? store.secretRequest : nil }, set: { if $0 == nil { store.secretRequest = nil } })) { SecretEntrySheet(prompt: $0) }
            .task(id: bot.id) { UISmokeProbe.renderedChats.insert(bot.id); draft = store.drafts.text(for: bot.id); store.refreshFeatures(for: bot); takeComposerFill() }
            .onChange(of: draft) { _, value in store.drafts.set(value, for: bot.id) }
            .onChange(of: store.composerFill) { _, _ in takeComposerFill() }
            .onChange(of: store.pendingComposerAttachment) { _, _ in takePendingAttachment() }
    }
    private func composer(thread: ChatThread?) -> some View {
        let conversation: any Conversation = thread ?? bot
        return ComposerView(text: $draft, attachments: $intake.items, isStreaming: store.isStreaming(in: conversation), canSteer: store.canSteer(in: conversation), hint: store.steerHint,
                     send: send, stop: { store.stop(conversation) }, attach: attach, pasteImage: { data, name in if let item = store.prepareAttachment(imageData: data, name: name) { intake.items.append(item) } },
                     reading: intake.reading, cancelReading: intake.cancel, removeAttachment: { intake.remove($0, store: store) },
                     mentionNames: store.mentionTargets(for: bot).map(store.mentionLabel),
                     manageActions: store.isManager(bot) && thread == nil ? ManageBotsAction.actions(for: bot.backend) : [], manage: manage,
                     dictationContext: "\(bot.id):\(thread?.id.uuidString ?? "chat")", slashCommands: bot.isReadOnlyArchive ? [] : SlashCommand.menu, dictation: dictation)
    }
    private func manage(_ action: ManageBotsAction) { store.startManagement(action, manager: bot) }
    /// A Manage bots request for this chat replaces the draft.
    private func takeComposerFill() {
        guard let fill = store.composerFill, fill.botID == bot.id else { return }
        draft = fill.text; store.composerFill = nil
    }
    /// P38: Media tab → Attach puts a saved document into this chat's composer.
    private func takePendingAttachment() {
        guard let pending = store.pendingComposerAttachment, pending.botID == bot.id else { return }
        intake.items.append(pending.attachment); store.pendingComposerAttachment = nil
    }
    private func attach(_ urls: [URL]) { intake.attach(urls, store: store) }
    private func send() {
        let value = draft; guard !intake.isReading, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !intake.items.isEmpty else { return }
        let steering = !store.isIdle(store.currentConversation(of: bot))
        // P50: sending always goes to the bottom.
        store.chatScroll.toBottom(store.currentConversation(of: bot).id)
        if store.submitComposer(text: value, attachments: steering ? [] : intake.items) { draft = ""; if !steering { intake.items = [] } }
    }
}

/// An open thread: the message it branched from, then the thread's own replies.
private struct ThreadTranscript: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var thread: ChatThread; let parent: ChatMessage?; var botID: UUID? = nil; var botName = ""; let viewport: ChatViewport
    let selection: MessageSelection
    /// Rows that arrived (0: the newest row's text grew).
    let changed: (Int) -> Void
    var body: some View {
        let rows = thread.messages.filter { !$0.isSilent && !$0.isSilentHeartbeat }, layout = store.technicalLayout(rows, botName: botName)
        if let parent { MessageView(message: parent, fold: store.technicalLayout([parent], botName: botName).folds[parent.id]).opacity(0.85).selectableMessage(parent.id, in: selection) }
        HStack { Rectangle().fill(AppColor.separator).frame(height: 0.5); Text(thread.replyCount == 1 ? "1 reply" : "\(thread.replyCount) replies").font(.caption).foregroundStyle(.secondary).fixedSize(); Rectangle().fill(AppColor.separator).frame(height: 0.5) }
            .padding(.horizontal, 28).padding(.vertical, 6)
        ForEach(layout.visible(rows)) { message in
            MessageView(message: message, repliedMessage: message.replyToID.flatMap { id in thread.messages.first { $0.id == id } },
                        actionTarget: botID.map { .bot(botID: $0, threadID: thread.id) }, fold: layout.folds[message.id],
                        partner: layout.folds[message.id]?.partnerID.flatMap { id in rows.first { $0.id == id } }, reply: { store.replyTo = message }).id(message.id).chatRow(message.id, in: viewport)
                .selectableMessage(message.id, in: selection)
        }
        Color.clear.frame(height: 0)
            .onChange(of: thread.messages.last?.content) { _, _ in changed(0) }
            .onChange(of: thread.messages.count) { old, new in changed(max(new - old, 0)) }
    }
}
