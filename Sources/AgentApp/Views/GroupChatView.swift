import SwiftUI

/// A group's shared thread: the user's messages and each member's replies under its own avatar.
struct GroupChatView: View {
    @EnvironmentObject private var store: AppStore; @ObservedObject var group: GroupChat
    @State private var draft = ""; @StateObject private var intake = AttachmentIntake(); @StateObject private var dictation = VoiceDictation()
    @State private var planningWorkflow = false
    @Environment(\.grokHistoryExpanded) private var historyExpanded

    var body: some View {
        let members = store.members(of: group)
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                ShowSidebarItem()
                GroupAvatarStack(group: group, members: members, size: 28, halo: AppColor.chat, probe: "group_header:\(group.id)")
                Button { store.showInfo.toggle() } label: { Text(group.name).font(.system(size: 14, weight: .semibold)).lineLimit(1) }.buttonStyle(.plain)
                Text(members.isEmpty ? "No bots yet" : ([store.userName] + members.map(\.name)).joined(separator: ", ")).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
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
                        ForEach(group.messages) { message in
                            GroupMessageRow(message: message, author: message.authorID.flatMap { id in store.bots.first { $0.id == id } },
                                            repliedMessage: message.replyToID.flatMap { id in group.messages.first { $0.id == id } }, groupID: group.id).id(message.id)
                        }
                        WorkflowView(group: group)
                        ForEach(store.approvals.filter(isGroupApproval)) { request in ApprovalCard(request: request) { store.decide(request, approved: $0) }.id(request.id) }
                        Color.clear.frame(height: 1).id("bottom")
                    }.frame(maxWidth: 720).frame(maxWidth: .infinity)
                }.background(AppColor.chat)
                .onChange(of: group.messages.last?.content) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: group.messages.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            }
            if let reply = store.replyTo {
                HStack { Image(systemName: "arrowshape.turn.up.left"); Text("Replying to \(authorName(reply)): \(reply.content)").lineLimit(1); Spacer(); Button { store.replyTo = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 28).padding(.top, 8).frame(maxWidth: 768)
            }
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
        let steering = !store.isIdle(group)
        if store.send(text: value, attachments: steering ? [] : intake.items, to: group) { draft = ""; if !steering { intake.items = [] } }
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
