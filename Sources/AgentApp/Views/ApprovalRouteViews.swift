import SwiftUI

/// P37 D5: "<reviewer avatar> Approved by Jarvis · All bots line 1: Anything → Reviewer: Jarvis" under an approval a
/// rule or a reviewer decided.
struct ApprovalDecisionLine: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var message: ChatMessage
    var body: some View {
        let reviewer = message.metadata[ApprovalCardKey.decider].flatMap(UUID.init(uuidString:)).flatMap { id in store.bots.first { $0.id == id } }
        let approved = message.metadata[ApprovalCardKey.outcome] == "approved"
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let reviewer { BotAvatar(bot: reviewer, size: 18) } else { Image(systemName: "list.bullet.rectangle").foregroundStyle(.secondary) }
                Text(message.content).font(.caption.weight(.medium))
                Spacer(minLength: 0)
                Text(approved ? (reviewer.map { "Approved by \($0.name)" } ?? "Approved by rule") : (reviewer.map { "Declined by \($0.name)" } ?? "Declined by rule"))
                    .font(.caption2.weight(.semibold)).foregroundStyle(approved ? .green : .orange)
            }
            if let rule = message.metadata[ApprovalCardKey.rule] { Text(rule).font(.caption2).foregroundStyle(.secondary).lineLimit(2) }
        }.padding(10).frame(maxWidth: 520, alignment: .leading)
            .background(AppColor.card, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(AppColor.separator, lineWidth: 0.5))
            .padding(.vertical, 3)
    }
}

/// D4: the verdict under the reviewed reply: Looks good / Changes requested + notes, and "Send notes to <bot>".
struct ReviewCard: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var message: ChatMessage
    var body: some View {
        let reviewer = message.metadata[ReviewKey.reviewer].flatMap(UUID.init(uuidString:)).flatMap { id in store.bots.first { $0.id == id } }
        let state = message.metadata[ReviewKey.state] ?? "pending"
        let owner = store.conversation(containing: message.id).flatMap(store.owner(of:))
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let reviewer { BotAvatar(bot: reviewer, size: 22) }
                VStack(alignment: .leading, spacing: 1) {
                    Text("Review by \(reviewer?.name ?? "reviewer")").font(.caption.weight(.semibold))
                    if let why = message.metadata[ReviewKey.why] { Text("After it \(why)").font(.caption2).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 0)
                badge(state)
            }
            if state == "pending" { HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Waiting for the verdict…").font(.caption).foregroundStyle(.secondary) } }
            if let notes = message.metadata[ReviewKey.notes], !notes.isEmpty {
                Text(notes).font(.system(size: 12.5)).textSelection(.enabled).padding(9).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
            }
            if message.metadata[ReviewKey.sent] != nil {
                Label("Notes sent to \(owner?.name ?? "the bot")", systemImage: "arrow.turn.down.right").font(.caption).foregroundStyle(.secondary)
            } else if store.canSendReviewNotes(message) {
                HStack { Spacer(); Button("Send notes to \(owner?.name ?? "bot")") { store.sendReviewNotes(message) }.buttonStyle(NeutralPrimaryButtonStyle()) }
            }
        }.padding(12).frame(maxWidth: 520, alignment: .leading)
            .background(AppColor.card, in: RoundedRectangle(cornerRadius: 11)).overlay(RoundedRectangle(cornerRadius: 11).stroke(AppColor.separator, lineWidth: 0.5))
            .padding(.vertical, 4)
    }
    @ViewBuilder private func badge(_ state: String) -> some View {
        switch state {
        case "ok": Label("Looks good", systemImage: "checkmark.seal.fill").font(.caption.weight(.semibold)).foregroundStyle(.green)
        case "changes": Label("Changes requested", systemImage: "exclamationmark.bubble.fill").font(.caption.weight(.semibold)).foregroundStyle(.orange)
        case "text": Label("Reviewed", systemImage: "text.bubble").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        case "failed": Label("No review", systemImage: "xmark.circle").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        default: EmptyView()
        }
    }
}

/// D1/D2: an ordered list of routing lines (first match wins) and, for a bot, its "anything else" line.
struct ApprovalRouteEditor: View {
    @EnvironmentObject private var store: AppStore
    @Binding var lines: [ApprovalRoute]
    var otherwise: Binding<ApprovalRoute>?
    let excluding: UUID?
    var body: some View {
        ForEach($lines) { $line in
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("When").foregroundStyle(.secondary)
                    if line.legacyActionPattern != nil {
                        TextField("Action", text: Binding(get: { line.legacyActionPattern ?? "" }, set: { line.legacyActionPattern = $0 })).frame(width: 90)
                    } else {
                        Picker("Kind", selection: $line.kind) { ForEach(ApprovalActionKind.allCases) { Text($0.title).tag($0) } }.labelsHidden().frame(width: 150)
                    }
                    TextField("Command pattern, e.g. git push*", text: $line.commandPattern)
                    if line.kind == .botMessage { TextField("to bot", text: Binding(get: { line.targetBot ?? "" }, set: { line.targetBot = $0.isEmpty ? nil : $0 })).frame(width: 80) }
                }
                HStack(spacing: 6) {
                    Text("→").foregroundStyle(.secondary)
                    DecisionPicker(route: $line, excluding: excluding)
                    Spacer()
                    Button { move(line.id, -1) } label: { Image(systemName: "arrow.up") }.disabled(lines.first?.id == line.id)
                    Button { move(line.id, 1) } label: { Image(systemName: "arrow.down") }.disabled(lines.last?.id == line.id)
                    Button(role: .destructive) { lines.removeAll { $0.id == line.id } } label: { Image(systemName: "trash") }
                }
            }.padding(.vertical, 3)
        }
        Button("Add line") { lines.append(ApprovalRoute(kind: .command, commandPattern: "", decision: .ask)) }
        if let otherwise {
            HStack(spacing: 6) {
                Text("Anything else").fontWeight(.medium); Text("→").foregroundStyle(.secondary)
                DecisionPicker(route: otherwise, excluding: excluding)
            }
        }
    }
    private func move(_ id: UUID, _ offset: Int) {
        guard let index = lines.firstIndex(where: { $0.id == id }), lines.indices.contains(index + offset) else { return }
        lines.swapAt(index, index + offset)
    }
}

