import SwiftUI

struct HerdrRoutinesPanel: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.timeZone) private var timeZone
    @ObservedObject var bot: Bot
    let server: HerdrServer

    @State private var routines: [HerdrClient.Routine]?
    @State private var sessions: HerdrRoutineSessions?
    @State private var checkins: [HerdrClient.BotCheckin] = []
    @State private var listError: String?
    @State private var sessionError: String?
    @State private var checkinError: String?
    @State private var actionError: String?
    @State private var loading = false
    @State private var changing = false
    @State private var refresh = 0
    @State private var editing: Editor?
    @State private var deleting: HerdrClient.Routine?
    @State private var expanded: Set<Int64> = []
    @State private var testRuns: [Int64: Int64] = [:]

    private typealias Routine = HerdrClient.Routine

    private enum Editor: Identifiable {
        case new(HerdrClient.AgentRef)
        case edit(Routine)

        var id: Int64 {
            switch self { case .new: 0; case .edit(let routine): routine.id }
        }
    }

    private var agentName: String { HerdrBackend.agentName(botName: bot.name, botID: bot.id) }
    private var visibleRoutines: [Routine] { routinesForBot(routines ?? [], agentName: agentName, sessions: sessions) }
    private var busy: Bool { loading || changing }
    private var liveTarget: HerdrClient.AgentRef? { bot.isReadOnlyArchive ? nil : sessions?.liveTarget }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let actionError {
                StatusCard(kind: .warning, title: "Routine action failed", detail: actionError) {}
            }
            routineList
            if let sessionError, listError == nil {
                StatusCard(kind: .warning, title: "Couldn’t check for a live session", detail: sessionError) {
                    Button("Try again", action: reload).disabled(busy)
                }
            } else if routines != nil, listError == nil, liveTarget == nil, !bot.isReadOnlyArchive {
                Text("Send this bot a message to start a session, then refresh to create a routine.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            checkinSection
        }
        .task(id: refresh) { await load() }
        .sheet(item: $editing) { editor in
            switch editor {
            case .new(let target):
                HerdrRoutineEditor(routine: nil, displayZone: timeZone) { edit in
                    update(try await client().createRoutine(edit, target: target))
                }
            case .edit(let routine):
                HerdrRoutineEditor(routine: routine, displayZone: timeZone) { edit in
                    update(try await client().editRoutine(routine.id, edit))
                }
            }
        }
        .confirmationDialog("Delete routine?", isPresented: Binding(
            get: { deleting != nil },
            set: { if !$0 { deleting = nil } }
        ), titleVisibility: .visible, presenting: deleting) { routine in
            Button("Delete Routine", role: .destructive) {
                change { update(try await $0.controlRoutine(routine.id, .archive)) }
            }
        } message: { routine in
            Text("The server will archive “\(routine.name)” and stop future runs.")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Routines").font(.headline).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 4)
            Button("New routine", systemImage: "plus") {
                if let liveTarget { editing = .new(liveTarget) }
            }
            .disabled(busy || listError != nil || routines == nil || liveTarget == nil)
            .help(liveTarget == nil ? "A live bot session is required" : "New routine")
            Button("Refresh", systemImage: "arrow.clockwise", action: reload)
                .labelStyle(.iconOnly).help("Refresh routines and check-ins").disabled(busy)
        }
        .controlSize(.small)
    }

    @ViewBuilder private var routineList: some View {
        if let listError {
            StatusCard(kind: .warning, title: "Routines unavailable", detail: listError) {
                Button("Try again", action: reload).disabled(busy)
            }
        } else if routines == nil || (visibleRoutines.isEmpty && loading) {
            StatusCard(kind: .working, title: "Loading routines…") {}
        } else if visibleRoutines.isEmpty {
            StatusCard(kind: .info, title: "No routines yet",
                       detail: "Routines send instructions to this bot’s session on a schedule. They run on the workspace server, even when the app is closed.") {}
        } else {
            ForEach(visibleRoutines) { routine in routineCard(routine) }
        }
    }

    private func routineCard(_ routine: Routine) -> some View {
        let isLive = sessions?.isLive(routine)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 6) {
                Text(routine.name).font(.headline).frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                if routine.state == .paused {
                    FactChip(text: "Paused", symbol: "pause")
                } else if isLive == false {
                    FactChip(text: "Needs session", colour: AppColor.caution)
                } else {
                    FactChip(text: "Active", colour: AppColor.good)
                }
            }
            Text(routine.schedule.summary(in: timeZone)).font(.callout).foregroundStyle(.secondary)
            if let next = routine.nextAt {
                Text("Next run \(routineDate(next, in: timeZone))").font(.caption).foregroundStyle(.secondary)
            }
            if isLive == false {
                Text("The original session has ended or is no longer connected.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Run now", systemImage: "play") {
                    change { client in
                        let run = try await client.testRoutine(routine.id)
                        testRuns[routine.id] = run.id
                        expanded.insert(routine.id)
                    }
                }
                .disabled(isLive != true)
                Spacer()
                Menu {
                    Button(routine.state == .paused ? "Resume" : "Pause") {
                        change { update(try await $0.controlRoutine(routine.id, routine.state == .paused ? .resume : .pause)) }
                    }
                    Button("Edit…") { editing = .edit(routine) }
                    Divider()
                    Button("Delete…", role: .destructive) { deleting = routine }
                } label: {
                    Label("Routine actions", systemImage: "ellipsis").labelStyle(.iconOnly)
                }
                .fixedSize()
                .help("Routine actions")
            }
            .controlSize(.small)
            .disabled(busy || bot.isReadOnlyArchive)
            HerdrRoutineHistory(id: routine.id, isExpanded: Binding(
                get: { expanded.contains(routine.id) },
                set: { if $0 { expanded.insert(routine.id) } else { expanded.remove(routine.id) } }
            ), refresh: refresh, testRun: testRuns[routine.id], client: client)
        }
        .appleCard(padding: 10)
    }

    @ViewBuilder private var checkinSection: some View {
        if !checkins.isEmpty || checkinError != nil && checkinError != listError {
            SettingBlock(title: "Check-ins") {
                if let checkinError, checkinError != listError {
                    StatusCard(kind: .warning, title: "Check-ins unavailable", detail: checkinError) {
                        Button("Try again", action: reload).disabled(busy)
                    }
                }
                ForEach(checkins) { checkin in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(checkin.what).font(.callout.weight(.medium))
                        if checkin.schedule.kind == "ci", let url = checkin.schedule.url {
                            Text("Watching CI").font(.caption).foregroundStyle(.secondary)
                            Text(url).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        } else if let next = checkin.nextMs {
                            Text("Next check-in \(routineDate(next, in: timeZone))").font(.caption).foregroundStyle(.secondary)
                        }
                        if checkin.paused { FactChip(text: "Paused", symbol: "pause") }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .appleCard(padding: 10)
                }
            }
        }
    }

    private func client() throws -> HerdrClient { try store.herdrClient(for: server) }

    private func reload() {
        actionError = nil
        refresh += 1
    }

    private func load() async {
        loading = true
        defer { if !Task.isCancelled { loading = false } }
        do {
            let client = try client()
            async let list: Void = loadRoutines(client)
            async let bindings: Void = loadSessions(client)
            async let plans: Void = loadCheckins(client)
            _ = await (list, bindings, plans)
        } catch {
            if !Task.isCancelled { listError = error.localizedDescription }
        }
    }

    private func loadRoutines(_ client: HerdrClient) async {
        do {
            let fetched = try await client.routines()
            try Task.checkCancellation()
            routines = fetched
            listError = nil
        } catch HerdrClient.Failure.http(404, _) {
            if !Task.isCancelled { listError = "This workspace server doesn’t provide routines. Check the server version and try again." }
        } catch {
            if !Task.isCancelled { listError = error.localizedDescription }
        }
    }

    private func loadSessions(_ client: HerdrClient) async {
        async let profiles = try? client.profiles()
        let workspace: HerdrClient.Workspace?
        do {
            workspace = try await client.workspace()
            if !Task.isCancelled { sessionError = nil }
        } catch {
            workspace = nil
            if !Task.isCancelled { sessionError = error.localizedDescription }
        }
        let bindings = await HerdrRoutineSessions(agentName: agentName, workspace: workspace, profiles: profiles ?? [])
        if !Task.isCancelled { sessions = bindings }
    }

    private func loadCheckins(_ client: HerdrClient) async {
        do {
            let fetched = try await client.botCheckins(bot.id)
            try Task.checkCancellation()
            checkins = fetched
            checkinError = nil
        } catch HerdrClient.Failure.http(404, _) {
            // An older workspace or a bot that has not joined its team yet.
            if !Task.isCancelled { checkins = []; checkinError = nil }
        } catch {
            if !Task.isCancelled { checkinError = error.localizedDescription }
        }
    }

    private func update(_ routine: Routine) {
        if let index = routines?.firstIndex(where: { $0.id == routine.id }) { routines?[index] = routine }
        else { routines?.insert(routine, at: 0) }
    }

    private func change(_ operation: @escaping (HerdrClient) async throws -> Void) {
        guard !busy else { return }
        changing = true
        actionError = nil
        Task {
            defer { changing = false }
            do { try await operation(client()) }
            catch { actionError = error.localizedDescription }
        }
    }
}

