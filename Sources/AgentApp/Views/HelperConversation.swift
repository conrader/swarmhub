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

struct HelperChatLine: View {
    let name: String
    let text: String
    var incoming = false
    var unavailable = false
    var media: HelperReplyMedia?

    var body: some View {
        VStack(alignment: incoming ? .leading : .trailing, spacing: 5) {
            Text(verbatim: name).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if unavailable {
                Text(HelperAssignment.unavailable).font(.callout).foregroundStyle(.secondary)
            } else if incoming {
                NativeSessionReply(text: text, media: media)
            } else {
                Text(HerdrHelperView.assignment(text)).textSelection(.enabled)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 16))
            }
        }.frame(maxWidth: .infinity, alignment: incoming ? .leading : .trailing)
    }
}

struct HelperChatComposer: View {
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
        }.frame(maxWidth: 768).padding(.horizontal, 18).padding(.vertical, 8)
            .task(id: target.id) {
                await Task.yield()
                guard !Task.isCancelled else { return }
                focused = true
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
