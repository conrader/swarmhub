import Foundation

/// The operator places box-transport.json in the Mac update directory after deterministic bootstrap. No model
/// operation writes this configuration. A missing record retains the legacy installer; an unreadable record fails closed.
@MainActor final class BoxInstallTransport {
    let configurationURL: URL
    init(configurationURL: URL) { self.configurationURL = configurationURL }
    var boxes: [String: StagedInstall.Box]? // synthetic boxes in app tests
    struct Attempt {
        let package: StagedInstall.Package
        let transfer: StagedTransfer
        let command: String
        var stageCallID: String?
        var staged = false
        var call = UpdaterStatusCall()
        var status: BoxUpdaterStatus?
    }
    var attempts: [UUID: Attempt] = [:]
    var status: [String: BoxUpdaterStatus] = [:]
    var refreshing: Set<String> = []
    var confirming: Set<String> = []

    func box(on connection: String) throws -> StagedInstall.Box? {
        if let boxes { return boxes[connection] }
        let url = configurationURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode([String: StagedInstall.Box].self, from: Data(contentsOf: url))[connection]
    }
}

extension AppStore {
    /// A corrupt operator record must never switch a bootstrapped connection back to raw shell installation.
    func usesStagedSkills(on connection: String) -> Bool {
        let key = "updates.transport.bootstrapped." + connection
        do {
            if try boxInstallTransport.box(on: connection) != nil { defaults.set(true, forKey: key); return true }
            return defaults.bool(forKey: key)
        } catch { return true }
    }

    func stagedSkillInstructions(manager: Bot, profiles: [StagedInstall.Profile]) throws -> String? {
        let target = connection(of: manager)
        guard !boxInstallTransport.refreshing.contains(target) else { throw StagedInstall.Failure.refused("status refresh running") }
        guard let box = try boxInstallTransport.box(on: target) else { throw StagedInstall.Failure.refused("operator record unavailable") }
        let key = "updates.transport.floor." + target
        let saved = try defaults.data(forKey: key).map { try JSONDecoder().decode(StagedInstall.Floor.self, from: $0) } ?? .init()
        let package = try StagedInstall.prepare(box: box, saved: saved, profiles: profiles, now: ISO8601DateFormatter().string(from: now()))
        // The destination merges profiles.json with saved selections and rerenders them together. Filtering the
        // incoming skills would still reapply a saved skill in backoff, even in a profile omitted from this request.
        // Defer while any skill on this connection backs off at this bundle's version. Retain every selection and
        // the signed bundle's version decisions when the request can go through.
        for bot in bots where bot.backend == .hermes && !bot.isReadOnlyArchive && connection(of: bot) == target {
            for name in bot.skillInstallFailures.keys.sorted() {
                guard let version = package.versions[name], stagedSkillBackingOff(name, version: version, bot: bot),
                      let failure = bot.skillInstallFailures[name] else { continue }
                errorMessage = "Signed skill install deferred: \(self.profile(of: bot))/\(name) is backing off until \(failure.retryAt.formatted()). Signed skill installs run together."
                return nil
            }
        }
        let transfer = try StagedTransfer(package, namespace: sessionNamespace)
        let profile = manager.hermesProfile ?? "default"
        let devModes = stagedDevModes(on: target)
        let instructions = try StagedInstall.instructions(transfer, profile: profile, devModes: devModes)
        let command = try StagedInstall.command(transfer, profile: profile, devModes: devModes)
        guard command.utf8.count <= 32_768 else { throw StagedInstall.Failure.refused("transfer exceeds command budget") }
        // Raise before sending, even if delivery fails. A retry may reuse only this exact manifest.
        defaults.set(try JSONEncoder().encode(package.floor), forKey: key)
        boxInstallTransport.attempts[manager.id] = .init(package: package, transfer: transfer,
                                                       command: command)
        return instructions
    }

