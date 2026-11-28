import SwiftUI

/// Codex can persist a protected spawn argument in place of the original message.
enum HelperAssignment {
    static let unavailable = "The original assignment is unavailable."

    static func readable(_ value: String) -> String? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("gAAAAA"), text.utf8.count >= 64,
           text.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 95, 61].contains($0) }) { return nil }
        return value
    }

    static func transcript(_ source: String) -> String {
        guard source.contains("gAAAAA") else { return source }
        return source.components(separatedBy: "\n").map { line in
            for prefix in ["Task ", "Task: ", ""] where line.hasPrefix(prefix) {
                let value = String(line.dropFirst(prefix.count))
                if value.hasPrefix("gAAAAA"), readable(value) == nil { return prefix + unavailable }
            }
            return line
        }.joined(separator: "\n")
    }
}

/// Journal IDs order the remote events. Locally sent guidance is inserted at the next dated event.
enum HelperConversationEvent: Identifiable {
    case journal(HerdrClient.Item)
    case guidance(ChatMessage)

    enum ID: Hashable { case journal(Int), guidance(UUID) }

    var id: ID {
        switch self {
        case .journal(let item): .journal(item.id)
        case .guidance(let message): .guidance(message.id)
        }
    }

    static func timeline(journal: [HerdrClient.Item], guidance: [ChatMessage]) -> [Self] {
        var events: [Self] = []
        var pending = guidance[...]
        for item in journal.sorted(by: { $0.id < $1.id }) {
            if let milliseconds = item.atMs {
                let date = Date(timeIntervalSince1970: Double(milliseconds) / 1000)
                while let next = pending.first, next.createdAt < date {
                    events.append(.guidance(next))
                    pending = pending.dropFirst()
                }
            }
            events.append(.journal(item))
        }
        return events + pending.map(Self.guidance)
    }
}

/// Guidance is saved in the parent conversation. Observe that owner even while its chat is closed.
struct HelperGuidanceHistory<Content: View>: View {
    @EnvironmentObject private var store: AppStore
    let selection: HerdrHelperSelection
    let bot: Bot
    @ViewBuilder let content: ([ChatMessage]) -> Content

    var body: some View {
        if let target = store.steeringTarget(selection, of: bot) {
            if selection.groupRuntime == nil {
                ObservedHelperInstructions(owner: bot, target: target, content: content)
            } else if let group = store.groupOwningHelper(selection, of: bot) {
                ObservedHelperInstructions(owner: group, target: target, content: content)
            } else { content([]) }
        } else { content([]) }
    }
}

private struct ObservedHelperInstructions<Owner: ObservableObject & Conversation, Content: View>: View {
    @ObservedObject var owner: Owner
    let target: HelperSteeringTarget
    let content: ([ChatMessage]) -> Content

    var body: some View { content(target.instructions(in: owner.messages)) }
}

struct HelperChatGuidance: View {
    @ObservedObject var message: ChatMessage
    let botName: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text("You via " + botName).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(HerdrHelperView.assignment(message.content)).textSelection(.enabled)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 16))
            if message.metadata[TurnWaitCopy.key] == "waiting" {
                Text("Queued in " + botName + "’s chat").font(.caption).foregroundStyle(.secondary)
            } else if let caption = SteerCopy.caption(message, botName: botName) {
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// Show enough activity to follow a helper without pushing its answer offscreen.
struct HelperChatSteps<Step, Row: View>: View {
    @Environment(\.compactWorkspaceHeight) private var compactHeight
    let steps: [Step]
    let title: String
    let model: String?
    @ViewBuilder let row: (Step) -> Row
    @State private var expanded = true
    @State private var showEarlier = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DisclosureGroup(isExpanded: $expanded) {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    if steps.isEmpty { Text("No steps yet.").foregroundStyle(.secondary) }
                    if steps.count > 3 {
                        Button(showEarlier ? "Show latest 3" : "Show earlier steps (\(steps.count - 3))") {
                            showEarlier.toggle()
                        }.buttonStyle(.borderless).font(.caption)
                    }
                    ForEach(steps.indices.suffix(showEarlier ? steps.count : 3), id: \.self) { index in
                        row(steps[index]).lineLimit(2)
                    }
                }.padding(.horizontal, 8).padding(.vertical, compactHeight ? 4 : 8).frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                HStack {
                    Text(title).font(.callout.weight(.semibold)).accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 4)
                    if let model { Text(verbatim: model).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1) }
                }
            }.padding(.horizontal, 10).padding(.vertical, 7)
        }.background(AppColor.card, in: RoundedRectangle(cornerRadius: 7))
            .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(AppColor.separator) }
            .accessibilityElement(children: .contain).accessibilityIdentifier("helper.chatSteps")
    }
}

