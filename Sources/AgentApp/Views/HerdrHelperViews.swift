import SwiftUI

extension Bot {
    var sessionsExpandedKey: String { "sidebar.sessionsExpanded.\(id)" }
}

/// The disclosure belongs to the bot. Direct and group sessions keep their own identities.
struct SidebarBotSessions<ParentRow: View>: View {
    @EnvironmentObject private var store: AppStore
    let bot: Bot
    let parents: [HerdrHelperParent]
    let workers: [HerdrCodejobRow]
    let parentRow: ParentRow

    init(bot: Bot, parents: [HerdrHelperParent], workers: [HerdrCodejobRow], @ViewBuilder row: () -> ParentRow) {
        self.bot = bot
        self.parents = AppStore.sortedSidebarRoots(parents)
        self.workers = workers
        parentRow = row()
    }

    var body: some View {
        let expanded = store.sessionsExpanded(for: bot)
        if parents.isEmpty && workers.isEmpty {
            botControls
        } else {
            HStack(spacing: 0) {
                botControls
                Button {
                    store.setSessionsExpanded(!expanded, for: bot)
                } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .frame(width: 28, height: 32).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Sessions for " + bot.name)
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                .help(expanded ? "Hide sessions" : "Show sessions")
            }
            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(parents, id: \.self) { parent in
                        if let archive = parent.archive, parents.count > 1 {
                            let started = Date(timeIntervalSince1970: Double(archive.session.createdMs) / 1000)
                            let when = started.formatted(date: .abbreviated, time: .shortened)
                            Text([store.helperGroupNames[parent], when].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary).padding(.leading, 10)
                        } else if let group = store.helperGroupNames[parent] {
                            Text(group).font(.caption).foregroundStyle(.secondary).padding(.leading, 10)
                        }
                        ForEach(store.sessionRows(under: parent, for: bot)) { item in
                            Group {
                                switch item {
                                case .workspace(let row):
                                    HerdrHelperRow(bot: bot, row: row, selected: !store.showOnlyAttention && store.openHerdrHelper == row.id) {
                                        store.open(bot, helper: row.id, revealInSidebar: false)
                                    }
                                case .native(let row, let selection, _):
                                    SidebarNativeThread(bot: bot, row: row, selection: selection)
                                }
                            }.padding(.leading, CGFloat(min(item.depth, 5)) * 10)
                                .id(item.sidebarID)
                        }
                    }
                    ForEach(workers) { row in
                        let target = LiveTerminal(host: row.id.host, job: row.job, botName: bot.name)
                        Button {
                            store.previewInInspector(TerminalBrowserRequest(server: store.herdrServer(for: bot), target: target), fallbackBot: bot)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: row.job.isWorking ? "terminal" : "clock").foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(row.job.description).font(.system(size: 13, weight: .medium))
                                    Text(target.detail).font(.caption).foregroundStyle(.secondary)
                                }.lineLimit(1)
                                Spacer(minLength: 0)
                            }.padding(.leading, 10).frame(height: HerdrHelperRow.height).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(!row.job.isWorking)
                            .accessibilityLabel(row.job.description + " for " + bot.name + " · " + target.detail)
                    }
                }
                .overlay(alignment: .leading) { Rectangle().fill(AppColor.separator).frame(width: 1).accessibilityHidden(true) }
                .padding(.leading, SidebarMetrics.rowPadding + SidebarMetrics.mark / 2)
            }
        }
    }
    @ViewBuilder private var botControls: some View {
        if let ref = store.herdrTerminalSession(for: bot) {
            HStack(spacing: 0) {
                parentRow
                SidebarTerminalButton(bot: bot, target: LiveTerminal(agent: ref, title: bot.name))
            }
        } else { parentRow }
    }
}

struct SidebarTerminalButton: View {
    @EnvironmentObject private var store: AppStore
    let bot: Bot
    let target: LiveTerminal
    var avatarSize: CGFloat? = nil

