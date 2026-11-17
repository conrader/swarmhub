import SwiftUI

/// A Herdr bot's helper agents in the sidebar, nested under the bot's row while the server lists any, newest first.
struct HerdrHelperRows: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var bot: Bot
    var body: some View {
        ForEach(store.herdrHelpers[bot.id]?.helpers ?? []) { helper in
            HerdrHelperRow(helper: helper, selected: store.isOpen(helper, of: bot)) { store.open(helper, of: bot) }
                .padding(.leading, SidebarMetrics.rowPadding + SidebarMetrics.mark / 2)
        }
    }
}

/// One helper: its name, the difficulty its agent chose and the model the server gave it, then what it is doing and
/// its task. Pressing it opens the helper's read-only view.
struct HerdrHelperRow: View {
    let helper: HerdrClient.Helper; let selected: Bool; let open: () -> Void
    @State private var hovering = false
    static let height: CGFloat = 44

    var body: some View {
        Button(action: open) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                HerdrHelperGlyph(helper: helper).font(.system(size: 11, weight: .semibold)).frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(helper.name).font(.system(size: 13, weight: .medium)).foregroundStyle(.primary).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 4)
                        Text(helper.runLine).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).layoutPriority(1)
                    }
                    Text(Self.fragment(helper)).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                }
            }
            .padding(.horizontal, 10).frame(height: Self.height).contentShape(RoundedRectangle(cornerRadius: SidebarMetrics.selectionRadius))
            .background(selected ? AppColor.selection : hovering ? AppColor.selection.opacity(0.45) : .clear, in: RoundedRectangle(cornerRadius: SidebarMetrics.selectionRadius))
            .onHover { hovering = $0 }
        }.buttonStyle(.plain).help("Helper \(helper.name): \(helper.statusLine). \(helper.task ?? "")")
            .accessibilityLabel("Helper \(helper.name), \(helper.runLine), \(helper.statusLine)")
    }

    /// "Working · Fix the failing test": the status, then the task on the same line.
    nonisolated static func fragment(_ helper: HerdrClient.Helper) -> String {
        let task = (helper.task ?? "").components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return task.isEmpty ? helper.statusLine : "\(helper.statusLine) · \(task)"
    }
}

