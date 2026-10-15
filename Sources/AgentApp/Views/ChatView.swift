import SwiftUI

struct ChatView: View {
    @EnvironmentObject private var store: AppStore; @ObservedObject var bot: Bot; @State private var draft = ""
    @StateObject private var intake = AttachmentIntake(); @StateObject private var dictation = VoiceDictation()
    @Environment(\.grokHistoryExpanded) private var historyExpanded
    var body: some View {
        let thread = store.openThread(in: bot), coding = store.codingThreadChoice(for: bot)
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                ShowSidebarItem()
                if thread != nil { ThreadBackButton() }
                BotAvatar(bot: bot, size: 30, motion: .focus, isWorking: store.isWorking(bot), probe: "chat_header",
                          isWaiting: store.hasPendingApproval(bot))
                Button { store.showInfo.toggle() } label: { Text(bot.name).font(.system(size: 14, weight: .semibold)) }.buttonStyle(.plain)
                if let thread { Text(thread.headerTitle).font(.system(size: 12)).foregroundStyle(.secondary) }
                if let members = bot.archivedMembers { Text("Archived group · \(members.joined(separator: ", "))").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1) }
                Spacer()
                OpenVoiceButton(name: bot.name, target: .bot(botID: bot.id, threadID: thread?.id),
                                messages: { (thread?.messages ?? bot.messages).map { (role: $0.role.rawValue, text: $0.content) } })
                if store.isManager(bot) {
                    ManageBotsMenu(actions: ManageBotsAction.actions(for: bot.backend), perform: manage) { Label("Manage bots", systemImage: "person.2.badge.gearshape").font(.system(size: 12)) }
                }
            }.padding(.horizontal, ChromeMetrics.headerPadding).frame(height: 54).windowDragStrip(probe: "chat_header").background(AppColor.chat)
            Rectangle().fill(AppColor.separator).frame(height: 0.5)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        Color.clear.frame(height: 20)
                        if let thread {
                            ThreadTranscript(thread: thread, parent: bot.messages.first { $0.id == thread.parentMessageID }, botID: bot.id) { proxy.scrollTo("bottom", anchor: .bottom) }
                        } else {
                            if GrokServerArchive.choice(hasLocalArchive: bot.grokSourceID != nil) == .local { GrokHistoryView(bot: bot, expanded: historyExpanded) }
                            if bot.messages.isEmpty && bot.grokSourceID == nil { ChatWelcome(bot: bot) }
                            ForEach(bot.messages) { message in
                                MessageView(message: message, repliedMessage: message.replyToID.flatMap { id in bot.messages.first { $0.id == id } },
                                            thread: bot.thread(for: message.id), canThread: store.canFork(bot), codingModel: coding?.model,
                                            actionTarget: .bot(botID: bot.id, threadID: nil), reply: { store.replyTo = message }, openThread: { store.replyInThread(to: message, in: bot) },
                                            codeInThread: { store.codeInThread(to: message, in: bot) }).id(message.id)
                            }
                        }
                        ForEach(store.approvals.filter { $0.botID == bot.id && !($0.sessionID?.hasPrefix("group-") ?? false) }) { request in ApprovalCard(request: request) { store.decide(request, approved: $0) }.id(request.id) }
                        Color.clear.frame(height: 1).id("bottom")
                    }.frame(maxWidth: 720).frame(maxWidth: .infinity)
                    // P38 B: an app connection card grants access to the bot of this chat only.
                    .environment(\.connectAppBotID, bot.id)
                }.background(AppColor.chat)
                .onChange(of: bot.messages.last?.content) { _, _ in if thread == nil { proxy.scrollTo("bottom", anchor: .bottom) } }
                .onChange(of: bot.messages.count) { _, _ in if thread == nil { proxy.scrollTo("bottom", anchor: .bottom) } }
                .onChange(of: store.scrollTarget) { _, target in
                    guard let target else { return }
                    DispatchQueue.main.async { proxy.scrollTo(target, anchor: .center); store.scrollTarget = nil }
                }
            }
            if let reply = store.replyTo { HStack { Image(systemName: "arrowshape.turn.up.left"); Text("Replying to \(reply.role == .user ? "you" : bot.name): \(reply.content)").lineLimit(1); Spacer(); Button { store.replyTo = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 28).padding(.top, 8).frame(maxWidth: 768) }
            if bot.isReadOnlyArchive {
                Text("Read-only archive imported from Grok Bot.").font(.system(size: 12)).foregroundStyle(.secondary).padding(14).frame(maxWidth: .infinity).background(AppColor.chat)
            } else if bot.isGrokHistoryOnly {
                HistoryOnlyBanner(bot: bot).frame(maxWidth: .infinity).background(AppColor.chat)
            } else if store.needsKey(bot) {
                AddKeyBanner(bot: bot).frame(maxWidth: .infinity).background(AppColor.chat)
            } else {
                if store.isManager(bot) { BotOffersCard(manager: bot).padding(.top, 8).frame(maxWidth: .infinity).background(AppColor.chat) }
                if thread == nil, let banner = store.skillBanner(for: bot) { SkillInstallBanner(bot: bot, state: banner.state).frame(maxWidth: .infinity).background(AppColor.chat) }
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
                     manageActions: store.isManager(bot) && thread == nil ? ManageBotsAction.actions(for: bot.backend) : [], manage: manage,
                     dictationContext: "\(bot.id):\(thread?.id.uuidString ?? "chat")", dictation: dictation)
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
        if store.send(text: value, attachments: steering ? [] : intake.items) { draft = ""; if !steering { intake.items = [] } }
    }
}

/// An open thread: the message it branched from, then the thread's own replies.
private struct ThreadTranscript: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var thread: ChatThread; let parent: ChatMessage?; var botID: UUID? = nil; let scrollToBottom: () -> Void
    var body: some View {
        if let parent { MessageView(message: parent).opacity(0.85) }
        HStack { Rectangle().fill(AppColor.separator).frame(height: 0.5); Text(thread.replyCount == 1 ? "1 reply" : "\(thread.replyCount) replies").font(.caption).foregroundStyle(.secondary).fixedSize(); Rectangle().fill(AppColor.separator).frame(height: 0.5) }
            .padding(.horizontal, 28).padding(.vertical, 6)
        ForEach(thread.messages) { message in
            MessageView(message: message, repliedMessage: message.replyToID.flatMap { id in thread.messages.first { $0.id == id } },
                        actionTarget: botID.map { .bot(botID: $0, threadID: thread.id) }, reply: { store.replyTo = message }).id(message.id)
        }
        Color.clear.frame(height: 0)
            .onChange(of: thread.messages.last?.content) { _, _ in scrollToBottom() }
            .onChange(of: thread.messages.count) { _, _ in scrollToBottom() }
    }
}
