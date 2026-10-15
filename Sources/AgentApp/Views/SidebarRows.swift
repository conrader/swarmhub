import SwiftUI

/// P20 sidebar geometry, after Grok Bot's left column (values in points).
enum SidebarMetrics {
    static let rowHeight: CGFloat = 58, mark: CGFloat = 36, rowPadding: CGFloat = 12, markGap: CGFloat = 12
    /// The selected row's highlight sits this far in from the column edges.
    static let listInset: CGFloat = 12
    static let selectionRadius: CGFloat = 10, nameSize: CGFloat = 15, fragmentSize: CGFloat = 14, badge: CGFloat = 12
    /// The top row holds the 32 pt round search and + buttons; it is taller than the 28 pt title zone it covers.
    static let topRow: CGFloat = 32, roundButton: CGFloat = 32, bottomBar: CGFloat = 56
    static let width: (min: CGFloat, ideal: CGFloat, max: CGFloat) = (240, 280, 320)
    /// Settings → Your name (simple page); its first letter is the bottom round button.
    static let accountNameKey = "accountName"
    static func initial(of name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).first.map { String($0).uppercased() } ?? "K"
    }
}

/// Name over a one-line grey fragment, both truncated with "…"; unread makes the name semibold.
private struct RowText: View {
    let name: String; let fragment: String; let unread: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).font(.system(size: SidebarMetrics.nameSize, weight: unread ? .semibold : .medium)).foregroundStyle(.primary)
                .lineLimit(1).truncationMode(.tail)
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
            .background(selected ? AppColor.selection : hovering ? AppColor.selection.opacity(0.45) : .clear, in: shape)
    }
}

private struct UnreadDot: View {
    var body: some View { Circle().fill(.primary.opacity(0.72)).frame(width: 8, height: 8) }
}

/// A bot in the sidebar: its 36 pt mark (with a badge when it needs attention), name, latest-message line and context actions.
struct BotRow: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var bot: Bot; @ObservedObject var drafts: ComposerDrafts
    let selected: Bool; @Binding var botToDelete: Bot?
    @State private var hovering = false
    var body: some View {
        let working = store.isWorking(bot), attention = store.needsAttention(bot)
        // P21 D3: sample bots say so instead of showing their canned last message.
        let fragment = { (now: Date) in
            bot.isDemo ? SimpleCopy.sampleLabel : SidebarFragment.text(messages: bot.messages, draft: drafts.texts[bot.id], isWorking: working,
                                                                       archiveNewest: store.grokHistory.newestVisible(for: bot.id), working: store.workingLine(for: bot, now: now))
        }
        Button { store.open(bot) } label: {
            HStack(spacing: SidebarMetrics.markGap) {
                BotAvatar(bot: bot, size: SidebarMetrics.mark, motion: .list, isWorking: working, isHovered: hovering, probe: "sidebar",
                          isWaiting: store.hasPendingApproval(bot))
                    .overlay(alignment: .bottomTrailing) {
                        if attention {
                            Circle().fill(Color.orange).frame(width: SidebarMetrics.badge, height: SidebarMetrics.badge)
                                .overlay(Circle().stroke(selected ? AppColor.selection : AppColor.sidebar, lineWidth: 2))
                                .offset(x: 2, y: 2).accessibilityLabel("Needs attention")
                        }
                    }
                // Re-read the phase during a pause in text, even when no stream event arrives.
                if working {
                    TimelineView(.periodic(from: .now, by: 1)) { context in RowText(name: bot.name, fragment: fragment(context.date), unread: bot.isUnread) }
                } else {
                    RowText(name: bot.name, fragment: fragment(.now), unread: bot.isUnread)
                }
                Spacer(minLength: 4)
                if bot.retiredOnBox { Text("retired").font(.system(size: 10)).foregroundStyle(.tertiary) }
                // P34 D6: a bot message arrived that is not opened yet.
                if store.hasBotMessageBadge(bot) {
                    Image(systemName: "bubble.left.and.bubble.right.fill").font(.system(size: 8, weight: .semibold)).foregroundStyle(.white)
                        .padding(4).background(Color.accentColor, in: Circle()).help("A bot wrote to \(bot.name)").accessibilityLabel("New bot message")
                }
                if bot.isUnread { UnreadDot() }
            }.modifier(RowChrome(selected: selected, hovering: hovering)).onHover { hovering = $0 }
        }.buttonStyle(.plain).contextMenu {
            Button("Edit", systemImage: "pencil") { store.editingBot = bot }
            if !bot.isUnread { Button("Mark as Unread", systemImage: "circle.fill") { store.markUnread(bot) } }
            Button(bot.isHidden ? "Show in Sidebar" : "Hide from Sidebar", systemImage: bot.isHidden ? "eye" : "eye.slash") { store.setHidden(bot, !bot.isHidden) }
            Button(bot.notificationsEnabled ? "Mute Notifications" : "Enable Notifications", systemImage: bot.notificationsEnabled ? "bell.slash" : "bell") { bot.notificationsEnabled.toggle(); store.save() }
            Divider(); Button("Delete", systemImage: "trash", role: .destructive) { botToDelete = bot }
        }
    }
}

/// A group in the sidebar: its member cluster (no badge), name, "<Member>: …" line and the same context actions as a bot.
struct GroupRow: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var group: GroupChat; @ObservedObject var drafts: ComposerDrafts; @Binding var botToDelete: GroupChat?
    @State private var hovering = false
    var body: some View {
        let selected = store.selectedGroup?.id == group.id
        let working = store.isStreaming && store.streamingConversation === group
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
                    TimelineView(.periodic(from: .now, by: 1)) { context in RowText(name: group.name, fragment: fragment(context.date), unread: group.isUnread) }
                } else {
                    RowText(name: group.name, fragment: fragment(.now), unread: group.isUnread)
                }
                Spacer(minLength: 4)
                if group.isMuted { Image(systemName: "bell.slash").font(.system(size: 10)).foregroundStyle(.tertiary) }
                if group.isUnread { UnreadDot() }
            }.modifier(RowChrome(selected: selected, hovering: hovering)).onHover { hovering = $0 }
        }.buttonStyle(.plain).contextMenu {
            if !group.isUnread { Button("Mark as Unread", systemImage: "circle.fill") { store.markUnread(group) } }
            Button(group.isHidden ? "Show in Sidebar" : "Hide from Sidebar", systemImage: group.isHidden ? "eye" : "eye.slash") { store.setHidden(group, !group.isHidden) }
            Button(group.isMuted ? "Enable Notifications" : "Mute Notifications", systemImage: group.isMuted ? "bell" : "bell.slash") { group.isMuted.toggle(); store.save() }
            Divider(); Button("Delete Group", systemImage: "trash", role: .destructive) { botToDelete = group }
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