/// A helper's state as one small symbol: working, waiting at a prompt, failed, answered, ended.
struct HerdrHelperGlyph: View {
    let helper: HerdrClient.Helper
    var body: some View {
        let look: (symbol: String, colour: Color) = {
            guard helper.isLive else { return ("stop.circle", .secondary) }
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

/// Overview's helpers of a Herdr bot, each as a card, with how many run of the number the server allows. Nothing without helpers.
struct HerdrHelpersSection: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var bot: Bot
    var body: some View {
        if let list = store.herdrHelpers[bot.id], !list.helpers.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Helpers").font(.headline); Spacer()
                    Text(Self.count(list)).font(.caption).foregroundStyle(.secondary)
                }
                ForEach(list.helpers) { helper in
                    HerdrHelperCard(helper: helper, selected: store.isOpen(helper, of: bot)) { store.open(helper, of: bot) }
                }
                Text("Agents \(bot.name) started for parts of its work. The server chose each one's model from the difficulty \(bot.name) gave the task\(list.stopAfterSeconds.map { ", and stops a helper \(HerdrHelperPolicyDraft.delayLabel($0)) after its answer" } ?? "").")
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
                if let task = helper.task, !task.isEmpty {
                    Text(task).font(.callout).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                }
                if !helper.runLine.isEmpty { Text(helper.runLine).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading) }
            }
            .appleCard(padding: 10, selected: selected).contentShape(RoundedRectangle(cornerRadius: AppleMetrics.corner, style: .continuous))
        }.buttonStyle(.plain).help("Helper \(helper.name): \(helper.statusLine). \(helper.task ?? "")")
            .accessibilityLabel("Helper \(helper.name), \(helper.runLine), \(helper.statusLine)")
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
    /// The helper and its Core as last listed, and its log as last read (a render passes all three in).
    @State private var helper: HerdrClient.Helper?; @State private var core: String?
    @State private var log: HerdrClient.HelperLog?; @State private var problem = ""
    @StateObject private var reply: ChatMessage

    init(bot: Bot, selection: HerdrHelperSelection, helper: HerdrClient.Helper? = nil, core: String? = nil, log: HerdrClient.HelperLog? = nil) {
        self.bot = bot; self.selection = selection
        _helper = State(initialValue: helper); _core = State(initialValue: core); _log = State(initialValue: log)
        _reply = StateObject(wrappedValue: ChatMessage(role: .assistant, content: log?.latestReply(answered: helper?.answered == true) ?? ""))
    }

    private var listed: HerdrClient.Helper? { store.herdrHelpers[bot.id]?.helpers.first { $0.id == selection.helperID } }

    var body: some View {
        let shown = listed ?? helper
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                ShowSidebarItem()
                Button { store.open(bot) } label: { Image(systemName: "chevron.left").frame(width: 22, height: 22).contentShape(Rectangle()) }
                    .buttonStyle(.plain).help("Back to \(bot.name)").accessibilityLabel("Back to \(bot.name)")
                if let shown { HerdrHelperGlyph(helper: shown).font(.system(size: 15, weight: .semibold)) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(shown?.name ?? "Helper").font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text("Helper of \(bot.name)").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if let shown {
                    if !shown.runLine.isEmpty {
                        FactChip(text: shown.runLine).help("The difficulty \(bot.name) gave the task, and the model the server runs that difficulty on")
                    }
                    FactChip(text: listed == nil ? "No longer listed" : shown.statusLine)
                }
            }.padding(.horizontal, ChromeMetrics.headerPadding).frame(height: 54).windowDragStrip(probe: "helper_header").background(AppColor.chat)
            Rectangle().fill(AppColor.separator).frame(height: 0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if listed == nil, shown != nil {
                        StatusCard(kind: .info, title: "This helper has ended and left the server's list.", detail: "What you see is how it was last read.")
                    }
                    part("Task", symbol: "text.bubble.fill", colour: .blue) {
                        Text(shown?.task ?? log?.tasks.first?.text ?? "").textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        ForEach(Array(followUps(after: shown?.task).enumerated()), id: \.offset) { _, text in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Follow-up").font(.caption).foregroundStyle(.secondary)
                                Text(text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    part("Steps", symbol: "list.bullet", colour: .orange, count: log?.tools.count) {
                        if let tools = log?.tools, !tools.isEmpty { ForEach(tools, id: \.seq) { step($0, running: shown?.isWorking == true) } }
                        else { quiet(log == nil ? "Reading…" : "No tool steps yet.") }
                    }
                    part(shown?.answered != true && log?.draft?.isEmpty == false ? "Reply so far" : "Latest reply", symbol: "arrowshape.turn.up.left.fill", colour: .green) {
                        if reply.content.isEmpty { quiet(log == nil ? "Reading…" : "No reply yet.") } else { MarkdownContent(message: reply).textSelection(.enabled) }
                    }
                    part("Terminal", symbol: "terminal.fill", colour: .gray, boxed: false) {
                        if let screen = log?.screen, !screen.isEmpty {
                            ScrollView(.horizontal) {
                                Text(screen).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).fixedSize().padding(12)
                            }.frame(maxWidth: .infinity, alignment: .leading).background(AppColor.raised, in: RoundedRectangle(cornerRadius: 10))
                        } else { quiet(log == nil ? "Reading…" : "The server has no terminal for this helper any more.") }
                    }
                    if !problem.isEmpty { Text(problem).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                }.padding(.horizontal, 28).padding(.vertical, 22).frame(maxWidth: 720, alignment: .leading).frame(maxWidth: .infinity)
            }
            Rectangle().fill(AppColor.separator).frame(height: 0.5)
            Text("Read-only. \(bot.name) started this helper and gets its answers; talk to \(bot.name) to change what it does.")
                .font(.system(size: 12)).foregroundStyle(.secondary).padding(12).frame(maxWidth: .infinity)
        }.background(AppColor.chat)
            .task(id: selection) { await follow() }
            .onChange(of: listed) { _, now in if let now { helper = now } }
            .onChange(of: store.herdrHelpers[bot.id]?.core) { _, now in if let now { core = now } }
    }

    /// One part of what the helper did: a small mark and a heading, and under them the content on its own card.
    private func part<Content: View>(_ title: String, symbol: String, colour: Color, count: Int? = nil, boxed: Bool = true, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                SymbolTile(symbol: symbol, colour: colour, size: 22)
                Text(title).font(.headline).accessibilityAddTraits(.isHeader)
                if let count, count > 0 { Text("\(count)").font(.caption).foregroundStyle(.secondary) }
            }
            if boxed { VStack(alignment: .leading, spacing: 8) { content() }.appleCard(padding: 14) } else { content() }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func quiet(_ text: String) -> some View { Text(text).foregroundStyle(.secondary) }

    /// "Running a command" and its command line; the last unfinished step of a working helper is the one running now.
    private func step(_ call: HerdrClient.ToolCall, running: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: call.failed ? "xmark.circle" : call.finished ? "checkmark.circle" : running ? "circle.dotted" : "circle")
                .font(.system(size: 11)).foregroundStyle(call.failed ? Color.red : .secondary).frame(width: 14)
            Text(ActivityCopy.label(HerdrBackend.toolName(call.tool))).font(.callout)
            if let detail = call.detail, !detail.isEmpty {
                Text(detail).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            }
        }
    }

    /// Every later task the helper was given (`helper send`).
    private func followUps(after task: String?) -> [String] {
        let texts = (log?.tasks ?? []).map(\.text)
        return texts.first == task || task == nil ? Array(texts.dropFirst()) : texts.filter { $0 != task }
    }

    private func follow() async {
        if let listed { helper = listed }
        if let known = store.herdrHelpers[bot.id]?.core { core = known }
        // The helper's own session on the event stream; a server without one, or a stream that breaks, is polled.
        if await followStream() { return }
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
        guard let helper = listed ?? helper, let core else { return }
        do {
            let fresh = try await store.herdrHelperLog(helper.ref, core: core, of: bot)
            guard !Task.isCancelled else { return }
            show(fresh)
        } catch { if log == nil, !Task.isCancelled { problem = error.localizedDescription } }
    }
}