private struct HerdrRoutineHistory: View {
    @Environment(\.timeZone) private var timeZone
    let id: Int64
    @Binding var isExpanded: Bool
    let refresh: Int
    let testRun: Int64?
    let client: () throws -> HerdrClient
    @State private var runs: [HerdrClient.RoutineRun]?
    @State private var error: String?
    @State private var retry = 0

    private struct Load: Equatable {
        let expanded: Bool
        let refresh: Int
        let testRun: Int64?
        let retry: Int
    }

    var body: some View {
        DisclosureGroup("Recent runs", isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                if let error {
                    Text(error).foregroundStyle(.secondary)
                    Button("Try again") { retry += 1 }
                } else if let runs {
                    if runs.isEmpty { Text("No runs yet.").foregroundStyle(.secondary) }
                    ForEach(runs) { run in
                        Divider()
                        runRow(run)
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
        }
        .font(.caption)
        .task(id: Load(expanded: isExpanded, refresh: refresh, testRun: testRun, retry: retry)) {
            if isExpanded { await load() }
        }
    }

    private func runRow(_ run: HerdrClient.RoutineRun) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(runKind(run.kind)) · \(stateLabel(run.state))").fontWeight(.medium)
            Text(routineDate(run.atMs, in: timeZone)).foregroundStyle(.secondary)
            if let detail = run.detail { Text(detail).foregroundStyle(.secondary) }
            if let result = run.result {
                Text("Outcome · \(stateLabel(result.state))").fontWeight(.medium)
                Text(result.summary).textSelection(.enabled)
            } else if run.awaitingResult == true {
                Text("Waiting for a result").foregroundStyle(.secondary)
            }
        }
    }

    private func runKind(_ kind: String) -> String {
        switch kind {
        case "schedule": "Scheduled"
        case "test": "Run now"
        default: kind.capitalized
        }
    }

    private func stateLabel(_ state: String) -> String {
        switch state {
        case "pending": "Sending…"
        case "sent": "Sent to bot"
        default: state.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private func load() async {
        error = nil
        do {
            let client = try client()
            for poll in 0..<100 {
                if poll > 0 { try await Task.sleep(for: .seconds(3)) }
                try Task.checkCancellation()
                let detail = try await client.routine(id)
                try Task.checkCancellation()
                runs = detail.runs
                guard detail.runs.contains(where: { $0.state == "pending" || $0.awaitingResult == true }) else { return }
            }
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }
}

private func routineDate(_ ms: Int64, in timeZone: TimeZone) -> String {
    Date(timeIntervalSince1970: Double(ms) / 1_000)
        .formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: timeZone))
}
