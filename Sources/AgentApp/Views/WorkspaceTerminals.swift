import SwiftUI

/// A terminal address can be reused. Native targets always include the launch time, and detached targets
/// keep their host, owner and job identity. Opening a preview never writes to a running session.
struct LiveTerminal: Identifiable, Equatable {
    enum Source: Hashable {
        case agent(HerdrClient.AgentRef)
        case job(host: String, owner: UUID, key: String)
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

    init(host: String, job: HerdrClient.CodejobActivity.Job, botName: String) {
        id = .job(host: host, owner: job.owner, key: job.job)
        title = botName + " · " + job.description
        detail = host + " · " + String(job.job.prefix(8))
    }
}

struct TerminalBrowserRequest: Identifiable {
    let id = UUID()
    let server: HerdrServer
    var target: LiveTerminal?
    var group: GroupChat?
}

struct WorkspaceTerminals: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let request: TerminalBrowserRequest
    @State private var server: HerdrServer
    @State private var selected: LiveTerminal?
    @State private var terminals: [LiveTerminal] = []
    @State private var problem: String?
    @State private var loaded = false

    init(request: TerminalBrowserRequest) {
        self.request = request
        _server = State(initialValue: request.server)
        _selected = State(initialValue: request.target)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if selected != nil {
                    Button { selected = nil } label: { Image(systemName: "chevron.left") }
                        .accessibilityLabel("All terminals")
                }
                Text(selected?.title ?? request.group.map { $0.name + " terminals" } ?? "Live terminals").font(.headline)
                Spacer()
                if selected == nil {
                    Picker("Workspace", selection: Binding(get: { server.id }, set: { id in
                        if let next = store.herdrServer(id: id) { terminals = []; problem = nil; loaded = false; server = next }
                    })) {
                        ForEach(store.herdrServers) { Text($0.name).tag($0.id) }
                    }.labelsHidden().fixedSize()
                } else { Text(server.name).foregroundStyle(.secondary) }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let selected {
                TerminalOutput(server: server, target: selected).id(selected.id)
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
            Spacer(minLength: 0)
        }.padding().frame(minWidth: 540, idealWidth: 740, minHeight: 320, idealHeight: 480)
        .task(id: server.id + (selected == nil ? "-list" : "-preview")) {
            guard selected == nil else { return }
            while !Task.isCancelled {
                do {
                    let client = try store.herdrClient(for: server)
                    let roster = try await client.workspace(includingCodejobs: request.group == nil)
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
            if let group = request.group {
                guard group.memberIDs.contains(bot.id) else { continue }
                for name in store.approvalAgentNames(for: bot, in: group) { names[name] = bot.name }
            } else {
                names[HerdrBackend.agentName(botName: bot.name, botID: bot.id)] = bot.name
            }
        }
        var results = agents.compactMap { agent -> LiveTerminal? in
            if request.group != nil {
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
        for host in roster.codejobActivity?.hosts ?? [] where request.group == nil {
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
    @State private var output: String?
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let problem { Text(problem).font(.callout).foregroundStyle(.secondary) }
            if let output {
                ScrollView([.horizontal, .vertical]) {
                    Text(verbatim: output.isEmpty ? "Waiting for output…" : output)
                        .font(.system(.callout, design: .monospaced)).textSelection(.enabled).padding(12)
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(AppColor.chat, in: RoundedRectangle(cornerRadius: 6))
            } else if problem == nil { ProgressView("Connecting…") }
        }.task {
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
                        text = try await client.screen(of: ref)
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