    var body: some View {
        let server = store.herdrServer(for: bot)
        let selected = store.showInfo && store.inspectorTerminal?.target?.id == target.id && store.inspectorTerminal?.server == server
        Button {
            store.previewInInspector(.init(server: server, target: target), fallbackBot: bot)
        } label: {
            Group {
                if let avatarSize {
                    AvatarTerminalBadge(avatarSize: avatarSize)
                } else {
                    Image(systemName: "terminal").font(.caption).foregroundStyle(.secondary)
                }
            }.frame(width: 24, height: 24)
                .background(selected ? AppColor.selection : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help("Preview terminal for " + target.title)
        .accessibilityLabel("Preview terminal for " + target.title)
    }
}

/// Put the terminal and disclosure beside the title. The assignment can use the whole second line.
private struct SidebarSessionRow<Glyph: View, Clock: View>: View {
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var hovering = false
    let bot: Bot
    let name: String
    let detail: String
    let selected: Bool
    let target: LiveTerminal?
    let folded: Bool
    let toggleBranch: (() -> Void)?
    let accessibilityName: String
    let accessibilityDetail: String
    let helpText: String
    let open: () -> Void
    @ViewBuilder let glyph: () -> Glyph
    @ViewBuilder let clock: () -> Clock

    private var controlsWidth: CGFloat { (target == nil ? 0 : 24) + (toggleBranch == nil ? 0 : 24) }

    private var title: some View { Text(verbatim: name).font(.system(size: 12, weight: .semibold)) }
    private var subtitle: some View { Text(verbatim: detail).font(.system(size: 11)).foregroundStyle(.secondary) }
    private var duration: some View { clock().font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary) }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: open) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    glyph().font(.system(size: 11, weight: .semibold)).frame(width: 14).accessibilityHidden(true)
                    ViewThatFits(in: .horizontal) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline, spacing: 3) {
                                title.fixedSize()
                                Spacer(minLength: 0)
                                duration.fixedSize()
                            }.padding(.trailing, controlsWidth)
                            Color.clear.frame(height: 14).overlay(alignment: .leading) { subtitle }
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            title.padding(.trailing, controlsWidth)
                            HStack(alignment: .firstTextBaseline, spacing: 3) {
                                subtitle.frame(maxWidth: .infinity, alignment: .leading)
                                duration.fixedSize()
                            }
                        }
                    }.lineLimit(1)
                }.padding(.leading, 7).padding(.trailing, 3)
                    .frame(maxWidth: .infinity, minHeight: HerdrHelperRow.height).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(accessibilityName).accessibilityValue(accessibilityDetail)
                .accessibilityAddTraits(selected ? .isSelected : []).help(helpText)
            HStack(spacing: 0) {
                if let toggleBranch {
                    Button(action: toggleBranch) {
                        Image(systemName: folded ? "chevron.right" : "chevron.down")
                            .font(.caption).frame(width: 24, height: 24).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("Sessions for " + name)
                        .accessibilityValue(folded ? "Collapsed" : "Expanded")
                }
                if let target { SidebarTerminalButton(bot: bot, target: target) }
            }
        }
        .background(selected ? AppColor.selection : hovering ? AppColor.selection.opacity(0.6) : .clear,
                    in: RoundedRectangle(cornerRadius: SidebarMetrics.selectionRadius))
        .overlay {
            if selected, contrast == .increased {
                RoundedRectangle(cornerRadius: SidebarMetrics.selectionRadius).strokeBorder(.primary).allowsHitTesting(false)
            }
        }
        .onHover { hovering = $0 }
    }
}

struct HerdrHelperRow: View {
    @EnvironmentObject private var store: AppStore
    let bot: Bot
    let row: SidebarHelperSession
    let selected: Bool
    let open: () -> Void
    private var helper: HerdrClient.Helper { row.helper }
    static let height: CGFloat = 44