/// Ask me | Approve | Deny | Reviewer: <bot>, as one menu.
struct DecisionPicker: View {
    @EnvironmentObject private var store: AppStore
    @Binding var route: ApprovalRoute
    let excluding: UUID?
    var body: some View {
        Picker("Then", selection: Binding(get: { Choice(route) }, set: { route.decision = $0.decision; route.reviewerID = $0.reviewer })) {
            ForEach([ApprovalDecisionKind.ask, .approve, .deny], id: \.self) { Text($0.title).tag(Choice(decision: $0, reviewer: nil)) }
            Divider()
            ForEach(store.bots.filter { !$0.isReadOnlyArchive && $0.id != excluding }) { bot in Text("Reviewer: \(bot.name)").tag(Choice(decision: .reviewer, reviewer: bot.id)) }
            if route.decision == .reviewer, route.reviewerID == nil || !store.bots.contains(where: { $0.id == route.reviewerID && $0.id != excluding }) {
                Text("Reviewer: not chosen").tag(Choice(route))
            }
        }.labelsHidden().frame(maxWidth: 200)
    }
    struct Choice: Hashable {
        var decision: ApprovalDecisionKind; var reviewer: UUID?
        init(decision: ApprovalDecisionKind, reviewer: UUID?) { self.decision = decision; self.reviewer = decision == .reviewer ? reviewer : nil }
        init(_ route: ApprovalRoute) { self.init(decision: route.decision, reviewer: route.reviewerID) }
    }
}

/// D4: `when <bot> finished <trigger> → Reviewer: <bot>`, with "send notes automatically".
struct ReviewAfterEditor: View {
    @EnvironmentObject private var store: AppStore
    @Binding var rules: [ReviewAfterRule]
    let excluding: UUID?
    var showsSubject = false
    var body: some View {
        ForEach($rules) { $rule in
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if showsSubject {
                        Picker("Bot", selection: $rule.subjectBotID) {
                            Text("Any bot").tag(nil as UUID?)
                            ForEach(store.bots.filter { !$0.isReadOnlyArchive }) { Text($0.name).tag($0.id as UUID?) }
                        }.labelsHidden().frame(width: 110)
                    }
                    Text("finished").foregroundStyle(.secondary)
                    Picker("Trigger", selection: $rule.trigger) { ForEach(ReviewTrigger.allCases) { Text($0.title).tag($0) } }.labelsHidden().frame(width: 170)
                    if rule.trigger == .botMessage { TextField("to bot", text: Binding(get: { rule.botMessageTo ?? "" }, set: { rule.botMessageTo = $0.isEmpty ? nil : $0 })).frame(width: 80) }
                }
                HStack(spacing: 6) {
                    Text("→ Reviewer").foregroundStyle(.secondary)
                    Picker("Reviewer", selection: $rule.reviewerID) {
                        Text("Choose a bot").tag(nil as UUID?)
                        ForEach(store.bots.filter { !$0.isReadOnlyArchive && $0.id != excluding }) { Text($0.name).tag($0.id as UUID?) }
                    }.labelsHidden().frame(width: 130)
                    Toggle("Send notes automatically", isOn: $rule.autoSendNotes).toggleStyle(.checkbox)
                    Spacer()
                    Button(role: .destructive) { rules.removeAll { $0.id == rule.id } } label: { Image(systemName: "trash") }
                }
            }.padding(.vertical, 3)
        }
        Button("Add review line") { rules.append(ReviewAfterRule(trigger: .codingJob, reviewerID: nil)) }
    }
}

/// Settings → Approvals (D2): lines for all bots, checked after each bot's own lines and before its "anything else".
struct SettingsApprovalsPane: View {
    @EnvironmentObject private var store: AppStore
    var body: some View {
        Section {
            Text("These lines apply to every bot, after the bot’s own lines and before its “anything else” line. First match wins. A reviewer never reviews its own requests; those go to the next line. Unsafe or destructive commands, unknown commands and reviewers that don’t answer in time always come to you.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Approvals for all bots") { ApprovalRouteEditor(lines: $store.globalApprovalRoutes, otherwise: nil, excluding: nil) }
        Section("Review after, for all bots") { ReviewAfterEditor(rules: $store.globalReviewAfter, excluding: nil, showsSubject: true) }
        Section("Bots") {
            ForEach(store.bots.filter { !$0.isReadOnlyArchive && !$0.isDemo }) { bot in
                HStack {
                    VStack(alignment: .leading, spacing: 2) { Text(bot.name); Text(summary(bot)).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Edit…") { store.editingBot = bot }
                }
            }
        }
        .onChange(of: store.globalApprovalRoutes) { store.save() }.onChange(of: store.globalReviewAfter) { store.save() }
    }
    private func summary(_ bot: Bot) -> String {
        let routing = bot.effectiveRouting
        let otherwise = routing.otherwise.label { id in store.bots.first { $0.id == id }?.name ?? "not chosen" }.replacingOccurrences(of: "Anything →", with: "anything else →")
        return (routing.lines.isEmpty ? "No lines of its own" : "\(routing.lines.count) line\(routing.lines.count == 1 ? "" : "s") of its own") + " · " + otherwise
    }
}
