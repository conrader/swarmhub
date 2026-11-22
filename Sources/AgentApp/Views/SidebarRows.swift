import SwiftUI

/// P20 sidebar geometry, after Grok Bot's left column (values in points).
enum SidebarMetrics {
    static let rowHeight: CGFloat = 58, mark: CGFloat = 36, rowPadding: CGFloat = 12, markGap: CGFloat = 12
    /// The selected row's highlight sits this far in from the column edges.
    static let listInset: CGFloat = 12
    static let selectionRadius: CGFloat = 10, nameSize: CGFloat = 15, fragmentSize: CGFloat = 14, badge: CGFloat = 12
    /// How strongly the open chat's row is washed with the accent.
    static let selectionWash = 0.22
    /// The top row holds the 32 pt round search and + buttons; it is taller than the 28 pt title zone it covers.
    static let topRow: CGFloat = 32, roundButton: CGFloat = 32, bottomBar: CGFloat = 56
    /// Pinned strip: big marks, three to a line, the name under each. The tile's top inset leaves room for the mark's
    /// canvas, which is drawn larger than the mark and raised.
    static let pinnedMark: CGFloat = 56, pinnedColumns = 3, pinnedNameSize: CGFloat = 12, maxPinned = 9, pinnedTopInset: CGFloat = 20
    static let sectionHeader: CGFloat = 32
    static let width: (min: CGFloat, ideal: CGFloat, max: CGFloat) = (240, 280, 320)
    /// Settings → Your name (simple page); its first letter is the bottom round button.
    static let accountNameKey = "accountName"
    static func initial(of name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).first.map { String($0).uppercased() } ?? "K"
    }
}

/// Name over a one-line grey fragment, both truncated with "…"; unread makes the name semibold. `main` (a Herdr
/// server's main bot, "Main bot of This Mac") puts a small star right after the name.
private struct RowText: View {
    let name: String; let fragment: String; let unread: Bool
    var main: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Text(name).font(.system(size: SidebarMetrics.nameSize, weight: unread ? .semibold : .medium)).foregroundStyle(.primary)
                    .lineLimit(1).truncationMode(.tail)
                if let main { HerdrMainBotStar(label: main) }
            }
            // A blank fragment still takes its line, so every row is the same height.
            Text(fragment.isEmpty ? " " : fragment).font(.system(size: SidebarMetrics.fragmentSize)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.tail)
        }
    }
}

struct RowChrome: ViewModifier {
    let selected: Bool; let hovering: Bool
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: SidebarMetrics.selectionRadius)
        content.padding(.horizontal, SidebarMetrics.rowPadding).frame(height: SidebarMetrics.rowHeight).contentShape(shape)
            .background(selected ? AnyShapeStyle(TintShapeStyle().opacity(SidebarMetrics.selectionWash)) : hovering ? AnyShapeStyle(AppColor.selection.opacity(0.6)) : AnyShapeStyle(.clear), in: shape)
            // The open chat is washed with the accent and marked at its leading edge: the grey it had could hardly
            // be told from the row under the pointer.
            .overlay(alignment: .leading) { if selected { Capsule().fill(.tint).frame(width: 3, height: SidebarMetrics.rowHeight - 30).padding(.leading, 3.5).accessibilityHidden(true) } }
    }
}

private struct UnreadDot: View {
    var body: some View { Circle().fill(.tint).frame(width: 8, height: 8) }
}

