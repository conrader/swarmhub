import CoreGraphics
import Foundation

/// Off-app alerts, per server (Settings → Advanced → Appearance and alerts). Each click is one `swarmctl alerts panel`
/// call (Hermes on this Mac: a subprocess; a box: one paired terminal call in a deleted session, `swarmctlBoxTurn`).
/// The no-double-alert rule (docs/offapp-alerts.md): while SwarmHub runs and its user has touched this Mac in the last
/// `presenceIdle` seconds, it keeps a presence lease on each server with alerts on (a paused routine, written through the
/// jobs API every `presenceRenewal` for `presenceLease`); the box sends nothing while the lease is fresh. Quit ends it.
extension AppStore {
    static let presenceRenewal: TimeInterval = 120, presenceLease: TimeInterval = 300, presenceIdle: TimeInterval = 600

    // MARK: Settings (no secret in UserDefaults)

    func alertSettings(for target: String) -> AlertSettings {
        guard let data = defaults.data(forKey: "alerts.settings." + target),
              let settings = try? JSONDecoder().decode(AlertSettings.self, from: data) else { return AlertSettings() }
        return settings
    }

    static func alertSecretAccount(_ kind: String, target: String) -> String { "swarmhub.alerts.\(kind).\(target)" }
    func alertSecret(_ kind: String, target: String) -> String { keyStore.key(for: Self.alertSecretAccount(kind, target: target)) }

    /// The servers whose alerts the box last accepted as on: the ones that get a presence lease.
    var alertServers: [String] { hermesConnections.map(\.target).filter { defaults.bool(forKey: "alerts.on." + $0) } }

    /// The agent that runs the pane's command on a server: its first live Hermes agent.
    func alertRunner(for target: String) -> Bot? {
        bots.first { $0.backend == .hermes && !$0.isDemo && !$0.isReadOnlyArchive && !$0.isGrokHistoryOnly && !$0.retiredOnBox
            && connection(of: $0) == target }
    }

    /// Hermes on this Mac answers without a model turn, so the section may load itself.
    func alertsAreLocal(_ target: String) -> Bool { alertRunner(for: target).map(webhooksAreLocal) ?? false }

    // MARK: Actions

    func refreshAlerts(on target: String) async { _ = await performAlerts(.status, on: target) }

    func sendTestAlert(on target: String) async {
        guard let panel = await performAlerts(.test, on: target), let sinks = panel.result?.sinks else { return }
        boxAlerts.update(target) { $0.notice = AlertsCopy.testResult(sinks.mapValues { ToolEvent.redacted($0) }) }
    }

    func turnOffAlerts(on target: String) async {
        var settings = alertSettings(for: target)
        settings.enabled = false
        await saveAlerts(settings, ntfyToken: alertSecret("ntfy", target: target), emailPassword: alertSecret("smtp", target: target), on: target)
    }

    /// Keeps the settings (secrets in the Keychain), seals them to the box's key and sends them; the box saves them and
    /// starts (or stops) its service. A box key not read yet costs one status call first.
    func saveAlerts(_ settings: AlertSettings, ntfyToken: String, emailPassword: String, on target: String) async {
        guard !settings.enabled || settings.hasSink else { boxAlerts.update(target) { $0.error = AlertsCopy.needSink }; return }
        defaults.set(try? JSONEncoder().encode(settings), forKey: "alerts.settings." + target)
        keyStore.setKey(ntfyToken, for: Self.alertSecretAccount("ntfy", target: target))
        keyStore.setKey(emailPassword, for: Self.alertSecretAccount("smtp", target: target))
        var boxKey = boxAlerts.state(for: target).panel?.boxKey
        if boxKey == nil { boxKey = await performAlerts(.status, on: target)?.boxKey }
        guard let boxKey else { return }
        let blob: String
        do { blob = try AlertSeal.seal(settings.boxJSON(ntfyToken: ntfyToken, emailPassword: emailPassword), to: boxKey) }
        catch { boxAlerts.update(target) { $0.error = (error as? BoxAlertsError)?.errorDescription ?? AlertsCopy.sealFailed }; return }
        guard let panel = await performAlerts(.configure(blob), on: target, secrets: [ntfyToken, emailPassword]) else { return }
        boxAlerts.presenceWritten[target] = nil  // The lease goes out at the next poll tick.
        boxAlerts.update(target) { state in
            if let reason = panel.result?.error { state.notice = AlertsCopy.serviceError(ToolEvent.redacted(reason)) }
            else { state.notice = panel.config.enabled ? AlertsCopy.saved : AlertsCopy.off }
        }
    }

