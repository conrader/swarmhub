import SwiftUI

struct InfoPanel: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var bot: Bot
    @Environment(\.workspaceApprovals) private var inboxes
    var modelPreset: HerdrAgentControls.Preset? = nil
    var skillsPreset: HerdrSkillsModel? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Details").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                if bot.backend == .herdr {
                    Button("Terminal", systemImage: "terminal") {
                        let target: LiveTerminal?
                        if let helper = store.openHerdrHelper, helper.botID == bot.id,
                           let list = store.herdrHelpers[helper.parent],
                           let child = list.helpers.first(where: { $0.id == helper.helperID }) {
                            target = LiveTerminal(agent: child.ref, title: child.name, core: list.core)
                        } else if store.openHerdrHelper == nil, let ref = store.herdrTerminalSession(for: bot) {
                            target = LiveTerminal(agent: ref, title: bot.name)
                        } else { target = nil }
                        store.previewInInspector(.init(server: store.herdrServer(for: bot), target: target))
                    }.controlSize(.small).accessibilityLabel("Show terminal in Details")
                }
                MoreInfoSections(tabs: Array(store.infoTabs(for: bot).dropFirst(3)), selection: store.visibleInfoTab(for: bot)) { store.infoTab = $0 }
                Button { store.editingBot = bot } label: { Image(systemName: "gearshape").frame(width: 24, height: 24).contentShape(Rectangle()) }.buttonStyle(.plain).help(SimpleCopy.agentSettings).accessibilityLabel(SimpleCopy.agentSettings)
                Button { store.showInfo = false } label: { Image(systemName: "xmark").frame(width: 24, height: 24).contentShape(Rectangle()) }
                    .buttonStyle(.plain).help("Close").accessibilityLabel("Close")
            }.padding(.horizontal, 14).frame(height: 54).windowDragStrip(probe: "details_header")
            Divider()
            InfoTabBar(tabs: store.infoTabs(for: bot), selection: store.visibleInfoTab(for: bot)) { store.infoTab = $0 }
            Divider()
            if store.visibleInfoTab(for: bot) == .overview { identity }
            ScrollView { panelContent.padding(14).frame(maxWidth: .infinity, alignment: .leading) }
        }.frame(minWidth: ChromeMetrics.infoWidth.min, idealWidth: ChromeMetrics.infoWidth.ideal, maxWidth: ChromeMetrics.infoWidth.max)
        .background(AppColor.panel)
    }

    @ViewBuilder private var panelContent: some View {
        switch store.visibleInfoTab(for: bot) {
        case .overview: overview.id(bot.id)
        case .approvals:
            let server = store.herdrServer(for: bot)
            VStack(alignment: .leading, spacing: 12) {
                Text("Pending approvals").font(.headline)
                if inboxes[server.id]?.unavailable == true {
                    Text("Can’t check approvals on " + server.name).foregroundStyle(.secondary)
                } else if inboxes[server.id] == nil {
                    ProgressView("Checking approvals…").controlSize(.small)
                } else if store.approvals(for: bot, in: nil, inboxes: inboxes).isEmpty && store.herdrPrompts[bot.id] == nil {
                    Text("No pending requests").foregroundStyle(.secondary)
                }
                HerdrChatApprovals(bot: bot, server: server).id(server.id)
                HerdrCommandRules(botID: bot.id, server: server).id("\(server.id)/\(bot.id)")
                HerdrHelperModelSection(bot: bot, server: server, templates: [], approvalsOnly: true)
            }
        case .model: HerdrAgentControls(bot: bot, preset: modelPreset).id(bot.id)
        case .team:
            let server = store.herdrServer(for: bot)
            VStack(alignment: .leading, spacing: 18) {
                HerdrTeamActivity(bot: bot)
                HerdrHelpersSection(bot: bot)
                Button(store.startsHerdrHelpers(bot) ? "Helper instructions on" : "Helper instructions off") { store.editingBot = bot }
                    .help("Edit this bot’s helper instructions in Advanced settings")
            }.id("\(bot.id)-\(server.id)-\(server.place)-\(server.address)")
        case .routines:
            let server = store.herdrServer(for: bot)
            HerdrRoutinesPanel(bot: bot, server: server, inInspector: true)
                .id("\(bot.id)-\(server.id)-\(server.place)-\(server.address)")
        case .skills: HerdrSkillsPanel(bot: bot, preset: skillsPreset)
        case .media: MediaTabView(bot: bot)
        }
    }

    private var identity: some View {
        HStack(alignment: .center, spacing: 9) {
            BotAvatar(bot: bot, size: 36, motion: .focus, isWorking: store.isWorking(bot), probe: "overview", facing: .left,
                      mainBotLabel: store.herdrMainBotLabel(bot))
            VStack(alignment: .leading, spacing: 2) {
                Text(bot.name).font(.headline)
                if !bot.title.isEmpty, bot.title != Bot.placeholderTitle {
                    Text(bot.title).font(.callout).foregroundStyle(.secondary)
                }
                if bot.grokSourceID != nil, PreparedGrokBundle.meaningful(bot.botDescription).isEmpty {
                    Text("No specific description in Grok").font(.caption).foregroundStyle(.secondary)
                    Button("Edit description") { store.editingBot = bot }.buttonStyle(.link)
                } else if !bot.botDescription.isEmpty {
                    Text(verbatim: bot.botDescription).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 12) {
            let instructions = bot.outboundPersona.trimmingCharacters(in: .whitespacesAndNewlines)
            if !instructions.isEmpty, instructions != Bot.defaultPersona {
                BotInstructions(text: instructions)
            }
            if bot.backend == .herdr {
                Divider()
                BotUsageOverview(bot: bot)
                HerdrBotProjectsSection(bot: bot, quietWhenEmpty: true)
                HerdrOverviewSection(bot: bot)
                Button("Team activity", systemImage: AgentInfoTab.team.symbol) { store.openInfoTab(.team) }
                HerdrActiveHelpersSection()
                HerdrHelpersSection(bot: bot)
            }
            groups
        }
        .task(id: store.herdrServer(for: bot)) {
            guard store.launchWorkEnabled, bot.backend == .herdr else { return }
            let server = store.herdrServer(for: bot)
            await store.refreshProjectAssignments(on: server, using: store.herdrProjectsModel(for: server))
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
