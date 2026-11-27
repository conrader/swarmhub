import SwiftUI

/// A terminal address can be reused. Native targets always include the launch time, and detached targets
/// keep their host, owner and job identity. Opening a preview never writes to a running session.
struct LiveTerminal: Identifiable, Hashable, Codable {
    enum Source: Hashable, Codable {
        case agent(HerdrClient.AgentRef)
        case codexThread(core: String, owner: HerdrClient.AgentRef, thread: String)
        case claudeThread(core: String, owner: HerdrClient.AgentRef, thread: String)
        case opencodeThread(core: String, owner: HerdrClient.AgentRef, thread: String)
        case geminiThread(core: String, owner: HerdrClient.AgentRef, thread: String)
        case job(host: String, owner: UUID, key: String)

        var child: (runtime: HerdrClient.ChildRuntime, core: String, owner: HerdrClient.AgentRef, thread: String)? {
            switch self {
            case let .codexThread(core, owner, thread): (.codex, core, owner, thread)
            case let .claudeThread(core, owner, thread): (.claude, core, owner, thread)
            case let .opencodeThread(core, owner, thread): (.opencode, core, owner, thread)
            case let .geminiThread(core, owner, thread): (.gemini, core, owner, thread)
            default: nil
            }
        }
    }
    let id: Source
    let title: String
    var detail = ""
    var core: String?

    init(agent: HerdrClient.AgentRef, title: String, detail: String = "", core: String? = nil) {
        id = .agent(agent)
        self.title = title
        self.detail = detail
        self.core = core
    }

    init(thread: HerdrClient.NativeThread, owner: HerdrClient.AgentRef, core: String) {
        id = switch thread.provider {
        case .codex: .codexThread(core: core, owner: owner, thread: thread.id)
        case .claude: .claudeThread(core: core, owner: owner, thread: thread.id)
        case .opencode: .opencodeThread(core: core, owner: owner, thread: thread.id)
        case .gemini: .geminiThread(core: core, owner: owner, thread: thread.id)
        }
        title = thread.name
        detail = thread.sessionDetail
        self.core = core
    }

    init(host: String, job: HerdrClient.CodejobActivity.Job, botName: String) {
        id = .job(host: host, owner: job.owner, key: job.job)
        title = botName + " · " + job.description
        detail = host + " · " + String(job.job.prefix(8))
    }
}

struct TerminalBrowserRequest: Identifiable, Hashable, Codable {
    var id = UUID()
    let server: HerdrServer
    var target: LiveTerminal?
    var groupID: UUID?
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct ChatTerminalPreviewButton: View {
    @EnvironmentObject private var store: AppStore
    let server: HerdrServer
    let target: LiveTerminal
    var beforeOpening: () -> Void = {}

    var body: some View {
        Button {
            beforeOpening()
            store.previewInInspector(.init(server: server, target: target))
        } label: {
            Image(systemName: "eye")
        }
        .buttonStyle(.bordered).controlSize(.small)
        .help("Preview this terminal in Details")
        .accessibilityLabel("Preview " + target.title + " in Details")
    }
}


struct WorkspaceTerminals: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let request: TerminalBrowserRequest
    let docked: Bool
    @Environment(\.openWindow) private var openWindow
    @State private var server: HerdrServer
    @State private var selected: LiveTerminal?
    @State private var terminals: [LiveTerminal] = []
    @State private var problem: String?
    @State private var loaded = false
    @AppStorage("terminalPreviewFitPanel") private var fitPanel = false

    init(request: TerminalBrowserRequest, docked: Bool = false) {
        self.docked = docked
        self.request = request
        _server = State(initialValue: request.server)
        _selected = State(initialValue: request.target)
    }

