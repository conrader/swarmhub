import SwiftUI

/// P33: the agent panel's tab bar. Seven text labels do not fit the panel's 300 pt minimum, so each tab is an SF Symbol
/// over a short caption (`.symbolCaption`); `.symbolOnly` is kept for the render that compares the two.
extension AgentInfoTab {
    var symbol: String {
        switch self {
        case .overview: "info.circle"
        case .model: "cpu"
        case .skills: "puzzlepiece.extension"
        case .activity: "checklist"
        case .routines: "clock"
        case .media: "photo.on.rectangle"
        case .computer: "desktopcomputer"
        }
    }
    /// The caption under the symbol; the full name is the tab's help and accessibility label.
    var caption: String { rawValue }
}

/// A one-line "needs attention" status on Overview that switches to the tab holding the details.
struct InfoPointer: Equatable, Identifiable {
    let text: String
    let tab: AgentInfoTab
    var id: String { text }
}

extension AppStore {
    /// The tabs this agent shows. Hermes (and other) agents show all seven; an OpenClaw agent only the ones with content
    /// for it: Model unless it is a read-only archive, Skills when it carries imported skills, Activity when it has an
    /// approval audit, Routines when it has local routines (its automations live on the Gateway).
    func infoTabs(for bot: Bot) -> [AgentInfoTab] {
        guard bot.backend == .openClaw else { return AgentInfoTab.allCases }
        return AgentInfoTab.allCases.filter { tab in
            switch tab {
            case .overview, .media, .computer: true
            case .model: !bot.isReadOnlyArchive
            case .skills: !importedSkills(for: bot).isEmpty || !bot.skills.isEmpty
            case .activity: !bot.approvalAudit.isEmpty || !threadSummaries(for: bot).isEmpty
            case .routines: !bot.routines.isEmpty
            }
        }
    }

    /// The tab the panel shows: the chosen one when this agent has it, else Overview (`infoTab` itself is left alone so
    /// the choice comes back on an agent that has the tab).
    func visibleInfoTab(for bot: Bot) -> AgentInfoTab { infoTabs(for: bot).contains(infoTab) ? infoTab : .overview }

    /// Opens the panel on `tab`.
    func openInfoTab(_ tab: AgentInfoTab) { infoTab = tab; showInfo = true }

    /// Overview's pointers, in tab order: SwarmHub skills to install or update (the banner's rule, ignoring "Not now"),
    /// approvals waiting, and a chat model that differs from the bot's Conversation role.
    func infoPointers(for bot: Bot) -> [InfoPointer] {
        var pointers: [InfoPointer] = []
        if let mismatch = modelRolesRow(for: bot).mismatch, !mismatch.isEmpty {
            pointers.append(InfoPointer(text: "Model differs from this bot's role", tab: .model))
        }
        let manages = isManager(bot)
        if manages || manager(for: bot) != nil {
            let states = skills(for: bot).map { skillState($0, for: bot) }.filter { $0.needsAction && (manages || $0 != .missing) }
            if states.contains(where: { $0 != .missing }) { pointers.append(InfoPointer(text: "SwarmHub skills: update available", tab: .skills)) }
            else if !states.isEmpty { pointers.append(InfoPointer(text: "SwarmHub skills: not installed", tab: .skills)) }
        }
        let waiting = approvals.filter { $0.botID == bot.id }.count
        if waiting > 0 { pointers.append(InfoPointer(text: waiting == 1 ? "1 approval waiting" : "\(waiting) approvals waiting", tab: .activity)) }
        return pointers.filter { infoTabs(for: bot).contains($0.tab) }
    }
}

struct InfoTabBar: View {
    enum Style { case symbolCaption, symbolOnly }
    let tabs: [AgentInfoTab]
    let selection: AgentInfoTab
    var style = Style.symbolCaption
    let select: (AgentInfoTab) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(tabs.enumerated()), id: \.element) { index, tab in
                if index > 0 { Spacer(minLength: 2) }
                item(tab)
            }
        }.padding(.horizontal, 8).padding(.vertical, 6)
    }

    private func item(_ tab: AgentInfoTab) -> some View {
        let selected = tab == selection
        return Button { select(tab) } label: {
            VStack(spacing: 2) {
                Image(systemName: tab.symbol).font(.system(size: style == .symbolOnly ? 14 : 13)).frame(height: 17)
                if style == .symbolCaption { Text(tab.caption).font(.system(size: 9, weight: selected ? .semibold : .regular)).lineLimit(1).fixedSize() }
            }
            .padding(.horizontal, style == .symbolOnly ? 8 : 2).frame(height: style == .symbolOnly ? 28 : 36)
            .contentShape(Rectangle())
            .background(selected ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain).foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        .help(tab.rawValue).accessibilityLabel(tab.rawValue).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Overview's one-line pointers to tabs that need attention.
struct InfoPointerRows: View {
    @EnvironmentObject private var store: AppStore
    let pointers: [InfoPointer]
    var body: some View {
        if !pointers.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(pointers) { pointer in
                    Button { store.openInfoTab(pointer.tab) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                            Text(pointer.text); Spacer(minLength: 4); Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }.font(.caption).contentShape(Rectangle())
                    }.buttonStyle(.plain).help("Open \(pointer.tab.rawValue)")
                }
            }
        }
    }
}
