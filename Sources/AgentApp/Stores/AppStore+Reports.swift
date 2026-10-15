import Foundation

/// P36: bots report bugs and feature requests to SwarmHub. A bot's `report` op (any Hermes bot's reply) makes a pending
/// row; the manager's quiet listing turn brings the box's unsent files (body, versions); Send posts to `/v1/reports`
/// with this Mac's install key (or the optional sign-in's token), Dismiss forgets it, and either way the manager closes the box file in a quiet turn.
/// Nothing is sent without Konrad's press.
extension AppStore {
    var swarmHubService: SwarmHubService {
        let raw = defaults.string(forKey: SwarmHubService.baseURLKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let url = URL(string: raw).flatMap { ["https", "http"].contains($0.scheme ?? "") ? $0 : nil } ?? URL(string: SwarmHubService.defaultBaseURL)!
        return SwarmHubService(baseURL: url, session: reportsCenter.session)
    }

    var appVersionText: String { AppBuildInfo.current().version }

    /// `report` ops of a finished reply: pending rows, then the listing turn fetches their bodies.
    func handleReportOps(_ reply: ChatMessage, from bot: Bot) {
        guard bot.backend == .hermes, !bot.isDemo, let ops = SwarmhubBlock.ops(in: reply.content) else { return }
        let target = connection(of: bot); var added = false
        for case .report(let id, let kind, let title) in ops {
            reportsCenter.inbox.absorbOp(id: id, kind: kind, title: title, bot: bot.hermesProfile ?? "default", connection: target, now: now()); added = true
        }
        guard added else { return }
        Task { await fetchBoxReports(on: target) }
    }

    /// `reports` (listing) and `reports_closed` ops; always true so it can sit in a guard chain.
    @discardableResult func absorbReportOps(_ ops: [SwarmhubOp], connection target: String) -> Bool {
        for op in ops {
            switch op {
            case .boxReports(let rows): reportsCenter.inbox.absorbBox(rows, connection: target, now: now())
            case .reportsClosed(let sent, let deleted): reportsCenter.inbox.boxClosed(sent: sent, deleted: deleted)
            default: continue
            }
        }
        if ops.contains(where: { if case .boxReports = $0 { true } else { false } }), !reportsCenter.closing.contains(target) {
            let work = reportsCenter.inbox.boxWork(on: target)
            if !(work.sent + work.deleted).isEmpty { Task { await closeBoxReports(on: target) } }
        }
        return true
    }

    func fetchBoxReports(on target: String) async {
        guard let manager = ensureManager(on: target) else { return }
        await discoverBox(manager: manager)
    }

    /// The manager renames sent files to `.sent` and deletes dismissed ones (one quiet turn per connection at a time).
    func closeBoxReports(on target: String) async {
        let work = reportsCenter.inbox.boxWork(on: target)
        guard !(work.sent + work.deleted).isEmpty, reportsCenter.closing.insert(target).inserted else { return }
        defer { reportsCenter.closing.remove(target) }
        guard let manager = ensureManager(on: target), manager.backend == .hermes, let template = managerRecipeTemplate(.box),
              let instructions = BoxAdoption.closeReportsInstructions(template: template, managerProfile: manager.hermesProfile ?? "default", sent: work.sent, deleted: work.deleted),
              let backend = try? backend(for: manager),
              let ops = await quietBoxTurn(backend, persona: manager.persona, request: "Close SwarmHub reports on this box.", instructions: instructions) else { return }
        absorbReportOps(ops, connection: target)
    }

    /// The bot a report came from (its avatar in the inbox); nil for Konrad's own or an unknown profile.
    func reportBot(_ report: SwarmReport) -> Bot? {
        guard report.source == .agent, let profile = report.bot else { return nil }
        return bots.first { $0.backend == .hermes && !$0.isReadOnlyArchive && ($0.hermesProfile ?? "default") == profile && (report.connection == nil || connection(of: $0) == report.connection) }
    }

    // MARK: Inbox actions

    func openReports(select id: String? = nil) {
        showingReports = true
        if let id { reportsCenter.selectedID = id } else if reportsCenter.selectedID == nil { reportsCenter.selectedID = reportsCenter.inbox.visible.first?.id }
        Task { await refreshReportStatuses() }
    }

    /// Help → "Report a problem…": a new report of Konrad's own, prefilled without keys or bot names.
    @discardableResult func startUserReport() -> SwarmReport {
        let kinds = Array(Set(bots.filter { !$0.isDemo && $0.backend != .mock }.map(\.backend.shortName))).sorted()
        let report = ReportPrefill.make(appVersion: appVersionText, macOS: ReportPrefill.macOSVersion(), connectionKinds: kinds, now: now())
        reportsCenter.inbox.add(report)
        openReports(select: report.id)
        return report
    }

    /// Send to SwarmHub (no sign-in needed): posts with the install key or the token, stores the server id and status,
    /// closes the box file.
    func sendReport(_ id: String) async {
        let center = reportsCenter
        guard let report = center.inbox.report(id), report.state == .pending, center.sendingID == nil else { return }
        guard let payload = ReportPayload(report, appVersion: appVersionText) else { center.lastError = "Add a title and a description first."; return }
        center.sendingID = id; center.lastError = nil
        defer { center.sendingID = nil }
        let service = swarmHubService
        do {
            let result = try await center.withReportsAuth(service: service, now: now()) { try await service.postReport(payload, auth: $0) }
            center.inbox.markSent(id, serverID: result.id, status: result.status, now: now())
            if let target = report.connection, report.boxFile == .present { Task { await closeBoxReports(on: target) } }
        } catch let error as SwarmHubError {
            center.lastError = error == .unauthorized ? "SwarmHub did not accept this Mac's report key. Try again later." : error.message
        } catch { center.lastError = error.localizedDescription }
    }

    func dismissReport(_ id: String) {
        guard let report = reportsCenter.inbox.report(id) else { return }
        reportsCenter.inbox.dismiss(id)
        if reportsCenter.selectedID == id { reportsCenter.selectedID = reportsCenter.inbox.visible.first?.id }
        if let target = report.connection, report.boxFile == .present { Task { await closeBoxReports(on: target) } }
    }

    /// Opening the inbox: the status and note of every sent report (same auth as Send; never registers an install).
    func refreshReportStatuses() async {
        let center = reportsCenter
        guard center.inbox.reports.contains(where: { $0.serverID != nil }), !center.refreshing,
              center.token(at: now()) != nil || center.storedInstall != nil else { return }
        center.refreshing = true; defer { center.refreshing = false }
        let service = swarmHubService
        if let rows = try? await center.withReportsAuth(service: service, now: now(), { try await service.listReports(auth: $0) }) { center.inbox.applyStatuses(rows) }
    }
}