    /// Skill dev mode for every bot the app knows on this connection, by profile: the box merge applies it to each
    /// saved row, so a signed install for one bot carries (and never drops) the toggle of the others.
    func stagedDevModes(on target: String) -> [String: Bool] {
        var modes: [String: Bool] = [:]
        for bot in bots where bot.backend == .hermes && !bot.isReadOnlyArchive && connection(of: bot) == target {
            modes[profile(of: bot)] = modes[profile(of: bot)] == true || bot.skillDevMode
        }
        return modes
    }

    func noteStagedSkillTool(_ tool: ToolEvent, manager: Bot) {
        guard var attempt = boxInstallTransport.attempts[manager.id] else { return }
        if tool.phase == .started, tool.command == attempt.command {
            attempt.stageCallID = tool.callID
            attempt.staged = false
            attempt.status = nil
        } else if let id = attempt.stageCallID, tool.callID == id, tool.phase == .completed || tool.phase == .failed {
            attempt.stageCallID = nil
            attempt.staged = tool.phase == .completed && StagedTransfer.completed(tool.result, prefix: attempt.transfer.prefix)
            if !attempt.staged {
                let previous = boxInstallTransport.status[connection(of: manager)]
                let status = StagedTransfer.failure(tool.result, prefix: attempt.transfer.prefix, previous: previous) ??
                    .failure("Transfer failed; no matching completion receipt. Skill installation is unconfirmed.", previous: previous)
                attempt.status = status
                boxInstallTransport.status[connection(of: manager)] = status
            }
        }
        if let status = attempt.call.consume(tool), attempt.staged {
            attempt.status = status
            noteBoxUpdaterStatus(status, on: connection(of: manager))
            if status.accepted(attempt.package) { recordUpdaterSkills(status, manager: manager) }
        }
        boxInstallTransport.attempts[manager.id] = attempt
    }

    func finishStagedSkillInstall(manager: Bot) {
        guard let attempt = boxInstallTransport.attempts.removeValue(forKey: manager.id) else { return }
        guard attempt.staged, let status = attempt.status, status.accepted(attempt.package) else {
            let reason = attempt.status?.detail ?? "No matching updater status received; skill installation is unconfirmed."
            errorMessage = reason
            noteStagedSkillResults(attempt.package, status: nil, reason: reason, manager: manager)
            return
        }
        let installed = attempt.package.profiles.allSatisfy { profile in
            profile.skills.allSatisfy { Self.stagedSkillLanded($0, profile: profile, package: attempt.package, status: status) ||
                Self.stagedSkillKept($0, profile: profile, status: status) }
        }
        noteStagedSkillResults(attempt.package, status: status, reason: "Updater: \(status.state). \(status.detail) Requested skills are not yet confirmed.", manager: manager)
        if !installed || status.state != "current" || status.reload_pending {
            errorMessage = "Updater: \(status.state). \(status.detail)" +
                (!installed ? " Requested skills are not yet confirmed." : "") + (status.reload_pending ? " Reload pending." : "")
        }
    }

    func recordUpdaterSkills(_ status: BoxUpdaterStatus, manager: Bot) {
        for (profile, live) in status.profiles {
            guard let bot = boundBot(profile, manager: manager) else { continue }
            let names = Set(skills(for: bot).map(\.name))
            bot.installedSkills = SkillLibrary.updaterVersions(live.advertised, names: names)
            bot.installedSkillVariants = (live.variants ?? [:]).filter { bot.installedSkills[$0.key] != nil }
            let modified = bot.skillDevMode ? Set(live.modified ?? []).intersection(names) : []
            if modified != bot.skillsModifiedLocally { bot.skillsModifiedLocally = modified }
        }
        objectWillChange.send(); save()
    }

    /// View opens reuse the last reading. Only an explicit refresh spends a model turn, one per connection.
    func refreshStagedSkills(for bot: Bot, onDemand: Bool = false) async {
        guard let manager = manager(for: bot) else { return }
        let target = connection(of: manager)
        if !onDemand {
            if let status = boxInstallTransport.status[target] { recordUpdaterSkills(status, manager: manager) }
            return
        }
        await runBoxUpdaterTurn(manager: manager, target: target, confirmation: nil)
    }
}