    var body: some View {
        SidebarSessionRow(bot: bot, name: helper.name, detail: Self.fragment(helper), selected: selected,
                          target: helper.isLive ? LiveTerminal(agent: helper.ref, title: helper.name, core: row.core) : nil,
                          folded: row.folded, toggleBranch: row.hasChildren ? { store.setHelperBranchFolded(!row.folded, branch: row.branch, for: bot) } : nil,
                          accessibilityName: ["Helper " + helper.name, helper.runLine, helper.statusLine].filter { !$0.isEmpty }.joined(separator: ", "),
                          accessibilityDetail: Self.rowDetail(helper),
                          helpText: [helper.name, helper.runLine, helper.statusLine, helper.assignment ?? ""].filter { !$0.isEmpty }.joined(separator: " · "),
                          open: open, glyph: { HerdrHelperGlyph(helper: helper) }, clock: { sessionTime })
    }

    @ViewBuilder private var sessionTime: some View {
        let start = Date(timeIntervalSince1970: Double(helper.createdMs) / 1000)
        if helper.isWorking && helper.createdMs > 1_000_000_000_000 {
            TimelineView(.periodic(from: .now, by: 1)) { tick in
                Text(ActivityCopy.duration(max(0, tick.date.timeIntervalSince(start)), compact: true)).monospacedDigit()
            }
        } else if helper.showingAnswer, let end = helper.reply?.atMs, Double(end) >= Double(helper.createdMs) {
            Text(ActivityCopy.duration((Double(end) - Double(helper.createdMs)) / 1000, compact: true)).monospacedDigit()
        }
    }

    nonisolated private static func rowDetail(_ helper: HerdrClient.Helper) -> String {
        if helper.showingAnswer, let answer = helper.resultPreview {
            return answer.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        return helper.taskLine
    }

    nonisolated static func fragment(_ helper: HerdrClient.Helper) -> String {
        let state = helper.isLive && helper.status?.state == "blocked" ? "Waiting" : helper.statusLine
        let detail = rowDetail(helper)
        return detail.isEmpty ? state : "\(state) · \(detail)"
    }
}

/// Provider-native threads have a transcript on their owning launch, even when Core has no child PTY.
private struct SidebarNativeThread: View {
    @EnvironmentObject private var store: AppStore
    let bot: Bot
    let row: NativeSidebarRow
    let selection: HerdrHelperSelection

    var body: some View {
        let thread = row.thread
        let current = store.openHerdrHelper?.native
        let selected = !store.showOnlyAttention && store.openHerdrHelper?.parent == selection.parent
            && current?.owner == selection.native?.owner && current?.core == selection.native?.core && current?.server == selection.native?.server
            && current?.thread.id == thread.id && current?.thread.provider == thread.provider
        let detail = thread.state == "answered" && !thread.reply.isEmpty ? thread.reply : thread.task
        let icon: String
        let color: Color
        switch thread.state {
        case "working": (icon, color) = ("circle.dotted", .accentColor)
        case "answered": (icon, color) = ("checkmark.circle.fill", .green)
        case "error": (icon, color) = ("exclamationmark.circle", .orange)
        default: (icon, color) = ("stop.circle", .secondary)
        }
        let subtitle = [thread.statusLine, detail].filter { !$0.isEmpty }.joined(separator: " · ")
        return SidebarSessionRow(bot: bot, name: thread.name, detail: subtitle, selected: selected, target: row.target,
                                 folded: row.folded, toggleBranch: row.hasChildren ? { store.setNativeSessionFolded(!row.folded, target: row.id, for: bot) } : nil,
                                 accessibilityName: thread.provider.label + " agent " + thread.name + ", " + thread.statusLine,
                                 accessibilityDetail: detail, helpText: "Open session for " + thread.name,
                                 open: { store.open(bot, helper: selection, revealInSidebar: false) },
                                 glyph: { Image(systemName: icon).foregroundStyle(color) }, clock: { NativeThreadDuration(thread: thread) })

    }
}

struct NativeThreadDuration: View {
    let thread: HerdrClient.NativeThread

