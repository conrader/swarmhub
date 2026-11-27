import SwiftUI

/// A group's shared thread: the user's messages and each member's replies under its own avatar.
struct GroupChatView: View {
    @Environment(\.workspaceApprovals) private var approvalInboxes
    @EnvironmentObject private var store: AppStore; @ObservedObject var group: GroupChat
    @State private var draft: String; private var intake: AttachmentIntake { store.attachmentIntake(for: group.id) }
    @State private var verifyingAttachmentSupport = false
    @StateObject private var viewport = ChatViewport()
    @State private var selection = MessageSelection()
    @Environment(\.grokHistoryExpanded) private var historyExpanded

    init(group: GroupChat, initialDraft: String = "") {
        self.group = group
        _draft = State(initialValue: initialDraft)
    }

    private var jumpToLatest: JumpToLatestButton {
        JumpToLatestButton(scroll: store.chatScroll, conversationID: group.id, action: viewport.latest)
    }

    var body: some View {
        let members = store.members(of: group), shown = group.messages.filter { !$0.isSilent }
        let _ = viewport.show(group.id, order: shown.map(\.id), model: store.chatScroll)
        let appStore = store, groupName = group.name
        let _ = selection.show(rows: shown, conversation: group.id, body: appStore.transcriptBody) { appStore.copiedMessage($0, botName: groupName) }
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                ShowSidebarItem()
                GroupAvatarStack(group: group, members: members, size: 28, halo: AppColor.chat, probe: "group_header:\(group.id)")
                Button { store.showInfo.toggle() } label: { Text(group.name).font(.system(size: 14, weight: .semibold)).lineLimit(1) }.buttonStyle(.plain)
                Text(members.isEmpty ? "No bots yet" : ([store.userName] + members.map(\.name)).joined(separator: ", ")).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if let bot = members.first(where: { $0.backend == .herdr }) {
                    Button("Terminals", systemImage: "terminal") {
                        store.previewInInspector(TerminalBrowserRequest(server: store.herdrServer(for: bot), groupID: group.id))
                    }.controlSize(.small).accessibilityLabel("Group terminals")
                }
                ShowDetailsItem()
            }.padding(.horizontal, ChromeMetrics.headerPadding).frame(height: 54).windowDragStrip(probe: "chat_header").background(AppColor.chat)
            Rectangle().fill(AppColor.separator).frame(height: 0.5)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        ChatTopMarker()
                        if !viewport.hasEarlier, group.grokSourceID != nil {
                            GrokHistoryView(archiveID: group.id, count: group.grokHistoryCount, ownerName: group.name, expanded: historyExpanded, page: viewport.archivePage, showPage: viewport.showArchive)
                                .id(viewport.archivePage == nil ? 0 : viewport.revision)
                        }
                        if group.messages.isEmpty { Text("Message everyone, or address one bot with @name.").font(.caption).foregroundStyle(.secondary).padding(.vertical, 12) }
                        if viewport.hasEarlier { HistoryPageButton(earlier: true, action: viewport.earlier) }
                        ForEach(shown[viewport.range]) { message in
                            GroupMessageRow(message: message, author: message.authorID.flatMap { id in store.bots.first { $0.id == id } },
                                            repliedMessage: message.replyToID.flatMap { id in group.messages.first { $0.id == id } }, groupID: group.id).id(message.id).chatRow(message.id)
                                .selectableMessage(message.id, in: selection)
                        }
                        if viewport.hasLater { HistoryPageButton(earlier: false, action: viewport.later) }
                        ChatBottomMarker()
                    }.frame(maxWidth: 720).frame(maxWidth: .infinity).messageSelectionContent(selection)
                }.trackChatViewport(viewport, follow: { !selection.characters.holdsScroll }).id(group.id).background(AppColor.chat)
                // ⌘/⇧-click picks rows, ⌘C copies them; another group starts with none picked.
                .messageSelection(selection, viewport: viewport).onChange(of: group.id) { _, _ in selection.clear() }
                // Opens where it was left; new rows and streaming text follow only at the bottom.
                // The message box floats at the bottom: the transcript passes beneath it.
                .floatingBar(edge: .bottom, backing: AppColor.chat) {
                    VStack(spacing: 0) {
                    if store.helperSteeringDrafts[group.id] == nil, let reply = store.replyTo {
                        HStack { Image(systemName: "arrowshape.turn.up.left"); Text("Replying to \(authorName(reply)): \(store.displayLine(reply))").lineLimit(1); Spacer(); Button { store.replyTo = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }
                            .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 28).padding(.top, 8).frame(maxWidth: 768)
                    }
                    ForEach(store.members(of: group)) { bot in
                        if store.herdrPrompt(for: bot, in: group) != nil || !store.approvals(for: bot, in: group, inboxes: approvalInboxes).isEmpty {
                            HerdrChatApprovals(bot: bot, server: store.herdrServer(for: bot), group: group).padding(.horizontal, 28).padding(.top, 8).frame(maxWidth: 768)
                        } else if let current = store.runningTurns.values.first(where: { $0.conversation === group && $0.botID == bot.id }),
                                  current.assistant?.metadata[TurnKey.agent].flatMap(HerdrTurnStatus.init(code:))?.needsPerson == true {
                            Button("View terminal") {
                                Task { await store.viewHerdrTerminal(for: bot, sessionID: store.turnSessionID(in: group, bot: bot)) }
                            }.buttonStyle(.link).font(.caption)
                        }
                    }
                    if let guidance = store.helperSteeringDrafts[group.id] {
                        HelperSteeringComposer(draft: guidance, chatID: group.id, jump: jumpToLatest).id(ObjectIdentifier(guidance))
                    } else {
                        AttachmentComposer(intake: intake) { attachments in
                         ComposerView(text: $draft, attachments: attachments, jump: jumpToLatest, isStreaming: store.isStreaming(in: group), canSteer: store.canSteer(in: group), hint: store.steerHint,
                                     send: send, stop: { store.stop(group) }, attach: { intake.attach($0, store: store) },
                                     pasteImage: { data, name in if let item = store.prepareAttachment(imageData: data, name: name) { intake.items.append(item) } },
                                     reading: intake.reading, cancelReading: intake.cancel, removeAttachment: { intake.remove($0, store: store) },
                                     mentionNames: GroupRouting.mentionable(store.routingMembers(of: group)).map(\.name), wantsFocus: store.composerFocus == group.id, tookFocus: { store.composerFocus = nil }, recipient: group.name,
                                     goalCommand: { store.handleGoalCommand($0, in: group) })
                        }
                    }
                    }
                    .frame(maxWidth: .infinity).glassGroup(spacing: 4)
                }
                .task(id: store.scrollTarget) { await viewport.reveal(store.scrollTarget, in: store) }
                .task(id: viewport.revision) { await viewport.position(proxy: proxy) }
                .onChange(of: shown.last?.content) { _, _ in if !selection.characters.holdsScroll { viewport.grew(proxy: proxy) } }
                .onChange(of: shown.count) { old, new in viewport.arrived(new - old, follow: !selection.characters.holdsScroll) }
            }
        }.background(AppColor.chat)
            .dropDestination(for: URL.self) { urls, _ in
                let files = urls.filter(\.isFileURL)
                guard !files.isEmpty else { return false }
                intake.attach(files, store: store); return true
            }
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
        MessageView(message: message, repliedMessage: repliedMessage,
                    actionTarget: message.authorID.map { .group(groupID: groupID, botID: $0) },
                    reply: { store.replyTo = message }, author: author, showsRemovedAuthor: author == nil)
    }
}
