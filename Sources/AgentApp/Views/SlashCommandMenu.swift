import SwiftUI

/// P45 1: the list over the composer while the draft is a single `/word`: filtered as you type, ↑↓ move, Enter or a click
/// picks, Esc closes (`ComposerView` owns the keys).
struct SlashCommandMenu: View {
    let commands: [SlashCommand]; let selected: Int; let pick: (SlashCommand) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(commands.enumerated()), id: \.element) { index, command in
                Button { pick(command) } label: {
                    HStack(spacing: 8) {
                        Text(command.name).font(.system(size: 12, weight: .semibold, design: .monospaced))
                        if !command.usage.isEmpty { Text(command.usage).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1) }
                        Spacer(minLength: 12)
                        Text(command.summary).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }.padding(.horizontal, 8).frame(maxWidth: .infinity, minHeight: 26, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).background(index == selected ? AppColor.selection : .clear, in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityIdentifier("slash.\(command.rawValue)")
            }
            if commands.isEmpty { Text("No command matches — Send posts it as a message").font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 8).frame(minHeight: 24) }
        }.padding(4).background(AppColor.card, in: RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).stroke(AppColor.separator, lineWidth: 0.5))
            .frame(maxWidth: 560)
    }
}

/// The menu's keyboard state, kept apart from the view so the keys are testable.
struct SlashMenuState: Equatable {
    var selected = 0
    /// The draft Esc closed the menu at; typing on reopens it.
    var dismissedAt: String?

    func matches(for text: String, commands: [SlashCommand]) -> [SlashCommand] {
        guard !commands.isEmpty, dismissedAt != text else { return [] }
        return SlashMenu.matches(for: text, commands: commands) ?? []
    }
    func isOpen(for text: String, commands: [SlashCommand]) -> Bool {
        !commands.isEmpty && dismissedAt != text && SlashMenu.query(in: text) != nil
    }
    mutating func move(_ delta: Int, count: Int) {
        guard count > 0 else { selected = 0; return }
        selected = ((selected + delta) % count + count) % count
    }
    /// The highlighted command (clamped: the list shrinks as you type).
    func current(in matches: [SlashCommand]) -> SlashCommand? { matches.isEmpty ? nil : matches[min(selected, matches.count - 1)] }
}