    private var group: GroupChat? { store.groups.first { $0.id == request.groupID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if selected != nil {
                    Button { selected = nil } label: { Image(systemName: "chevron.left") }
                        .accessibilityLabel("All terminals")
                }
                Text(selected?.title ?? group.map { $0.name + " terminals" } ?? "Live terminals").font(.headline)
                Spacer()
                if selected == nil {
                    Picker("Workspace", selection: Binding(get: { server.id }, set: { id in
                        if let next = store.herdrServer(id: id) { terminals = []; problem = nil; loaded = false; server = next }
                    })) {
                        ForEach(store.herdrServers) { Text($0.name).tag($0.id) }
                    }.labelsHidden().fixedSize()
                } else if !docked { Text(server.name).foregroundStyle(.secondary) }
                if docked {
                    Button {
                        openWindow(value: TerminalBrowserRequest(server: server, target: selected, groupID: request.groupID))
                    } label: { Image(systemName: "macwindow.on.rectangle") }
                        .help("Open terminal preview in a window").accessibilityLabel("Open terminal preview in a window")
                    Button { store.inspectorTerminal = nil } label: { Image(systemName: "xmark") }
                        .help("Back to Details").accessibilityLabel("Back to Details")
                } else { Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            }
            if docked, selected != nil {
                Picker("Terminal text size", selection: $fitPanel) {
                    Text("Readable").tag(false)
                    Text("Fit terminal").tag(true)
                }.pickerStyle(.segmented).labelsHidden().accessibilityLabel("Terminal text size")
            }
            if let selected {
                if let child = selected.id.child {
                    NativeThreadOutput(server: server, runtime: child.runtime, core: child.core, owner: child.owner, thread: child.thread, detail: selected.detail, readable: docked && !fitPanel) {
                        if docked { store.inspectorTerminal = nil } else { dismiss() }
                    }.id(selected.id)
                } else {
                    TerminalOutput(server: server, target: selected, readable: docked && !fitPanel).id(selected.id)
                }
            } else {
                if let problem { Text(problem).foregroundStyle(.secondary) }
                if terminals.isEmpty {
                    if loaded { ContentUnavailableView("No live terminals", systemImage: "terminal") }
                    else if problem == nil { ProgressView("Reading sessions…") }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(terminals) { terminal in
                                Button {
                                    selected = terminal
                                } label: {
                                    HStack {
                                        Image(systemName: "terminal")
                                        VStack(alignment: .leading) {
                                            Text(terminal.title)
                                            Text(terminal.detail).font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                                    }.padding(7).contentShape(Rectangle())
                                }.buttonStyle(.plain).accessibilityLabel("Preview " + terminal.title)
                            }
                        }
                    }
                }
            }
            if selected == nil { Spacer(minLength: 0) }
        }.padding(docked ? 10 : 16)
        .frame(minWidth: docked ? 240 : 540, idealWidth: docked ? 330 : 740, minHeight: docked ? 180 : 320)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(docked ? "inspector.terminal" : "workspace.terminals")
        .task(id: server.id + (selected == nil ? "-list" : "-preview")) {
            guard selected == nil else { return }
            while !Task.isCancelled {
                do {
                    let client = try store.herdrClient(for: server)
                    guard store.herdrServer(id: server.id) == server else { problem = "The workspace connection changed."; return }
                    let roster = try await client.workspace(includingCodejobs: request.groupID == nil)
                    try Task.checkCancellation()
                    terminals = rows(roster)
                    loaded = true
                    problem = nil
                } catch {
                    guard !Task.isCancelled else { return }
                    problem = error.localizedDescription
                }
                do { try await Task.sleep(for: .seconds(4)) } catch { return }
            }
        }
    }

    private func rows(_ roster: HerdrClient.Workspace) -> [LiveTerminal] {
        let agents = roster.agents.filter(\.isLive)
        let byRef = Dictionary(agents.map { ($0.ref, $0) }, uniquingKeysWith: { a, _ in a })
        var names: [String: String] = [:]
        for bot in store.bots where bot.backend == .herdr && store.herdrServer(for: bot) == server {
            if let group {
                guard group.memberIDs.contains(bot.id) else { continue }
                for name in store.approvalAgentNames(for: bot, in: group) { names[name] = bot.name }
            } else {
                names[HerdrBackend.agentName(botName: bot.name, botID: bot.id)] = bot.name
            }
        }
        var results = agents.compactMap { agent -> LiveTerminal? in
            if request.groupID != nil {
                var root = agent
                var seen = Set<HerdrClient.AgentRef>()
                while let parent = root.parent, let next = byRef[parent], seen.insert(parent).inserted { root = next }
                guard names[root.name] != nil else { return nil }
            }
            let parent = agent.parent.flatMap { byRef[$0] }
            let detail = [parent.map { "Helper of " + (names[$0.name] ?? $0.name) }, agent.status?.state, agent.template]
                .compactMap { $0 }.joined(separator: " · ")
            return LiveTerminal(agent: agent.ref, title: names[agent.name] ?? agent.name, detail: detail, core: roster.core)
        }
        let visibleOwners = Set(results.compactMap { terminal -> HerdrClient.AgentRef? in
            if case .agent(let ref) = terminal.id { return ref }
            return nil
        })
        var seenThreads = Set<LiveTerminal.Source>()
        for (parent, list) in store.herdrHelpers where list.core == roster.core && visibleOwners.contains(list.parent) {
            guard let bot = store.bots.first(where: { $0.id == parent.botID }),
                  store.herdrServer(for: bot) == server else { continue }
            for thread in list.nativeThreads where thread.state == "working" {
                let entry = LiveTerminal(thread: thread, owner: list.parent, core: list.core)
                if seenThreads.insert(entry.id).inserted { results.append(entry) }
            }
        }
        for host in roster.codejobActivity?.hosts ?? [] where request.groupID == nil {
            for job in host.jobs where job.isWorking {
                let name = store.bots.first { $0.id == job.owner }?.name ?? "Worker"
                results.append(LiveTerminal(host: host.host, job: job, botName: name))
            }
        }
        return results.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}

