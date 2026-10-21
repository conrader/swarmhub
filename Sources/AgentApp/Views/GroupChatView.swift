import SwiftUI

/// A group's shared thread: the user's messages and each member's replies under its own avatar.
struct GroupChatView: View {
    @EnvironmentObject private var store: AppStore; @ObservedObject var group: GroupChat
    @State private var draft = ""; @StateObject private var intake = AttachmentIntake(); @StateObject private var dictation = VoiceDictation()
    @State private var planningWorkflow = false
    @State private var workTogether = false
    @State private var showProjectContext = false; @State private var viewport = ChatViewport()
    @State private var selection = MessageSelection()
    @Environment(\.grokHistoryExpanded) private var historyExpanded

    var body: some View {
        let members = store.members(of: group), all = group.messages.filter { !$0.isSilent }
        let layout = store.technicalLayout(all, in: group), shown = layout.visible(all)
        let _ = viewport.show(group.id, order: shown.map(\.id))
        let appStore = store, groupName = group.name
        let _ = selection.show(rows: shown) { appStore.copiedMessage($0, botName: groupName, fold: layout.folds[$0.id]) }
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                ShowSidebarItem()
                GroupAvatarStack(group: group, members: members, size: 28, halo: AppColor.chat, probe: "group_header:\(group.id)")
                Button { store.showInfo.toggle() } label: { Text(group.name).font(.system(size: 14, weight: .semibold)).lineLimit(1) }.buttonStyle(.plain)
                Text(members.isEmpty ? "No bots yet" : ([store.userName] + members.map(\.name)).joined(separator: ", ")).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button { showProjectContext = true } label: { Image(systemName: "text.book.closed") }.help("Shared project context")
                if !members.isEmpty {
                    Button { planningWorkflow = true } label: { Label("Plan a workflow", systemImage: "list.bullet.rectangle") }
                        .buttonStyle(.borderless).help("Plan a workflow: a coordinator splits a request into tasks for the members")
                }
                OpenVoiceButton(name: group.name, target: group.memberIDs.first.map { .group(groupID: group.id, botID: $0) },
                                messages: { group.messages.map { (role: $0.role.rawValue, text: $0.content) } })
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
                                            repliedMessage: message.replyToID.flatMap { id in group.messages.first { $0.id == id } }, groupID: group.id,
                                            fold: layout.folds[message.id], partner: layout.folds[message.id]?.partnerID.flatMap { id in all.first { $0.id == id } }).id(message.id).chatRow(message.id, in: viewport)
                                .selectableMessage(message.id, in: selection)
                        }
                        WorkflowView(group: group)
                        ForEach(store.approvals.filter(isGroupApproval)) { request in ApprovalCard(request: request) { store.decide(request, approved: $0) }.id(request.id) }
                        ChatBottomMarker(viewport: viewport, conversationID: group.id)
                    }.frame(maxWidth: 720).frame(maxWidth: .infinity).messageSelectionContent(selection)
                }.id(group.id).background(AppColor.chat)
                // ⌘/⇧-click picks rows, ⌘C copies them; another group starts with none picked.
                .messageSelection(selection).onChange(of: group.id) { _, _ in selection.clear() }
                // P50: opens where it was left; new rows and streaming text follow only at the bottom.
                .overlay(alignment: .bottom) { JumpToLatestButton(scroll: store.chatScroll, conversationID: group.id, proxy: proxy) }
                .task(id: group.id) { await viewport.open(group.id, model: store.chatScroll, proxy: proxy) }
                .onChange(of: shown.last?.content) { _, _ in viewport.grew(proxy: proxy) }
                .onChange(of: shown.count) { old, new in viewport.arrived(new - old, proxy: proxy) }
            }
            if let reply = store.replyTo {
                HStack { Image(systemName: "arrowshape.turn.up.left"); Text("Replying to \(authorName(reply)): \(store.technicalLine(reply))").lineLimit(1); Spacer(); Button { store.replyTo = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 28).padding(.top, 8).frame(maxWidth: 768)
            }
            Toggle("Work together", isOn: $workTogether).toggleStyle(.switch).font(.caption).padding(.horizontal, 28)
                .help("Allow directed questions, corrections and review within this request. New work runs only while SwarmHub is available.")
            ComposerView(text: $draft, attachments: $intake.items, isStreaming: store.isStreaming(in: group), canSteer: store.canSteer(in: group), hint: store.steerHint,
                         send: send, stop: { store.stop(group) }, attach: { intake.attach($0, store: store) },
                         pasteImage: { data, name in if let item = store.prepareAttachment(imageData: data, name: name) { intake.items.append(item) } },
                         reading: intake.reading, cancelReading: intake.cancel, removeAttachment: { intake.remove($0, store: store) },
                         mentionNames: GroupRouting.mentionable(store.routingMembers(of: group)).map(\.name),
                         dictationContext: group.id.uuidString, dictation: dictation)
                .background(AppColor.chat)
        }.background(AppColor.chat)
            .dropDestination(for: URL.self) { urls, _ in
                let files = urls.filter(\.isFileURL)
                guard !files.isEmpty else { return false }
                intake.attach(files, store: store); return true
            }
            .sheet(isPresented: $showProjectContext) { ProjectContextView(projectID: group.id, members: members) }
            .sheet(isPresented: $planningWorkflow) { WorkflowStartSheet(group: group) }
            .task(id: group.id) { draft = store.drafts.text(for: group.id) }
            .onChange(of: draft) { _, value in store.drafts.set(value, for: group.id) }
    }

    private func isGroupApproval(_ request: ApprovalRequest) -> Bool {
        guard let session = request.sessionID, let botID = request.botID else { return false }
        return session == group.session(for: botID) || session == GroupRouting.sessionID(group: group.id, bot: botID)
    }
    private func authorName(_ message: ChatMessage) -> String {
        message.role == .user ? "you" : message.authorID.flatMap { id in store.bots.first { $0.id == id }?.name } ?? "bot"
    }
    private func send() {
        let value = draft; guard !intake.isReading, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !intake.items.isEmpty else { return }
        store.chatScroll.toBottom(group.id) // P50: sending always goes to the bottom.
        if workTogether, let coordinator = store.members(of: group).first {
            guard intake.items.isEmpty else { store.errorMessage = "Add documents through shared project context or send them in a regular group round first."; return }
            let roster = store.members(of: group)
            let targets = GroupRouting.recipients(of: value, members: store.routingMembers(of: group))
            let recipient = roster.first { targets.contains($0.id) } ?? coordinator
            if store.startTeamRequest(value, origin: group, coordinator: coordinator, recipient: recipient, roster: roster) { draft = "" }
            return
        }
        let steering = !store.isIdle(group)
        if store.send(text: value, attachments: steering ? [] : intake.items, to: group) { draft = ""; if !steering { intake.items = [] } }
    }
}

/// A member's reply carries its avatar and name; user and system lines render as in a one-bot chat.
private struct GroupMessageRow: View {
    @EnvironmentObject private var store: AppStore
    let message: ChatMessage; let author: Bot?; let repliedMessage: ChatMessage?; let groupID: UUID
    var fold: TechnicalFold? = nil; var partner: ChatMessage? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if message.role == .assistant {
                HStack(spacing: 7) {
                    if let author { BotAvatar(bot: author, size: 22) } else { Image(systemName: "person.crop.circle.badge.questionmark").frame(width: 22, height: 22) }
                    Text(author?.name ?? "Removed bot").font(.system(size: 12, weight: .semibold))
                }.padding(.horizontal, 28).padding(.top, 8)
            }
            MessageView(message: message, repliedMessage: repliedMessage,
                        actionTarget: message.authorID.map { .group(groupID: groupID, botID: $0) }, fold: fold, partner: partner, reply: { store.replyTo = message })
        }
    }
}