/// The conversation shows the most recent terminal lines. The full output stays available in Details.
struct HelperChatTerminal: View {
    var command: String? = nil
    let output: String
    @State private var expanded = true

    nonisolated static func excerpt(_ output: String) -> String {
        let lines = output.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard let last = lines.lastIndex(where: { !$0.allSatisfy(\.isWhitespace) }) else { return "" }
        return HelperAssignment.transcript(lines[...last].suffix(5).joined(separator: "\n"))
    }

    var body: some View {
        let excerpt = Self.excerpt(output)
        if !excerpt.isEmpty || command?.isEmpty == false {
            DisclosureGroup("Terminal output", isExpanded: $expanded) {
                ScrollView(.horizontal) {
                    VStack(alignment: .leading, spacing: 3) {
                        if let command, !command.isEmpty { Text(verbatim: "$ " + command).lineLimit(2).foregroundStyle(.secondary) }
                        if !excerpt.isEmpty { Text(verbatim: excerpt) }
                    }.font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: true)
                }.padding(.top, 3)
            }.font(.callout).padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppColor.sidebar, in: RoundedRectangle(cornerRadius: 6))
                .accessibilityIdentifier("helper.chatTerminal")
        }
    }
}

struct HelperChatReply: View {
    var title = "Latest reply"
    var text: String?
    var placeholder = "No reply yet."
    var media: HelperReplyMedia?
    var command: String?
    var output: String?

    var body: some View {
        let hasOutput = command?.isEmpty == false || !HelperChatTerminal.excerpt(output ?? "").isEmpty
        helperPart(title, detail: hasOutput ? "Terminal output below" : nil) {
            if let text, !text.isEmpty { NativeSessionReply(text: text, media: media) }
            else { Text(placeholder).foregroundStyle(.secondary) }
            if hasOutput { HelperChatTerminal(command: command, output: output ?? "") }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("helper.chatReply")
    }
}

/// Keep steering in reach while leaving the transcript the height of a single toolbar when it fits.
struct CompactHelperFooter<Actions: View, Composer: View>: View {
    @ViewBuilder let actions: Actions
    @ViewBuilder let composer: Composer

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                actions.fixedSize(horizontal: true, vertical: false)
                composer.frame(minWidth: 200)
            }
            VStack(alignment: .leading, spacing: 4) { actions; composer }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 4)
    }
}

struct HelperChatComposer: View {
    @Environment(\.compactWorkspaceHeight) private var compactHeight
    @EnvironmentObject private var store: AppStore
    let target: HelperSteeringTarget
    let bot: Bot
    @State private var text: String
    @State private var error = false
    @FocusState private var focused: Bool

    init(target: HelperSteeringTarget, bot: Bot, draft: String) {
        self.target = target
        self.bot = bot
        _text = State(initialValue: draft)
    }

    var body: some View {
        VStack(alignment: .leading) {
            if error { Text("This helper could not receive the message. Your draft is still here.").font(.caption) }
            HStack {
                TextEditor(text: $text)
                    .font(.body).focused($focused).scrollContentBackground(.hidden)
                    .frame(height: min(100, 26 + CGFloat(text.filter { $0.isNewline }.count) * 18))
                    .accessibilityLabel("Message " + target.name)
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text("Message " + target.name + " via " + bot.name + "…")
                                .foregroundStyle(.tertiary).padding(.leading, 5).allowsHitTesting(false)
                        }
                    }
                    .onKeyPress(.return, phases: .down) { press in
                        guard !press.modifiers.contains(.shift) else { return .ignored }
                        send(); return .handled
                    }
                Button(action: send) { Image(systemName: "arrow.up") }
                    .buttonStyle(ComposerRoundButtonStyle(prominent: true))
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Send to " + target.name)
            }.padding(10).background(AppColor.card, in: RoundedRectangle(cornerRadius: 16))
        }.frame(maxWidth: 768).padding(.horizontal, compactHeight ? 0 : 18).padding(.vertical, compactHeight ? 0 : 8)
            .onChange(of: store.helperComposerFocus == target.id, initial: true) { _, requested in
                if requested { focused = true }
            }
            .task(id: store.helperComposerFocus == target.id) {
                await Task.yield()
                guard !Task.isCancelled else { return }
                guard store.openHerdrHelper == target.selection else { return }
                focused = true
                if store.helperComposerFocus == target.id { store.helperComposerFocus = nil }
            }
            .onChange(of: text) { _, value in
                store.helperChatDrafts[target.id] = value.isEmpty ? nil : value
            }
    }

    private func send() {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        error = !store.sendHelperMessage(text, to: target, of: bot)
        if !error { text = ""; store.helperChatDrafts[target.id] = nil }
    }
}
