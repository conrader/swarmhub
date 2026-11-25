import SwiftUI

/// A group's shared thread: the user's messages and each member's replies under its own avatar.
struct GroupChatView: View {
    @EnvironmentObject private var store: AppStore; @ObservedObject var group: GroupChat
    @State private var draft = ""; private var intake: AttachmentIntake { store.attachmentIntake(for: group.id) }
    @State private var verifyingAttachmentSupport = false
    @State private var viewport = ChatViewport()
    @State private var selection = MessageSelection()
    @Environment(\.grokHistoryExpanded) private var historyExpanded

    var body: some View {
        let members = store.members(of: group), shown = group.messages.filter { !$0.isSilent }
        let _ = viewport.show(group.id, order: shown.map(\.id))
        let appStore = store, groupName = group.name
        let _ = selection.show(rows: shown, conversation: group.id, body: appStore.transcriptBody) { appStore.copiedMessage($0, botName: groupName) }
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                ShowSidebarItem()
                GroupAvatarStack(group: group, members: members, size: 28, halo: AppColor.chat, probe: "group_header:\(group.id)")
                Button { store.showInfo.toggle() } label: { Text(group.name).font(.system(size: 14, weight: .semibold)).lineLimit(1) }.buttonStyle(.plain)
                Text(members.isEmpty ? "No bots yet" : ([store.userName] + members.map(\.name)).joined(separator: ", ")).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
            }.padding(.horizontal, ChromeMetrics.headerPadding).frame(height: 54).windowDragStrip(probe: "chat_header").background(AppColor.chat)
            Rectangle().fill(AppColor.separator).frame(height: 0.5)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        Color.clear.frame(height: 20)
                        if group.grokSourceID != nil { GrokHistoryView(archiveID: group.id, count: group.grokHistoryCount, ownerName: group.name, expanded: historyExpanded) }
                        if group.messages.isEmpty { Text("Message everyone, or address one bot with @name.").font(.caption).foregroundStyle(.secondary).padding(.vertical, 12) }
                        ForEach(shown) { message in
                            GroupMessageRow(message: message, author: message.authorID.flatMap { id in store.bots.first { $0.id == id } },
                                            repliedMessage: message.replyToID.flatMap { id in group.messages.first { $0.id == id } }, groupID: group.id).id(message.id).chatRow(message.id, in: viewport)
                                .selectableMessage(message.id, in: selection)
                        }
                        ChatBottomMarker(viewport: viewport, conversationID: group.id)
                    }.frame(maxWidth: 720).frame(maxWidth: .infinity).messageSelectionContent(selection)
                }.id(group.id).background(AppColor.chat)
                // ⌘/⇧-click picks rows, ⌘C copies them; another group starts with none picked.
                .messageSelection(selection).onChange(of: group.id) { _, _ in selection.clear() }
                // Opens where it was left; new rows and streaming text follow only at the bottom.
                // The message box floats at the bottom: the transcript passes beneath it.
                .floatingBar(edge: .bottom, backing: AppColor.chat) {
                    VStack(spacing: 0) {
                    if let reply = store.replyTo {
                        HStack { Image(systemName: "arrowshape.turn.up.left"); Text("Replying to \(authorName(reply)): \(store.displayLine(reply))").lineLimit(1); Spacer(); Button { store.replyTo = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }
                            .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 28).padding(.top, 8).frame(maxWidth: 768)
                    }
                    ForEach(store.members(of: group)) { bot in
                        if store.herdrPrompt(for: bot, in: group) != nil {
                            HerdrPromptCard(bot: bot, group: group).padding(.horizontal, 28).padding(.top, 8).frame(maxWidth: 768)
                        } else if let current = store.runningTurns.values.first(where: { $0.conversation === group && $0.botID == bot.id }),
                                  current.assistant?.metadata[TurnKey.agent].flatMap(HerdrTurnStatus.init(code:))?.needsPerson == true {
                            Button("View terminal") {
                                Task { await store.viewHerdrTerminal(for: bot, sessionID: store.turnSessionID(in: group, bot: bot)) }
                            }.buttonStyle(.link).font(.caption)
                        }
                    }
                    AttachmentComposer(intake: intake) { attachments in
                     ComposerView(text: $draft, attachments: attachments, isStreaming: store.isStreaming(in: group), canSteer: store.canSteer(in: group), hint: store.steerHint,
                                 send: send, stop: { store.stop(group) }, attach: { intake.attach($0, store: store) },
                                 pasteImage: { data, name in if let item = store.prepareAttachment(imageData: data, name: name) { intake.items.append(item) } },
                                 reading: intake.reading, cancelReading: intake.cancel, removeAttachment: { intake.remove($0, store: store) },
                                 mentionNames: GroupRouting.mentionable(store.routingMembers(of: group)).map(\.name), recipient: group.name,
                                 goalCommand: { store.handleGoalCommand($0, in: group) })
        }
                    }
                    .frame(maxWidth: .infinity).glassGroup(spacing: 4)
                    .overlay(alignment: .top) { JumpToLatestButton(scroll: store.chatScroll, conversationID: group.id, proxy: proxy).alignmentGuide(.top) { $0[.bottom] } }
                }
                .task(id: group.id) { await viewport.open(group.id, model: store.chatScroll, proxy: proxy) }
                .onChange(of: shown.last?.content) { _, _ in if !selection.characters.holdsScroll { viewport.grew(proxy: proxy) } }
                .onChange(of: shown.count) { old, new in viewport.arrived(new - old, proxy: proxy, follow: !selection.characters.holdsScroll) }
            }
        }.background(AppColor.chat)
            .dropDestination(for: URL.self) { urls, _ in
                let files = urls.filter(\.isFileURL)
                guard !files.isEmpty else { return false }
                intake.attach(files, store: store); return true
            }
            .task(id: group.id) { draft = store.drafts.text(for: group.id) }
            .onChange(of: draft) { _, value in store.drafts.set(value, for: group.id) }
    }

    private func authorName(_ message: ChatMessage) -> String {
        message.role == .user ? "you" : message.authorID.flatMap { id in store.bots.first { $0.id == id }?.name } ?? "bot"
    }
    private func send() {
        let value = draft, items = intake.items
        guard !verifyingAttachmentSupport, !intake.isReading,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !items.isEmpty else { return }
        if items.isEmpty || !store.isIdle(group) { submit(value, items: items); return }
        verifyingAttachmentSupport = true
        Task {
            defer { verifyingAttachmentSupport = false }
            guard await store.confirmHerdrAttachments(store.groupRecipients(of: value, in: group)), store.selectedGroup?.id == group.id,
                  value == draft, items == intake.items else { return }
            submit(value, items: items)
        }
    }

    private func submit(_ value: String, items: [ChatAttachment]) {
        store.chatScroll.toBottom(group.id)
        if store.send(text: value, attachments: items, to: group) { draft = ""; intake.items = [] }
    }
}

/// A member's reply carries its avatar and name; user and system lines render as in a one-bot chat.
private struct GroupMessageRow: View {
    @EnvironmentObject private var store: AppStore
    let message: ChatMessage; let author: Bot?; let repliedMessage: ChatMessage?; let groupID: UUID
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if message.role == .assistant {
                HStack(spacing: 7) {
                    if let author { BotAvatar(bot: author, size: 22) } else { Image(systemName: "person.crop.circle.badge.questionmark").frame(width: 22, height: 22) }
                    Text(author?.name ?? "Removed bot").font(.system(size: 12, weight: .semibold))
                }.padding(.horizontal, 28).padding(.top, 8)
            }
            MessageView(message: message, repliedMessage: repliedMessage,
                        actionTarget: message.authorID.map { .group(groupID: groupID, botID: $0) }, reply: { store.replyTo = message })
        }
    }
}
