import SwiftUI

struct InfoPanel: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var bot: Bot

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Details").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button { store.editingBot = bot } label: { Image(systemName: "gearshape").frame(width: 24, height: 24).contentShape(Rectangle()) }.buttonStyle(.plain).help(SimpleCopy.agentSettings).accessibilityLabel(SimpleCopy.agentSettings)
                Button { store.showInfo = false } label: { Image(systemName: "xmark").frame(width: 24, height: 24).contentShape(Rectangle()) }
                    .buttonStyle(.plain).help("Close").accessibilityLabel("Close")
            }.padding(.horizontal, 14).frame(height: 54).windowDragStrip(probe: "details_header")
            Rectangle().fill(AppColor.separator).frame(height: 0.5)
            InfoTabBar(tabs: store.infoTabs(for: bot), selection: store.visibleInfoTab(for: bot)) { store.infoTab = $0 }
            Rectangle().fill(AppColor.separator).frame(height: 0.5)
            if store.visibleInfoTab(for: bot) == .overview { identity }
            ScrollView { panelContent.padding(14).frame(maxWidth: .infinity, alignment: .leading) }
        }.frame(minWidth: 300, idealWidth: 330, maxWidth: 380).background(AppColor.panel)
    }

    @ViewBuilder private var panelContent: some View {
        switch store.visibleInfoTab(for: bot) {
        case .overview: overview
        case .model: HerdrAgentControls(bot: bot).id(bot.id)
        case .skills: HerdrSkillsPanel(bot: bot)
        case .media: MediaTabView(bot: bot)
        }
    }

    private var identity: some View {
        VStack(spacing: 6) {
            BotAvatar(bot: bot, size: 72, motion: .focus, isWorking: store.isWorking(bot), probe: "overview", facing: .left).padding(.bottom, 4)
            HStack(spacing: 6) {
                Text(bot.name).font(.title2.bold()).multilineTextAlignment(.center)
                if let main = store.herdrMainBotLabel(bot) { HerdrMainBotStar(label: main, size: 14) }
            }
            if !bot.title.isEmpty, bot.title != Bot.placeholderTitle {
                Text(bot.title).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            if bot.grokSourceID != nil, PreparedGrokBundle.meaningful(bot.botDescription).isEmpty {
                Text("No specific description in Grok").font(.callout).foregroundStyle(.secondary)
                Button("Edit description") { store.editingBot = bot }.buttonStyle(.link)
            } else if !bot.botDescription.isEmpty {
                Text(verbatim: bot.botDescription).font(.callout).foregroundStyle(.secondary)
                    .lineLimit(1).padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 14).padding(.top, 20).padding(.bottom, 6)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 20) {
            let instructions = bot.outboundPersona.trimmingCharacters(in: .whitespacesAndNewlines)
            if !instructions.isEmpty, instructions != Bot.defaultPersona {
                BotInstructions(text: instructions).id(bot.id)
            }
            if bot.backend == .herdr {
                HerdrOverviewSection(bot: bot)
                HerdrTeamActivity(bot: bot)
                HerdrBotProjectsSection(bot: bot, quietWhenEmpty: true)
                HerdrHelpersSection(bot: bot)
            }
            groups
        }
    }

    /// The groups this bot is in, and a way to start one with it. (A one-to-one chat has two members, the person and
    /// the bot, which needs no list.)
    private var groups: some View {
        VStack(alignment: .leading, spacing: 10) {
            let groups = store.groups.filter { $0.memberIDs.contains(bot.id) }
            if !groups.isEmpty {
                Text("Groups").font(.headline)
                ForEach(groups) { group in Button { store.open(group) } label: { Label(group.name, systemImage: "person.3") }.buttonStyle(.plain) }
            }
            Button("New group with \(bot.name)…") { store.showingNewGroup = true }.disabled(bot.isReadOnlyArchive).padding(.top, 2)
        }
    }
}

private struct BotInstructions: View {
    let text: String
    @State private var expanded = false
    @State private var overflows = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(SimpleCopy.instructions).font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                if overflows || expanded {
                    Button(expanded ? "Show less" : "Show more") { expanded.toggle() }.buttonStyle(.link)
                }
            }
            if expanded {
                words.textSelection(.enabled)
            } else {
                words.lineLimit(3)
                    .background {
                        GeometryReader { preview in
                            words.frame(width: preview.size.width)
                                .background {
                                    GeometryReader { full in
                                        Color.clear.preference(key: InstructionsOverflow.self,
                                                               value: full.size.height > preview.size.height + 0.5)
                                    }
                                }
                                .hidden()
                        }
                    }
                    .onPreferenceChange(InstructionsOverflow.self) { [overflows = $overflows] in
                        overflows.wrappedValue = $0
                    }
            }
        }
    }

    private var words: some View {
        Text(verbatim: text).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct InstructionsOverflow: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}