    /// Runs one action; the state shows the box's answer or why it is missing. Nil when nothing was confirmed. Every answer
    /// (a refresh too) records whether the box's alerts are on now: another Mac may have changed them.
    @discardableResult func performAlerts(_ action: BoxAlertsAction, on target: String, secrets: [String] = []) async -> BoxAlertsPanel? {
        guard boxAlerts.state(for: target).busy == nil else { return nil }
        guard let bot = alertRunner(for: target) else { boxAlerts.update(target) { $0.error = AlertsCopy.noRunner }; return nil }
        guard let arguments = AlertsCommand.arguments(action) else { boxAlerts.update(target) { $0.error = AlertsCopy.sealFailed }; return nil }
        boxAlerts.update(target) { $0.busy = action; $0.error = nil; $0.notice = nil }
        do {
            let panel = try await runAlertsPanel(arguments, for: bot)
            boxAlerts.update(target) { $0.busy = nil; $0.panel = panel }
            defaults.set(panel.config.enabled, forKey: "alerts.on." + target)
            return panel
        } catch {
            let reason = BotInfoCache.describe(error, secrets: secrets.filter { !$0.isEmpty })
            boxAlerts.update(target) { $0.busy = nil; $0.error = reason }
            return nil
        }
    }

    func runAlertsPanel(_ arguments: [String], for bot: Bot) async throws -> BoxAlertsPanel {
        if let alertsControl { return try BoxAlertsPanel.decode(try await alertsControl(bot, arguments)) }
        if webhooksAreLocal(bot) {
            let home = managedHome ?? FileManager.default.homeDirectoryForCurrentUser
            do { return try BoxAlertsPanel.decode(try await Self.localSwarmctl(arguments, profile: bot.hermesProfile ?? "default", home: home)) }
            catch LocalSwarmctlError.missing { throw WebhookPanelError.unavailable(AlertsCopy.skillMissing) }
            catch LocalSwarmctlError.failed(let problem, let exit) { throw BoxAlertsError.refusal(problem, exit: exit) }
        }
        return try await swarmctlBoxTurn(arguments, for: bot, as: BoxAlertsCall.self, kind: "alerts", request: AlertsCopy.turnRequest,
                                         nativeSessions: AlertsCopy.nativeSessions).panel()
    }

    // MARK: Presence lease

    /// The routine poll's tick: while the user is at this Mac, each server with alerts on gets its lease renewed.
    func renewAlertPresenceIfDue(now: Date = .now) async {
        guard boxAlerts.idleSeconds() < Self.presenceIdle else { return }
        for target in alertServers {
            if let last = boxAlerts.presenceWritten[target], now.timeIntervalSince(last) < Self.presenceRenewal { continue }
            boxAlerts.presenceWritten[target] = now
            await writePresence(until: now.addingTimeInterval(Self.presenceLease), on: target)
        }
    }

    /// Best effort: a lease that cannot be written lapses, and the box alerts (a duplicate beats a missed alert).
    func writePresence(until: Date, on target: String) async {
        guard let bot = alertRunner(for: target), let client = try? jobsClient(for: bot) else { return }
        let prompt = PresenceLease.prompt(until: until)
        do {
            if let id = boxAlerts.presenceJobs[target] {
                do { _ = try await client.update(id, prompt: prompt); return }
                catch HermesJobsError.notFound { boxAlerts.presenceJobs[target] = nil }
            }
            if let existing = try await client.listAll().first(where: { $0.name == PresenceLease.jobName }) {
                boxAlerts.presenceJobs[target] = existing.id
                _ = try await client.update(existing.id, prompt: prompt)
                return
            }
            let created = try await client.create(name: PresenceLease.jobName, schedule: PresenceLease.schedule, prompt: prompt)
            boxAlerts.presenceJobs[target] = created.id
            _ = try? await client.pause(created.id)
        } catch {}
    }

    /// Quit: each known lease is set to an instant in the past, so the box alerts at once. (Plans for `handOffAutomations`.)
    var presenceEndings: [(client: HermesJobsClient, id: String)] {
        alertServers.compactMap { target in
            guard let id = boxAlerts.presenceJobs[target], let bot = alertRunner(for: target), let client = try? jobsClient(for: bot) else { return nil }
            return (client, id)
        }
    }
}

/// The app's presence lease on a box: a paused routine the alert service reads (`swarm_alerts_hermes.presence_until`).
enum PresenceLease {
    static let jobName = "swarmhub-presence"
    /// Once a year, and paused: it never runs; if someone resumes it, it answers `[SILENT]` (no card, no alert).
    static let schedule = "0 0 1 1 *"
    static func prompt(until: Date) -> String {
        "Swarm Hub presence lease: do nothing and reply exactly [SILENT]. until=\(max(0, Int(until.timeIntervalSince1970)))"
    }

    /// Routines SwarmHub keeps for itself: the lease and the loops and goals it handed to the box while closed.
    static func isInternal(_ name: String) -> Bool {
        name == jobName || name.range(of: #"\Aswarmhub-(loop|goal)-[0-9a-f]{8}\z"#, options: .regularExpression) != nil
    }
}

extension BoxAlertsCache {
    /// Seconds since the last keyboard, mouse or trackpad event in this login session.
    nonisolated static func systemIdleSeconds() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }
}
