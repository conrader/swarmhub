import Foundation

/// The operator places box-transport.json in the Mac update directory after deterministic bootstrap. No model
/// operation writes this configuration. A missing record retains the legacy installer; an unreadable record fails closed.
@MainActor final class BoxInstallTransport {
    let configurationURL: URL
    init(configurationURL: URL) { self.configurationURL = configurationURL }
    var boxes: [String: StagedInstall.Box]? // synthetic boxes in app tests
    struct Attempt {
        let package: StagedInstall.Package
        var call = UpdaterStatusCall()
        var status: BoxUpdaterStatus?
    }
    var attempts: [UUID: Attempt] = [:]
    var status: [String: BoxUpdaterStatus] = [:]

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
        guard let box = try boxInstallTransport.box(on: target) else { throw StagedInstall.Failure.refused("operator record unavailable") }
        let key = "updates.transport.floor." + target
        let saved = try defaults.data(forKey: key).map { try JSONDecoder().decode(StagedInstall.Floor.self, from: $0) } ?? .init()
        let package = try StagedInstall.prepare(box: box, saved: saved, profiles: profiles, now: ISO8601DateFormatter().string(from: now()))
        let instructions = try StagedInstall.instructions(package)
        // Raise before sending, even if delivery fails. A retry may reuse only this exact manifest.
        defaults.set(try JSONEncoder().encode(package.floor), forKey: key)
        boxInstallTransport.attempts[manager.id] = .init(package: package)
        return instructions
    }

    func noteStagedSkillTool(_ tool: ToolEvent, manager: Bot) {
        guard var attempt = boxInstallTransport.attempts[manager.id] else { return }
        if let status = attempt.call.consume(tool) {
            attempt.status = status
            boxInstallTransport.status[connection(of: manager)] = status
            if status.accepted(attempt.package) { recordUpdaterSkills(status, manager: manager) }
        }
        boxInstallTransport.attempts[manager.id] = attempt
    }

    func finishStagedSkillInstall(manager: Bot) {
        guard let attempt = boxInstallTransport.attempts.removeValue(forKey: manager.id) else { return }
        guard let status = attempt.status, status.accepted(attempt.package) else {
            errorMessage = attempt.status?.detail ?? "No matching updater status received; skill installation is unconfirmed."
            return
        }
        let installed = attempt.package.profiles.allSatisfy { profile in
            guard let live = status.profiles[profile.name] else { return false }
            return profile.skills.allSatisfy {
                (live.advertised[$0] ?? nil) == attempt.package.versions[$0] &&
                ($0 != "swarmhub-coding" || live.variants?[$0] == profile.coding_order)
            }
        }
        if !installed || status.state != "current" || status.reload_pending {
            errorMessage = "Updater: \(status.state). \(status.detail)" +
                (!installed ? " Requested skills are not yet confirmed." : "") + (status.reload_pending ? " Reload pending." : "")
        }
    }

    func recordUpdaterSkills(_ status: BoxUpdaterStatus, manager: Bot) {
        for (profile, live) in status.profiles {
            guard let bot = boundBot(profile, manager: manager) else { continue }
            bot.installedSkills = SkillLibrary.updaterVersions(live.advertised, names: Set(skills(for: bot).map(\.name)))
            bot.installedSkillVariants = (live.variants ?? [:]).filter { bot.installedSkills[$0.key] != nil }
        }
        objectWillChange.send(); save()
    }

    /// Read-back uses a fresh management turn's terminal status, never the assistant's summary or /v1/skills.
    func refreshStagedSkills(for bot: Bot) async {
        guard let manager = manager(for: bot), isIdle(manager), let backend = try? backend(for: manager) else { return }
        let session = "\(sessionNamespace)agentapp_update_status_\(UUID().uuidString.lowercased())"
        do {
            if try await backend.sessionTransport() == .nativeSessions {
                _ = try await backend.createSession(title: "SwarmHub updater status", systemPrompt: manager.persona, id: session)
            }
            let stream = try await backend.send(.init(sessionID: session, systemPrompt: manager.persona,
                messages: [(role: "user", content: "Read the installed SwarmHub skill versions.")],
                managementText: "Run exactly this in one terminal call: \(StagedInstall.statusCommand). Do not change anything."))
            var call = UpdaterStatusCall()
            for try await event in stream {
                switch event {
                case .tool(let tool):
                    if let status = call.consume(tool) {
                        boxInstallTransport.status[connection(of: manager)] = status
                        recordUpdaterSkills(status, manager: manager)
                    }
                case .approval(let approval): try? await backend.resolveApproval(approval, approved: false); return
                case .failed: return
                default: break
                }
            }
        } catch { /* Unreachable box: keep the last reading and direct app ↔ box routing. */ }
    }
}
