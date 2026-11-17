import SwiftUI

/// The agent panel's tab bar: each tab is an SF Symbol
/// over a short caption (`.symbolCaption`); `.symbolOnly` is kept for the render that compares the two.
extension AgentInfoTab {
    var symbol: String {
        switch self {
        case .overview: "info.circle"
        case .model: "cpu"
        case .skills: "puzzlepiece.extension"
        case .media: "photo.on.rectangle"
        }
    }
    /// The caption under the symbol; the full name is the tab's help and accessibility label.
    var caption: String { rawValue }
}

extension AppStore {
    /// The tabs this agent shows: a Herdr agent has Overview, its Model tab, its server's skill library and Media; a
    /// sample agent has no model or skills to show.
    func infoTabs(for bot: Bot) -> [AgentInfoTab] { bot.backend == .herdr ? [.overview, .model, .skills, .media] : [.overview, .media] }

    /// The tab the panel shows: the chosen one when this agent has it, else Overview (`infoTab` itself is left alone so
    /// the choice comes back on an agent that has the tab).
    func visibleInfoTab(for bot: Bot) -> AgentInfoTab { infoTabs(for: bot).contains(infoTab) ? infoTab : .overview }

    /// Opens the panel on `tab`.
    func openInfoTab(_ tab: AgentInfoTab) { infoTab = tab; showInfo = true }
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
            .background(selected ? AnyShapeStyle(TintShapeStyle().opacity(0.14)) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain).foregroundStyle(selected ? AnyShapeStyle(TintShapeStyle()) : AnyShapeStyle(.secondary))
        .help(tab.rawValue).accessibilityLabel(tab.rawValue).accessibilityAddTraits(selected ? .isSelected : [])
    }
}