private struct TerminalOutput: View {
    @EnvironmentObject private var store: AppStore
    let server: HerdrServer
    let target: LiveTerminal
    let readable: Bool
    private struct Mirror { let url: URL; let token: String; let ref: HerdrClient.AgentRef; let core: String? }
    @State private var mirror: Mirror?
    @State private var output: String?
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let problem { Text(problem).font(.callout).foregroundStyle(.secondary) }
            if !readable, let mirror {
                TerminalMirror(url: mirror.url, token: mirror.token, agent: mirror.ref, core: mirror.core) { problem = $0 }
            } else if let output {
                TerminalTextGrid(output: output, readable: readable)
            } else if problem == nil { ProgressView("Connecting…") }
        }.task(id: readable) {
            mirror = nil
            problem = nil
            while !Task.isCancelled {
                do {
                    guard store.herdrServer(id: server.id) == server else {
                        problem = "The workspace connection changed."
                        return
                    }
                    let client = try store.herdrClient(for: server)
                    let text: String
                    switch target.id {
                    case .agent(let ref):
                        let roster = try await client.workspace()
                        try Task.checkCancellation()
                        guard (target.core == nil || roster.core == target.core), roster.agents.contains(where: { $0.ref == ref && $0.isLive }) else {
                            problem = "This terminal session has ended."
                            return
                        }
                        if !readable, roster.terminalPreview == true {
                            let url = try await client.connectedBaseURL().appendingPathComponent("terminal-preview")
                            try Task.checkCancellation()
                            mirror = Mirror(url: url, token: client.token, ref: ref, core: roster.core)
                            return
                        }
                        text = try await client.screen(of: ref)
                    case .codexThread, .claudeThread, .opencodeThread, .geminiThread: return
                    case .job(let host, let owner, let key):
                        struct Tail: Decodable { let text: String? }
                        let tail: Tail = try await client.get("/api/codejobs/\(host)/\(owner.uuidString.lowercased())/\(key)/output")
                        guard let tail = tail.text else { problem = "The worker has ended or its output is unavailable."; return }
                        text = tail
                    }
                    try Task.checkCancellation()
                    output = text
                    problem = nil
                } catch {
                    guard !Task.isCancelled else { return }
                    problem = error.localizedDescription
                }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }
}
