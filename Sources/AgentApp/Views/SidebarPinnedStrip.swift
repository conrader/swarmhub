import SwiftUI

/// The pinned chats, first in the list's stack so they scroll with it: three to a line, each a big mark with its name under it.
struct SidebarPinnedStrip: View {
    let chats: [SidebarChat]
    let askNewSection: (UUID?) -> Void
    let requestDelete: (SidebarChat) -> Void

    static let layout = TileRows(minimum: SidebarMetrics.pinnedMark + 8, centeredColumns: SidebarMetrics.pinnedColumns, spacing: 4)

    var body: some View {
        Self.layout {
            ForEach(chats) { chat in
                switch chat {
                case .bot(let bot): PinnedBotTile(bot: bot, askNewSection: askNewSection) { requestDelete(chat) }
                case .group(let group): PinnedGroupTile(group: group, askNewSection: askNewSection) { requestDelete(chat) }
                }
            }
        }.padding(.bottom, 6)
    }
}

/// The frame every tile shares: the mark with free space above it (a mark draws past its own box), the name under it,
/// the same selection wash as a row, and an unread dot.
private struct PinnedTileFrame<Avatar: View>: View {
    let name: String; let unread: Bool; let selected: Bool; let hovering: Bool
    @ViewBuilder let avatar: () -> Avatar

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: SidebarMetrics.selectionRadius)
        VStack(spacing: 6) {
            avatar().frame(width: SidebarMetrics.pinnedMark, height: SidebarMetrics.pinnedMark)
                .overlay(alignment: .topTrailing) { if unread { Circle().fill(.tint).frame(width: 8, height: 8).accessibilityHidden(true) } }
            Text(name).font(.system(size: SidebarMetrics.pinnedNameSize, weight: unread ? .semibold : .medium)).foregroundStyle(.primary)
                .lineLimit(1).truncationMode(.tail).multilineTextAlignment(.center).help(name)
        }.padding(.top, SidebarMetrics.pinnedTopInset).padding(.bottom, 6).padding(.horizontal, 4).frame(maxWidth: .infinity)
            .contentShape(shape)
            .background(selected ? AnyShapeStyle(TintShapeStyle().opacity(SidebarMetrics.selectionWash)) : hovering ? AnyShapeStyle(AppColor.selection.opacity(0.6)) : AnyShapeStyle(.clear), in: shape)
    }
}

private struct PinnedBotTile: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var bot: Bot
    let askNewSection: (UUID?) -> Void
    let requestDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        let selected = !store.showOnlyAttention && store.selectedBot?.id == bot.id && store.selectedGroup == nil && store.openHerdrHelper?.botID != bot.id
        let terminal = store.herdrTerminalSession(for: bot)
        let coding = store.hasActiveCodingAgent(bot), attention = store.needsAttention(bot)
        let main = store.herdrMainBotLabel(bot)
        Button { store.openAndFocusComposer(.bot(bot)) } label: {
            PinnedTileFrame(name: bot.name, unread: bot.isUnread, selected: selected, hovering: hovering) {
                BotAvatar(bot: bot, size: SidebarMetrics.pinnedMark, motion: .list, isWorking: store.isAnswering(bot), isHovered: hovering,
                          probe: "sidebar", hasActiveCodingAgent: coding, showsCodingBadge: terminal == nil, mainBotLabel: main)
                    .overlay(alignment: .bottomTrailing) {
                        if attention {
                            Circle().fill(AppColor.clay).frame(width: SidebarMetrics.badge, height: SidebarMetrics.badge)
                                .overlay(Circle().stroke(selected ? AppColor.selection : AppColor.sidebar, lineWidth: 2))
                                .offset(x: 2, y: 2).accessibilityLabel("Needs attention")
                        }
                    }
            }.onHover { hovering = $0 }
        }.buttonStyle(.plain)
            .accessibilityLabel([bot.name, "pinned", main, coding ? "coding agent active" : nil].compactMap { $0 }.joined(separator: ", "))
            .accessibilityValue(bot.isUnread ? "Unread" : "")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .contextMenu { SidebarChatMenu(chat: .bot(bot), askNewSection: askNewSection, requestDelete: requestDelete) }
            .overlay(alignment: .top) {
                if let terminal {
                    SidebarTerminalButton(bot: bot, target: LiveTerminal(agent: terminal, title: bot.name), avatarSize: SidebarMetrics.pinnedMark)
                        .frame(width: SidebarMetrics.pinnedMark, height: SidebarMetrics.pinnedMark, alignment: .bottomLeading)
                        .padding(.top, SidebarMetrics.pinnedTopInset)
                }
            }
    }
}

private struct PinnedGroupTile: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var group: GroupChat
    let askNewSection: (UUID?) -> Void
    let requestDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        let selected = !store.showOnlyAttention && store.selectedGroup?.id == group.id
        Button { store.openAndFocusComposer(.group(group)) } label: {
            PinnedTileFrame(name: group.name, unread: group.isUnread, selected: selected, hovering: hovering) {
                GroupAvatarStack(group: group, members: store.members(of: group), size: SidebarMetrics.pinnedMark, isHovered: hovering,
                                 halo: selected ? AppColor.selection : AppColor.sidebar, probe: "group:\(group.id)")
            }.onHover { hovering = $0 }
        }.buttonStyle(.plain)
            .accessibilityValue(group.isUnread ? "Unread" : "")
            .accessibilityLabel("\(group.name), pinned").accessibilityAddTraits(selected ? .isSelected : [])
            .contextMenu { SidebarChatMenu(chat: .group(group), askNewSection: askNewSection, requestDelete: requestDelete) }
    }
}
