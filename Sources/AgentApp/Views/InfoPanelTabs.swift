import SwiftUI

extension AgentInfoTab {
    var symbol: String {
        switch self {
        case .approvals: "checkmark.shield"
        case .overview: "info.circle"
        case .team: "person.2"
        case .model: "cpu"
        case .routines: "clock.arrow.2.circlepath"
        case .skills: "puzzlepiece.extension"
        case .media: "photo.on.rectangle"
        }
    }

}

extension AppStore {
    func infoTabs(for bot: Bot) -> [AgentInfoTab] {
        if bot.sampleProfile != nil { return [.overview, .approvals, .routines, .media] }
        return bot.backend == .herdr ? AgentInfoTab.allCases : [.overview, .media]
    }

    /// The tab the panel shows: the chosen one when this agent has it, else Overview (`infoTab` itself is left alone so
    /// the choice comes back on an agent that has the tab).
    func visibleInfoTab(for bot: Bot) -> AgentInfoTab { infoTabs(for: bot).contains(infoTab) ? infoTab : .overview }

    /// Opens the panel on `tab`.
    func openInfoTab(_ tab: AgentInfoTab) { inspectorTerminal = nil; infoTab = tab; showInfo = true }
}

struct InfoTabBar: View {
    let tabs: [AgentInfoTab]
    let selection: AgentInfoTab
    let select: (AgentInfoTab) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs.prefix(3), id: \.self) { tab in
                let selected = selection == tab
                Button { select(tab) } label: {
                    Text(tab.rawValue).font(.system(size: 12, weight: selected ? .semibold : .medium))
                        .lineLimit(1).frame(maxWidth: .infinity).padding(.vertical, 5)
                        .foregroundStyle(selected ? .primary : .secondary)
                        .background {
                            if selected { RoundedRectangle(cornerRadius: 4).fill(AppColor.raised) }
                        }
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel(tab.rawValue).accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2).background(AppColor.selection, in: RoundedRectangle(cornerRadius: 6))
        .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(AppColor.separator) }
        .padding(.horizontal, 11).padding(.vertical, 6)
    }
}

struct MoreInfoSections: View {
    let tabs: [AgentInfoTab]
    let selection: AgentInfoTab
    let select: (AgentInfoTab) -> Void
    @State private var open = false

    var body: some View {
        if !tabs.isEmpty {
            Button { open.toggle() } label: {
                HStack(spacing: 3) {
                    Text(tabs.contains(selection) ? selection.rawValue : "More")
                    Image(systemName: "chevron.down").font(.caption2)
                }.lineLimit(1)
            }
            .controlSize(.small).fixedSize()
            .help("Model, team, skills and media")
            .accessibilityLabel("More Details sections")
            .accessibilityValue(tabs.contains(selection) ? selection.rawValue : "")
            .popover(isPresented: $open, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(tabs, id: \.self) { tab in
                        Button {
                            open = false
                            select(tab)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: tab.symbol).frame(width: 16)
                                Text(tab.rawValue)
                                Spacer()
                                if tab == selection { Image(systemName: "checkmark") }
                            }.padding(6).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityAddTraits(tab == selection ? .isSelected : [])
                    }
                }.padding(6).frame(width: 148)
            }
        }
    }
}