/// A bot in the sidebar: its 36 pt mark (with a badge when it needs attention), name, latest-message line and context actions.
struct BotRow: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.activityNow) private var fixedNow
    @ObservedObject var bot: Bot; @ObservedObject var drafts: ComposerDrafts
    let selected: Bool; @Binding var botToDelete: Bot?
    var askNewSection: (UUID?) -> Void = { _ in }
    @State private var hovering = false
    var body: some View {
        let working = store.isWorking(bot), attention = store.needsAttention(bot)
        // Sample bots say so instead of showing their canned last message.
        let fragment = { (now: Date) in
            // An agent that waits at a question says so, whatever its last message was.
            bot.isDemo ? SimpleCopy.sampleLabel : !working && store.herdrPrompts[bot.id] != nil ? HerdrPrompt.sidebar : SidebarFragment.text(messages: bot.messages, draft: drafts.texts[bot.id], isWorking: working,
                                                                       archiveNewest: store.grokHistory.newestVisible(for: bot.id), working: store.workingLine(for: bot, now: now))
        }
        Button { store.open(bot) } label: {
            HStack(spacing: SidebarMetrics.markGap) {
                BotAvatar(bot: bot, size: SidebarMetrics.mark, motion: .list, isWorking: working, isHovered: hovering, probe: "sidebar")
                    .overlay(alignment: .bottomTrailing) {
                        if attention {
                            Circle().fill(AppColor.clay).frame(width: SidebarMetrics.badge, height: SidebarMetrics.badge)
                                .overlay(Circle().stroke(selected ? AppColor.selection : AppColor.sidebar, lineWidth: 2))
                                .offset(x: 2, y: 2).accessibilityLabel("Needs attention")
                        }
                    }
                // Re-read the phase during a pause in text, even when no stream event arrives.
                if working {
                    TimelineView(.periodic(from: .now, by: 1)) { context in RowText(name: bot.name, fragment: fragment(fixedNow ?? context.date), unread: bot.isUnread, main: store.herdrMainBotLabel(bot)) }
                } else {
                    RowText(name: bot.name, fragment: fragment(fixedNow ?? .now), unread: bot.isUnread, main: store.herdrMainBotLabel(bot))
                }
                Spacer(minLength: 4)
                if bot.isUnread { UnreadDot() }
            }.modifier(RowChrome(selected: selected, hovering: hovering)).onHover { hovering = $0 }
        }.buttonStyle(.plain).contextMenu {
            SidebarChatMenu(chat: .bot(bot), askNewSection: askNewSection) { botToDelete = bot }
        }
    }
}

/// A group in the sidebar: its member cluster (no badge), name, "<Member>: …" line and the same context actions as a bot.
struct GroupRow: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.activityNow) private var fixedNow
    @ObservedObject var group: GroupChat; @ObservedObject var drafts: ComposerDrafts; @Binding var botToDelete: GroupChat?
    var askNewSection: (UUID?) -> Void = { _ in }
    @State private var hovering = false
    var body: some View {
        let selected = store.selectedGroup?.id == group.id
        let working = store.isStreaming(in: group)
        let fragment = { (now: Date) in SidebarFragment.text(messages: group.messages, draft: drafts.texts[group.id],
                                            isWorking: working,
                                            archiveNewest: store.grokHistory.newestVisible(for: group.id),
                                            author: { id in id.flatMap { id in store.bots.first { $0.id == id }?.name } },
                                            working: store.workingLine(for: group, now: now)) }
        Button { store.open(group) } label: {
            HStack(spacing: SidebarMetrics.markGap) {
                GroupAvatarStack(group: group, members: store.members(of: group), size: SidebarMetrics.mark, isHovered: hovering,
                                 halo: selected ? AppColor.selection : AppColor.sidebar, probe: "group:\(group.id)")
                if working {
                    TimelineView(.periodic(from: .now, by: 1)) { context in RowText(name: group.name, fragment: fragment(fixedNow ?? context.date), unread: group.isUnread) }
                } else {
                    RowText(name: group.name, fragment: fragment(fixedNow ?? .now), unread: group.isUnread)
                }
                Spacer(minLength: 4)
                if group.isMuted { Image(systemName: "bell.slash").font(.system(size: 10)).foregroundStyle(.tertiary) }
                if group.isUnread { UnreadDot() }
            }.modifier(RowChrome(selected: selected, hovering: hovering)).onHover { hovering = $0 }
        }.buttonStyle(.plain).contextMenu {
            SidebarChatMenu(chat: .group(group), askNewSection: askNewSection) { botToDelete = group }
        }
    }
}

/// A 32 pt round button with a subtle filled circle (top row search and +, bottom user initial).
struct RoundSidebarLabel: View {
    let symbol: String?; var text: String? = nil
    var body: some View {
        Group {
            if let text { Text(text).font(.system(size: 14, weight: .semibold)) } else if let symbol { Image(systemName: symbol).font(.system(size: 13, weight: .semibold)) }
        }.frame(width: SidebarMetrics.roundButton, height: SidebarMetrics.roundButton)
            .background(Circle().fill(Color.primary.opacity(0.08))).contentShape(Circle())
    }
}
