import CoreGraphics
import Foundation

/// Off-app alerts, per server (Settings → Advanced → Appearance and alerts). Each click is one `swarmctl alerts panel`
/// call (Hermes on this Mac: a subprocess; a box: one paired terminal call in a deleted session, `swarmctlBoxTurn`).
/// The no-double-alert rule (docs/offapp-alerts.md): while SwarmHub runs and its user has touched this Mac in the last
/// `presenceIdle` seconds, it keeps a presence lease on each server with alerts on (a paused routine, written through the
/// jobs API every `presenceRenewal` for `presenceLease`); the box sends nothing while the lease is fresh. Quit ends it.
extension AppStore {
    static let presenceRenewal: TimeInterval = 120, presenceLease: TimeInterval = 300, presenceIdle: TimeInterval = 600
    /// recsfix2/3: an automatic push the box did not confirm is tried again after this long, doubling up to the cap.
    static let profilesRetry: TimeInterval = 900, profilesRetryCap: TimeInterval = 6 * 3600

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

    /// recsfix1 (#14): the profiles the box may alert for: those of the live Hermes agents this Mac connected on the
    /// server. Sent with every save and whenever it changes (`syncAlertProfiles`), so the box drops a profile disconnected
    /// since (and knows none it was never told of).
    func alertProfiles(on target: String) -> [String] {
        Set(bots.filter { $0.backend == .hermes && !$0.isDemo && !$0.isReadOnlyArchive && !$0.isGrokHistoryOnly && !$0.retiredOnBox
            && connection(of: $0) == target }.map(profile(of:))).sorted()
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
    /// starts (or stops) its service. A box key not read yet costs one status call first. `runner`: the agent that runs
    /// the command when the server has none left (`syncAlertProfiles` after the last one was deleted or retired).
    /// `ifRevision` (recsfix3): an automatic push, applied by the box only over that revision of its settings; this Mac
    /// keeps its settings only once the box took them. False when the box holds newer ones (another Mac's), which win.
    @discardableResult func saveAlerts(_ settings: AlertSettings, ntfyToken: String, emailPassword: String, on target: String, via runner: Bot? = nil,
                                       ifRevision: Int? = nil) async -> Bool {
        guard !settings.enabled || settings.hasSink else { boxAlerts.update(target) { $0.error = AlertsCopy.needSink }; return false }
        if ifRevision == nil {
            defaults.set(try? JSONEncoder().encode(settings), forKey: "alerts.settings." + target)
            keyStore.setKey(ntfyToken, for: Self.alertSecretAccount("ntfy", target: target))
            keyStore.setKey(emailPassword, for: Self.alertSecretAccount("smtp", target: target))
        }
        var boxKey = boxAlerts.state(for: target).panel?.boxKey
        if boxKey == nil { boxKey = await performAlerts(.status, on: target, via: runner)?.boxKey }
        guard let boxKey else { return false }
        let blob: String, profiles = alertProfiles(on: target)
        do { blob = try AlertSeal.seal(settings.boxJSON(ntfyToken: ntfyToken, emailPassword: emailPassword, profiles: profiles, ifRevision: ifRevision), to: boxKey) }
        catch { boxAlerts.update(target) { $0.error = (error as? BoxAlertsError)?.errorDescription ?? AlertsCopy.sealFailed }; return false }
        guard let panel = await performAlerts(.configure(blob), on: target, secrets: [ntfyToken, emailPassword], via: runner) else { return false }
        if panel.result?.stale == true { boxAlerts.update(target) { $0.notice = AlertsCopy.newerOnBox }; return false }
        if ifRevision != nil { defaults.set(try? JSONEncoder().encode(settings), forKey: "alerts.settings." + target) }
        defaults.set(profiles, forKey: "alerts.profiles." + target)  // The list the box now holds (`syncAlertProfiles`).
        defaults.set(panel.config.revision ?? 0, forKey: "alerts.revision." + target)  // The box's settings are this Mac's.
        if var push = alertPushes[target] {  // Owed no more, unless the agents changed while it went.
            if profiles == alertProfiles(on: target) { alertPushes[target] = nil } else { push.next = .distantPast; alertPushes[target] = push }
        }
        boxAlerts.presenceWritten[target] = nil  // The lease goes out at the next poll tick.
        boxAlerts.update(target) { state in
            if let reason = panel.result?.error { state.notice = AlertsCopy.serviceError(ToolEvent.redacted(reason)) }
            else { state.notice = panel.config.enabled ? AlertsCopy.saved : AlertsCopy.off }
        }
        return true
    }

    /// Runs one action; the state shows the box's answer or why it is missing. Nil when nothing was confirmed. Every answer
    /// (a refresh too) records whether the box's alerts are on now: another Mac may have changed them.
    @discardableResult func performAlerts(_ action: BoxAlertsAction, on target: String, secrets: [String] = [], via runner: Bot? = nil) async -> BoxAlertsPanel? {
        guard boxAlerts.state(for: target).busy == nil else { return nil }
        guard let bot = runner ?? alertRunner(for: target) else { boxAlerts.update(target) { $0.error = AlertsCopy.noRunner }; return nil }
        guard let arguments = AlertsCommand.arguments(action) else { boxAlerts.update(target) { $0.error = AlertsCopy.sealFailed }; return nil }
        boxAlerts.update(target) { $0.busy = action; $0.error = nil; $0.notice = nil }
        do {
            let panel = try await runAlertsPanel(arguments, for: bot)
            boxAlerts.update(target) { $0.busy = nil; $0.panel = panel }
            defaults.set(panel.config.enabled, forKey: "alerts.on." + target)
            defaults.set(panel.config.revision ?? 0, forKey: "alerts.boxRevision." + target)
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

    // MARK: Profile allowlist

    /// recsfix2 (#14): the box's allowlist follows this Mac's connections, not only a save. On each server with alerts on
    /// whose settings this Mac saved, when the connected profiles differ from the list last sent (a bot connected,
    /// archived, retired or deleted; or settings saved by 0.6.5, which sent none), the saved settings go again with the
    /// new list. recsfix3: a push stays owed (`alertPushes`, kept across launches) until the box confirms it, retried with
    /// backoff, also for a server with no agent left: there it is a revocation (alerts off), run by the bot that left.
    /// Every automatic push names the box's revision this Mac saved; when the box holds newer settings (another Mac's,
    /// seen in any answer or refused by the box), nothing is pushed and nothing stays owed: the newer settings win.
    func syncAlertProfiles(now: Date = .now) async {
        let servers = alertServers
        let targets = servers + alertPushes.keys.sorted().filter { !servers.contains($0) }
        for target in targets {
            let owed = alertPushes[target]
            guard defaults.data(forKey: "alerts.settings." + target) != nil, alertSettingsAreNewest(on: target) else {
                if owed != nil { alertPushes[target] = nil }
                continue
            }
            let profiles = alertProfiles(on: target)
            var settings = alertSettings(for: target)
            guard owed != nil || (settings.enabled && defaults.stringArray(forKey: "alerts.profiles." + target) != profiles) else { continue }
            var push = owed ?? AlertsPush()
            guard now >= push.next else { continue }
            push.attempts += 1
            push.next = now.addingTimeInterval(min(Self.profilesRetry * pow(2, Double(push.attempts - 1)), Self.profilesRetryCap))
            alertPushes[target] = push  // Owed before it is tried: a quit or a failure meanwhile retries it.
            if profiles.isEmpty { settings.enabled = false }  // No agent of this Mac left there: alerts off.
            let runner = alertRunner(for: target) == nil ? push.runner?.bot : nil
            await saveAlerts(settings, ntfyToken: alertSecret("ntfy", target: target), emailPassword: alertSecret("smtp", target: target),
                             on: target, via: runner, ifRevision: defaults.integer(forKey: "alerts.revision." + target))
            if !alertSettingsAreNewest(on: target) { alertPushes[target] = nil }
        }
    }

    /// The box's settings are the ones this Mac saved last (no other Mac saved since), as far as its answers tell.
    func alertSettingsAreNewest(on target: String) -> Bool {
        defaults.integer(forKey: "alerts.boxRevision." + target) == defaults.integer(forKey: "alerts.revision." + target)
    }

    /// recsfix3: the automatic pushes still owed, per server (UserDefaults, no secret).
    var alertPushes: [String: AlertsPush] {
        get { defaults.data(forKey: "alerts.pushes").flatMap { try? JSONDecoder().decode([String: AlertsPush].self, from: $0) } ?? [:] }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "alerts.pushes") }
    }

    /// A deleted or retired (archived) Hermes bot: its server's settings are owed at once, not at the next tick; when it
    /// was the server's last agent, it runs the revocation (no tick reaches a server without agents).
    func alertProfilesLeft(_ bot: Bot) {
        let target = connection(of: bot)
        guard bot.backend == .hermes, defaults.bool(forKey: "alerts.on." + target), defaults.data(forKey: "alerts.settings." + target) != nil else { return }
        var push = alertPushes[target] ?? AlertsPush()
        push.next = .distantPast
        if alertRunner(for: target) == nil { push.runner = AlertsPush.Runner(bot) }
        alertPushes[target] = push
        Task { await syncAlertProfiles() }
    }

    // MARK: Presence lease

    /// The routine poll's tick: the allowlist follows the connections, and while the user is at this Mac, each server
    /// with alerts on gets its lease renewed.
    func renewAlertPresenceIfDue(now: Date = .now) async {
        await syncAlertProfiles(now: now)
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

/// recsfix3: an automatic push of a server's alert settings still owed to the box: how often it was tried, when it may
/// be tried again, and the bot to run it with when the server has no agent left (the one deleted or retired last).
struct AlertsPush: Codable, Equatable {
    struct Runner: Codable, Equatable {
        var name: String, profile: String?, baseURL: String?
        init(_ bot: Bot) { name = bot.name; profile = bot.hermesProfile; baseURL = bot.hermesBaseURL }
        var bot: Bot { let bot = Bot(name: name, backend: .hermes, hermesProfile: profile); bot.hermesBaseURL = baseURL; return bot }
    }
    var attempts = 0
    var next = Date.distantPast
    var runner: Runner?
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