    var body: some View {
        if thread.createdMs > 0 {
            if thread.state == "working" {
                TimelineView(.periodic(from: .now, by: 1)) { tick in
                    Text(ActivityCopy.duration(max(0, tick.date.timeIntervalSince1970 - Double(thread.createdMs) / 1000), compact: true))
                }
            } else if let end = thread.completedMs, end >= thread.createdMs {
                Text(ActivityCopy.duration((Double(end) - Double(thread.createdMs)) / 1000, compact: true))
            }
        }
    }
}

/// A helper's state as one small symbol: working, waiting at a prompt, failed, answered, ended.
struct HerdrHelperGlyph: View {
    let helper: HerdrClient.Helper
    var body: some View {
        let look: (symbol: String, colour: Color) = {
            guard helper.isLive else { return helper.answered == true ? ("checkmark.circle.fill", .green) : ("stop.circle", .secondary) }
            switch helper.status?.state {
            case "working": return ("circle.dotted", .accentColor)
            case "blocked": return ("exclamationmark.circle.fill", .orange)
            case "error": return ("xmark.octagon.fill", .red)
            default: return helper.answered == true ? ("checkmark.circle.fill", .green) : ("circle.dashed", .secondary)
            }
        }()
        Image(systemName: look.symbol).foregroundStyle(look.colour).accessibilityHidden(true)
    }
}

/// Helpers available from the conversation and their latest result.
struct HerdrCodingAgentCard: View {
    let helpers: [HerdrClient.Helper]
    let tint: BotTint
    let openTerminal: (HerdrClient.Helper) -> Void
    let openDetails: (HerdrClient.Helper) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Coding agents").font(.caption.weight(.semibold)).accessibilityAddTraits(.isHeader)
            if helpers.count > 3 {
                ScrollView { rows }.frame(height: 144)
            } else {
                rows
            }
        }.chatCard(tint: tint).accessibilityElement(children: .contain).accessibilityIdentifier("chat.codingAgents")
    }

    private var rows: some View {
        VStack(spacing: 6) {
            ForEach(helpers) { helper in
                HStack(spacing: 8) {
                    HerdrHelperGlyph(helper: helper).font(.callout).frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(helper.name).font(.callout.weight(.semibold)).lineLimit(1)
                            if !helper.runLine.isEmpty {
                                Text(helper.runLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        if let result = helper.resultPreview {
                            Text(result).font(.callout).lineLimit(2).accessibilityLabel("Result from \(helper.name): \(result)")
                        } else {
                            Text(helper.statusLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        if helper.resultPreview == nil, !helper.taskLine.isEmpty {
                            Text(helper.taskLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                    if helper.isLive {
                        Button("Terminal", systemImage: "terminal") { openTerminal(helper) }
                            .accessibilityLabel("Open terminal for \(helper.name)").accessibilityIdentifier("chat.helper.terminal.\(helper.id)")
                    }
                    Button("Details") { openDetails(helper) }.accessibilityLabel("Details for \(helper.name)")
                }.buttonStyle(.bordered).controlSize(.small)
            }
        }
    }
}

/// Overview's helpers of a Herdr bot, each as a card, with how many run of the number the server allows. Nothing without helpers.
struct HerdrHelpersSection: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var bot: Bot
    var body: some View {
        if let list = store.herdrHelpers[bot.id], !list.helpers.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(bot.name)’s helper sessions").font(.headline); Spacer()
                    Text(Self.count(list)).font(.caption).foregroundStyle(.secondary)
                }
                ForEach(list.helpers.filter { !$0.hasOpenTask }) { helper in
                    HerdrHelperCard(helper: helper, selected: store.isOpen(helper, of: bot)) { store.open(helper, of: bot) }
                }
                Text("\(bot.name) hands parts of its work to helpers.\(list.stopAfterSeconds.map { " Each one leaves \(HerdrHelperPolicyDraft.delayLabel($0)) after it answers." } ?? "")")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// "2 of 3 running", or "2 running" when the server states no limit.
    nonisolated static func count(_ list: HerdrClient.Helpers) -> String {
        let running = list.helpers.filter(\.isLive).count
        return list.limit.map { "\(running) of \($0) running" } ?? "\(running) running"
    }
}

/// One helper as a card: its state and name, its task, and the difficulty and model as the server names them (in
/// full, never shortened). Pressing it opens the helper's read-only view.
struct HerdrHelperCard: View {
    let helper: HerdrClient.Helper; let selected: Bool; let open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    HerdrHelperGlyph(helper: helper).font(.system(size: 13, weight: .semibold))
                    Text(helper.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(helper.statusLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if let task = helper.assignment, !task.isEmpty {
                    Text(task).font(.callout).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                }
                if !helper.runLine.isEmpty { Text(helper.runLine).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading) }
            }
            .inspectorCard(padding: 10, selected: selected).contentShape(RoundedRectangle(cornerRadius: AppleMetrics.corner, style: .continuous))
        }.buttonStyle(.plain).help("Helper \(helper.name): \(helper.statusLine). \(helper.assignment ?? "")")
            .accessibilityLabel("Helper \(helper.name), \(helper.runLine), \(helper.statusLine)")
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A helper, read-only, in place of its bot's chat: its task, its tool steps, its latest reply and its terminal.
/// It follows the helper's session on the bridge's event stream (polling it every two seconds where there is none)
/// while the helper runs, and reads it once more when it has ended. A helper the
/// server no longer lists stays on screen as it was last read until the person leaves it.
struct HerdrHelperView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var bot: Bot
    let selection: HerdrHelperSelection
    let groupName: String?
    let closeOverviewDetails: (() -> Void)?
    /// The helper and its Core as last listed, and its log as last read (a render passes all three in).
    @State private var helper: HerdrClient.Helper?; @State private var core: String?
    @State private var log: HerdrClient.HelperLog?; @State private var problem = ""
    private struct ReadKey: Equatable {
        let selection: HerdrHelperSelection
        let core: String?
        let helper: HerdrClient.AgentRef?
        let attempt: Int
    }
    @State private var readAttempt = 0
    @StateObject private var reply: ChatMessage
    @State private var guidance = ""
    @State private var controlError = ""
    @State private var promotion: Task<Void, Never>?
    @State private var stopping = false
    @State private var stopped = false
    @State private var terminal: HerdrTerminalTarget?

    init(bot: Bot, selection: HerdrHelperSelection, helper: HerdrClient.Helper? = nil, core: String? = nil, log: HerdrClient.HelperLog? = nil, groupName: String? = nil, closeOverviewDetails: (() -> Void)? = nil) {
        self.bot = bot; self.selection = selection
        self.groupName = groupName; self.closeOverviewDetails = closeOverviewDetails
        _helper = State(initialValue: helper); _core = State(initialValue: core); _log = State(initialValue: log)
        _reply = StateObject(wrappedValue: ChatMessage(role: .assistant, content: log?.latestReply(answered: helper?.answered == true) ?? ""))
    }

    private var listed: HerdrClient.Helper? { store.herdrHelpers[selection.parent]?.sidebarSessions.first { $0.id == selection.helperID } }

    var body: some View {
        let shown = listed ?? helper
        let back = store.backDestination(for: selection, of: bot)
        let group = store.groupOwningHelper(selection, of: bot)
        let backTitle = "Back to " + back.name
        let unavailable = store.herdrHelperReads[selection.parent] == .unavailable
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                if let closeOverviewDetails {
                    Button("Done", action: closeOverviewDetails)
                } else {
                    ShowSidebarItem()
                    Button {
                        store.open(back, of: bot)
                    } label: { Image(systemName: "chevron.left").frame(width: 22, height: 22).contentShape(Rectangle()) }
                        .buttonStyle(.plain).help(backTitle).accessibilityLabel(backTitle)
                }
                BotAvatar(bot: bot, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text([shown?.name ?? "Helper", "Helper of " + back.delegatorName(for: bot)].joined(separator: " · "))
                        .font(.system(size: 14, weight: .semibold)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    Text([stopped ? "Stopped" : unavailable ? "Status unavailable" : shown?.statusLine, groupName ?? store.helperGroupNames[selection.parent] ?? selection.groupRuntime].compactMap { $0 }.joined(separator: " · ")).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if let shown {
                    if !shown.runLine.isEmpty {
                        FactChip(text: shown.runLine).help(shown.difficultyLine.map { "\(bot.name) called this an \($0.lowercased()), and helpers for those run on \(shown.runLine)." } ?? "The model this helper runs on")
                    }
                    if listed?.isLive == true && !unavailable && !stopped {
                        ChatTerminalPreviewButton(server: store.herdrServer(for: bot),
                                                  target: LiveTerminal(agent: shown.ref, title: shown.name, core: store.herdrHelpers[selection.parent]?.core ?? core)) {
                            if let closeOverviewDetails {
                                closeOverviewDetails()
                                store.open(bot, helper: selection)
                            }
                        }
                        Button("Open terminal", systemImage: "terminal") {
                            terminal = HerdrTerminalTarget(agent: shown.ref, title: "\(bot.name) · \(shown.name)")
                        }.buttonStyle(.bordered).controlSize(.small).fixedSize()
                            .accessibilityIdentifier("helper.terminal")
                    }
                }
                if closeOverviewDetails == nil { ShowDetailsItem() }
            }.padding(.horizontal, ChromeMetrics.headerPadding).frame(height: 54).windowDragStrip(probe: "helper_header").background(AppColor.chat)
            Rectangle().fill(AppColor.separator).frame(height: 0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if unavailable {
                        StatusCard(kind: .info, title: "Helper activity is unavailable.", detail: "Showing the last details received from \(store.herdrServer(for: bot).name).")
                    } else if listed == nil, shown != nil {
                        StatusCard(kind: .info, title: "This helper has finished.", detail: "This is how it looked at the end.")
                    }
                    helperPart("Task", detail: stopped ? "Stopped" : shown?.statusLine) {
                        if let task = shown?.task ?? log?.tasks.first?.text, !task.isEmpty {
                            Text(Self.assignment(task)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        } else if log == nil {
                            quiet(problem.isEmpty ? "Loading…" : "Task unavailable.")
                        } else { quiet("No task recorded.") }
                        ForEach(Array(followUps(after: shown?.task).enumerated()), id: \.offset) { _, text in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Follow-up").font(.caption).foregroundStyle(.secondary)
                                Text(Self.assignment(text)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    helperPart(log.map { "Steps (\($0.tools.count))" } ?? "Steps", detail: shown?.runLine) {
                        if let tools = log?.tools, !tools.isEmpty { ForEach(tools, id: \.seq) { step($0, running: shown?.isWorking == true) } }
                        else if log == nil { quiet(problem.isEmpty ? "Loading…" : "Steps unavailable.") }
                        else { quiet("No steps yet.") }
                    }
                    helperPart(shown?.answered != true && log?.draft?.isEmpty == false ? "Reply so far" : "Latest reply", detail: nil) {
                        if !reply.content.isEmpty {
                            MarkdownContent(message: reply).textSelection(.enabled)
                        } else if let latest = shown?.resultPreview {
                            Text(verbatim: latest).textSelection(.enabled)
                            if shown?.reply?.truncated == true { quiet("Showing the saved excerpt.") }
                        } else {
                            if stopped { quiet("Stopped before replying.") }
                            else if log == nil { quiet(problem.isEmpty ? "Loading…" : "Reply unavailable.") }
                            else if shown?.isLive == false || shown?.answered == true { quiet("No reply recorded.") }
                            else { quiet("No reply yet.") }
                        }
                        if let screen = log?.screen, !screen.isEmpty {
                            Divider()
                            ScrollView([.horizontal, .vertical]) {
                                Text(screen).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).fixedSize()
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                                .frame(maxHeight: 150).fixedSize(horizontal: false, vertical: true)
                                .background(AppColor.sidebar, in: RoundedRectangle(cornerRadius: 4))
                                .accessibilityLabel("Terminal output")
                        }
                    }
                    Button(selection.archive == nil ? "Steer via " + bot.name : "Open " + (group?.name ?? bot.name), systemImage: "arrow.right") {
                        if store.beginHelperSteering(selection, of: bot) { closeOverviewDetails?() }
                        else { controlError = "The group session that started this helper is no longer available." }
                    }.buttonStyle(.appleProminent).controlSize(.large).accessibilityIdentifier("helper.steerViaParent")
                    if let shown, listed?.isLive == true && !unavailable && !stopped {
                        VStack(alignment: .leading, spacing: 8) {
                            if selection.archive == nil {
                                HStack {
                                    TextField("Guide this helper through \(bot.name)…", text: $guidance)
                                        .onSubmit { guide(shown) }
                                        .accessibilityIdentifier("helper.guidance")
                                    Button("Send to \(bot.name)") { guide(shown) }
                                        .disabled(guidance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                }
                            }
                            Button("Stop helper", systemImage: "stop.circle") {
                                stopping = true
                                controlError = ""
                                Task {
                                    defer { stopping = false }
                                    do {
                                        try await store.stopHelper(shown, selection: selection, of: bot)
                                        stopped = true
                                        await store.refreshHerdrHelpers(on: store.herdrServer(for: bot).id)
                                    } catch { controlError = error.localizedDescription }
                                }
                            }.buttonStyle(.bordered).controlSize(.large).accessibilityIdentifier("helper.stop")
                        }.disabled(stopping)
                    }
                    if let shown, let core {
                        let existing = store.promotedBot(for: shown.ref, core: core, parent: bot)
                        Button(existing.map { "Open \($0.name) chat" } ?? "Promote to bot", systemImage: "person.crop.circle.badge.plus") {
                            controlError = ""
                            promotion = Task {
                                defer { promotion = nil }
                                do {
                                    let promoted = try await store.promoteHelper(shown, core: core, selection: selection, of: bot)
                                    guard !Task.isCancelled else { return }
                                    closeOverviewDetails?()
                                    store.open(promoted)
                                } catch { controlError = error.localizedDescription }
                            }
                        }
                        .disabled(promotion != nil || (existing == nil && (unavailable || listed == nil)))
                        .accessibilityIdentifier("helper.promote")
                        .help("Open a permanent chat with this helper’s model, tasks and replies.")
                    }
                    if !controlError.isEmpty {
                        Text(controlError).font(.callout).foregroundStyle(AppColor.caution)
                    }
                    if !problem.isEmpty {
                        Text(problem).font(.caption).foregroundStyle(AppColor.caution).textSelection(.enabled)
                        Button("Retry history") { readAttempt += 1 }
                    }
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.background(AppColor.chat)
            .sheet(item: $terminal) { target in HerdrTerminalSheet(bot: bot, agent: target.agent, title: target.title) }
            .task(id: ReadKey(selection: selection, core: store.herdrHelpers[selection.parent]?.core ?? core,
                              helper: shown?.ref, attempt: readAttempt)) {
                problem = ""
                await follow()
            }
            .onDisappear { promotion?.cancel() }
            .onChange(of: listed) { _, now in if let now { helper = now } }
            .onChange(of: store.herdrHelpers[selection.parent]?.core) { _, now in if let now { core = now } }
    }

    private func guide(_ helper: HerdrClient.Helper) {
        guard !stopping, !guidance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if store.guideHelper(helper, selection: selection, of: bot, instruction: guidance) {
            guidance = ""
            closeOverviewDetails?()
        } else {
            controlError = store.errorMessage ?? "The parent session could not accept this instruction."
        }
    }

    private func quiet(_ text: String) -> some View { Text(text).foregroundStyle(.secondary) }

    /// "Running a command" and its command line; the last unfinished step of a working helper is the one running now.
    private func step(_ call: HerdrClient.ToolCall, running: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: call.failed ? "xmark.circle" : call.finished ? "checkmark.circle" : running ? "circle.dotted" : "circle")
                .font(.system(size: 11)).foregroundStyle(call.failed ? Color.red : call.finished ? AppColor.sage : .secondary).frame(width: 14)
            Text(ActivityCopy.label(HerdrBackend.toolName(call.tool))).font(.callout)
            if let detail = call.detail, !detail.isEmpty {
                Text(detail).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            }
        }
    }

    /// A task can contain shell syntax. Only paired inline code markers change how its text appears.
    static func assignment(_ source: String) -> AttributedString {
        var result = AttributedString()
        var start = source.startIndex
        for span in source.ranges(of: #/`[^`]+`/#) {
            result.append(AttributedString(source[start..<span.lowerBound]))
            var code = AttributedString(source[span].dropFirst().dropLast())
            code.inlinePresentationIntent = .code
            code.font = .body.monospaced()
            result.append(code)
            start = span.upperBound
        }
        result.append(AttributedString(source[start...]))
        return result
    }

    /// Every later task the helper was given (`helper send`).
    private func followUps(after task: String?) -> [String] {
        let texts = (log?.tasks ?? []).map(\.text)
        return texts.first == task || task == nil ? Array(texts.dropFirst()) : texts.filter { $0 != task }
    }

    private func follow() async {
        if let listed { helper = listed }
        if let known = store.herdrHelpers[selection.parent]?.core { core = known }
        // The helper's own session on the event stream; a server without one, or a stream that breaks, is polled.
        if (listed ?? helper)?.isLive == true, await followStream() { return }
        while !Task.isCancelled {
            let live = listed?.isLive == true
            await read()
            // An ended helper changes no more: that read was the last one.
            guard live else { return }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    /// Follows the helper on its event stream until its session ends (true). Its terminal is not in the stream and is
    /// read every two seconds beside it. False when the stream could not be opened or broke: the caller polls.
    private func followStream() async -> Bool {
        guard store.launchWorkEnabled, let helper = listed ?? helper, let events = try? store.herdrHelperEvents(helper.ref, of: bot) else { return false }
        let screens = Task { @MainActor in
            while !Task.isCancelled {
                if let screen = await store.herdrHelperScreen(helper.ref, of: bot), !Task.isCancelled { if log == nil { log = HerdrClient.HelperLog() }; log?.screen = screen }
                try? await Task.sleep(for: .seconds(2))
            }
        }
        defer { screens.cancel() }
        var held = HerdrClient.HelperLog(), draftID: String?
        do {
            for try await event in events {
                guard held.apply(event, draftID: &draftID) else { return false }
                if case .heartbeat = event { continue }
                held.screen = log?.screen
                show(held)
                if case .end = event { return true }
            }
        } catch {}
        return false
    }

    private func show(_ fresh: HerdrClient.HelperLog) {
        if fresh != log { log = fresh }
        let text = fresh.latestReply(answered: (listed ?? helper)?.answered == true) ?? ""
        if reply.content != text { reply.content = text }
        problem = ""
    }

    private func read() async {
        guard let helper = listed ?? helper, let core else {
            if !Task.isCancelled { problem = "The workspace hasn’t reported this helper’s history." }
            return
        }
        do {
            let fresh = try await store.herdrHelperLog(helper.ref, core: core, of: bot, includeScreen: helper.isLive)
            guard !Task.isCancelled else { return }
            show(fresh)
        } catch { if log == nil, !Task.isCancelled { problem = error.localizedDescription } }
    }
}

@MainActor
func helperPart<Content: View>(_ title: String, detail: String?, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 8) {
            Text(title).font(.callout.weight(.semibold)).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 4)
            if let detail, !detail.isEmpty {
                Text(detail).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            }
        }.padding(.horizontal, 12).padding(.vertical, 8)
        Divider()
        VStack(alignment: .leading, spacing: 6) { content() }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 10)
    }.background(AppColor.card, in: RoundedRectangle(cornerRadius: 7))
        .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(AppColor.separator) }
}
