import AppKit
import SwiftUI

struct HerdrRoutinesPanel: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.timeZone) private var timeZone
    @ObservedObject var bot: Bot
    let server: HerdrServer
    var inInspector = false

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
    @State private var rotating: HerdrClient.Routine?
    @State private var keyRequest: UUID?
    @State private var revealedKey: RevealedKey?
    @State private var expanded: Set<Int64> = []
    @State private var activityRevisions: [Int64: Int] = [:]

    private typealias Routine = HerdrClient.Routine

    private struct RevealedKey {
        let routineID: Int64
        let text: String
    }

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
                StatusCard(kind: .warning, title: "Routine action failed", detail: actionError, inInspector: inInspector) {}
            }
            routineList
            if let sessionError, listError == nil {
                StatusCard(kind: .warning, title: "Couldn’t check for a live session", detail: sessionError, inInspector: inInspector) {
                    Button("Try again", action: reload).disabled(busy)
                }
            } else if routines != nil, listError == nil, liveTarget == nil, !bot.isReadOnlyArchive {
                Text("Send this bot a message to start a session, then refresh to create a routine.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            checkinSection
        }
        .task(id: refresh) { await load() }
        .onDisappear {
            keyRequest = nil
            revealedKey = nil
            rotating = nil
        }
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
        .alert("Rotate webhook key?", isPresented: Binding(
            get: { rotating != nil },
            set: { if !$0 { rotating = nil } }
        ), presenting: rotating) { routine in
            Button("Rotate key", role: .destructive) { rotateKey(for: routine) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Senders using the previous key will need the new one.")
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
            StatusCard(kind: .warning, title: "Routines unavailable", detail: listError, inInspector: inInspector) {
                Button("Try again", action: reload).disabled(busy)
            }
        } else if routines == nil || (visibleRoutines.isEmpty && loading) {
            StatusCard(kind: .working, title: "Loading routines…", inInspector: inInspector) {}
        } else if visibleRoutines.isEmpty {
            StatusCard(kind: .info, title: "No routines yet",
                       detail: "Routines send instructions to this bot’s session on a schedule. They run on the workspace server, even when the app is closed.", inInspector: inInspector) {}
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
                        _ = try await client.testRoutine(routine.id)
                        expanded.insert(routine.id)
                        refreshActivity(routine.id)
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
            if case .webhook(let source, _, _) = routine.schedule {
                webhookSettings(routine, source: source)
            }
            HerdrRoutineActivity(routine: routine, isExpanded: Binding(
                get: { expanded.contains(routine.id) },
                set: { if $0 { expanded.insert(routine.id) } else { expanded.remove(routine.id) } }
            ), refresh: refresh, revision: activityRevisions[routine.id, default: 0],
               canApprove: routine.state == .active && isLive == true,
               actionsDisabled: busy || bot.isReadOnlyArchive, client: client) { reviewID, decision in
                change { client in
                    defer { refreshActivity(routine.id) }
                    _ = try await client.resolveRoutineReview(routineID: routine.id, reviewID: reviewID, decision: decision)
                    if decision == .approve { expanded.insert(routine.id) }
                }
            }
        }
        .appleCard(padding: 10, inInspector: inInspector)
    }

    private func webhookSettings(_ routine: Routine, source: HerdrClient.RoutineSchedule.Source?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Text("Webhook endpoint").font(.caption.weight(.semibold))
            if let url = HerdrClient.routineWebhookURL(serverAddress: server.address, id: routine.id, source: source) {
                CopyBox(text: url.absoluteString, copyLabel: "Copy URL", copiedLabel: "Copied", lineLimit: 2)
                if let host = url.host(percentEncoded: false)?.lowercased(),
                   ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host) {
                    Text("External services need a reachable relay or tunnel to this server.").foregroundStyle(.secondary)
                }
            }
            switch source {
            case .slack:
                Text("Subscribe to app mentions and forward signed Events API requests here.").foregroundStyle(.secondary)
            case .github:
                Text("Use the key as GitHub’s webhook secret. Send JSON with the original GitHub delivery headers.")
                    .foregroundStyle(.secondary)
            case nil:
                Text("Send the key as a Bearer token and include a unique Idempotency-Key for each event.")
                    .foregroundStyle(.secondary)
            }
            if source != .slack {
                HStack {
                    Text(routine.webhookReady ? "Key set" : "No key yet").foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button(routine.webhookReady ? "Rotate key" : "Generate key") {
                        if routine.webhookReady { rotating = routine } else { rotateKey(for: routine) }
                    }
                    .disabled(busy || bot.isReadOnlyArchive)
                }
            }
            if let revealedKey, revealedKey.routineID == routine.id {
                StatusCard(kind: .info, title: "New webhook key", detail: "Copy this key before hiding it.", inInspector: inInspector) {
                    Text(verbatim: revealedKey.text).font(.system(.caption, design: .monospaced))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Copy key") { copyWebhookKey(revealedKey.text) }
                        Button("Hide key") { self.revealedKey = nil }
                    }
                }
            }
        }
        .font(.caption)
        .controlSize(.small)
    }

    private func rotateKey(for routine: Routine) {
        guard !busy, !bot.isReadOnlyArchive else { return }
        let request = UUID()
        keyRequest = request
        revealedKey = nil
        change { client in
            defer { if keyRequest == request { keyRequest = nil } }
            let result = try await client.rotateRoutineWebhookKey(id: routine.id)
            if let index = routines?.firstIndex(where: { $0.id == routine.id }) {
                routines?[index].webhookReady = true
            }
            // A response may arrive after the user leaves the tab.
            guard keyRequest == request else { return }
            revealedKey = RevealedKey(routineID: routine.id, text: result.key)
        }
    }

    private func copyWebhookKey(_ key: String) {
        let item = NSPasteboardItem()
        item.setString(key, forType: .string)
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item])
    }

    @ViewBuilder private var checkinSection: some View {
        if !checkins.isEmpty || checkinError != nil && checkinError != listError {
            SettingBlock(title: "Check-ins") {
                if let checkinError, checkinError != listError {
                    StatusCard(kind: .warning, title: "Check-ins unavailable", detail: checkinError, inInspector: inInspector) {
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
                    .appleCard(padding: 10, inInspector: inInspector)
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
            if let revealedKey, !fetched.contains(where: { $0.id == revealedKey.routineID && $0.webhookReady }) {
                self.revealedKey = nil
            }
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
        if revealedKey?.routineID == routine.id, !routine.webhookReady { revealedKey = nil }
        refreshActivity(routine.id)
    }

    private func refreshActivity(_ id: Int64) { activityRevisions[id, default: 0] += 1 }

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

private struct HerdrRoutineActivity: View {
    @Environment(\.timeZone) private var timeZone
    let routine: HerdrClient.Routine
    @Binding var isExpanded: Bool
    let refresh: Int
    let revision: Int
    let canApprove: Bool
    let actionsDisabled: Bool
    let client: () throws -> HerdrClient
    let resolve: (Int64, HerdrClient.RoutineReviewDecision) -> Void
    @State private var detail: HerdrClient.RoutineDetail?
    @State private var loadedRevision: Int?
    @State private var error: String?
    @State private var retry = 0

    private struct Load: Equatable {
        let expanded: Bool
        let refresh: Int
        let revision: Int
        let retry: Int
    }

    private var isWebhook: Bool {
        if case .webhook = routine.schedule { return true }
        return false
    }

    private var reviewEnabled: Bool {
        if case .webhook(_, _, let enabled) = routine.schedule { return enabled }
        return false
    }

    private var reviews: [HerdrClient.RoutineReview] { detail?.reviews ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if case .webhook(.slack, _, _) = routine.schedule, let slackReady = detail?.slackReady {
                Text(slackReady ? "Slack signing is configured." : "Slack signing needs a workspace credential.")
                    .foregroundStyle(.secondary)
            }
            if isWebhook, error != nil {
                loadError
            }
            if isWebhook && (reviewEnabled || !reviews.isEmpty) {
                reviewQueue
            }
            history
        }
        .font(.caption)
        .task(id: Load(expanded: isExpanded, refresh: refresh, revision: revision, retry: retry)) {
            if isWebhook || isExpanded { await load() }
        }
    }

    private var history: some View {
        DisclosureGroup("Recent runs", isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                if !isWebhook && error != nil {
                    loadError
                } else if let detail {
                    if detail.runs.isEmpty { Text("No runs yet.").foregroundStyle(.secondary) }
                    ForEach(detail.runs) { run in
                        Divider()
                        runRow(run)
                    }
                } else if error == nil {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
        }
    }

    @ViewBuilder private var loadError: some View {
        if let error {
            Text(error).foregroundStyle(.secondary)
            Button("Try again") { retry += 1 }.controlSize(.small)
        }
    }

    private var reviewQueue: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Text("Pending webhook reviews").fontWeight(.semibold).accessibilityAddTraits(.isHeader)
            if detail == nil && error == nil {
                ProgressView().controlSize(.small)
            } else if detail != nil && reviews.isEmpty {
                Text("No events awaiting review.").foregroundStyle(.secondary)
            }
            ForEach(reviews) { review in
                Divider()
                reviewRow(review)
            }
        }
    }

    private func reviewRow(_ review: HerdrClient.RoutineReview) -> some View {
        let summary = [review.payload?["event"]?.stringValue, review.payload?["action"]?.stringValue]
            .compactMap { $0 }.joined(separator: " · ")
        let pendingRun = detail?.runs.contains { $0.state == "pending" } == true
        return VStack(alignment: .leading, spacing: 4) {
            DisclosureGroup {
                Text(verbatim: payloadText(review.payload))
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.isEmpty ? "Webhook event" : summary).fontWeight(.medium).lineLimit(1)
                    Text("Received \(routineDate(review.atMs, in: timeZone))").foregroundStyle(.secondary)
                }
            }
            if review.stale {
                Text("This routine changed after the event arrived. You can dismiss the event.").foregroundStyle(.secondary)
            } else if routine.state == .paused {
                Text("Resume the routine before approving events.").foregroundStyle(.secondary)
            } else if !canApprove || pendingRun {
                Text("Approval requires an available bot session.").foregroundStyle(.secondary)
            }
            HStack {
                Button("Approve & run") { resolve(review.id, .approve) }
                    .disabled(!canApprove || pendingRun || review.stale)
                Button("Dismiss") { resolve(review.id, .dismiss) }
            }
            .controlSize(.small)
            .disabled(actionsDisabled || loadedRevision != revision || error != nil)
        }
    }

    private func payloadText(_ payload: JSONValue?) -> String {
        guard let payload else { return "No JSON payload." }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(payload) else { return "Couldn’t display the JSON payload." }
        return String(decoding: data, as: UTF8.self)
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
            var remainingRunPolls = 99
            while !Task.isCancelled {
                try Task.checkCancellation()
                let fetched = try await client.routine(routine.id)
                try Task.checkCancellation()
                detail = fetched
                loadedRevision = revision
                if isExpanded && remainingRunPolls > 0 && fetched.runs.contains(where: { $0.state == "pending" || $0.awaitingResult == true }) {
                    remainingRunPolls -= 1
                    try await Task.sleep(for: .seconds(3))
                } else if isWebhook && (reviewEnabled || !(fetched.reviews ?? []).isEmpty) {
                    try await Task.sleep(for: .seconds(5))
                } else {
                    return
                }
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
