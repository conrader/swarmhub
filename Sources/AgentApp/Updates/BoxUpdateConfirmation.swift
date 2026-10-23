import Foundation

extension AppStore {
    func canConfirmBoxCode(_ confirmation: BoxUpdateState.Confirmation, for bot: Bot) -> Bool {
        guard connection(of: bot) == confirmation.connection, boxCodeConfirmation(for: bot) == confirmation,
              let manager = manager(for: bot), isIdle(manager),
              !boxInstallTransport.refreshing.contains(confirmation.connection),
              boxInstallTransport.attempts[manager.id] == nil else { return false }
        // Confirmation needs the operator's bootstrap record, but never reads or fetches the update source.
        return (try? boxInstallTransport.box(on: confirmation.connection)) != nil
    }

    /// Called only by the per-box button. No view task, refresh, install-all or model reply calls this method.
    func confirmBoxCode(_ confirmation: BoxUpdateState.Confirmation, for bot: Bot) async {
        guard canConfirmBoxCode(confirmation, for: bot), let manager = manager(for: bot) else { return }
        await runBoxUpdaterTurn(manager: manager, target: confirmation.connection, confirmation: confirmation)
    }

    /// Same native management-turn transport as staged installation/status refresh, with persisted session cleanup.
    /// Capture the destination before suspending: edits to a bot's connection cannot redirect an in-flight click.
    func runBoxUpdaterTurn(manager: Bot, target: String, confirmation: BoxUpdateState.Confirmation?) async {
        guard confirmation == nil || confirmation?.connection == target,
              connection(of: manager) == target, !boxInstallTransport.refreshing.contains(target), isIdle(manager),
              boxInstallTransport.attempts[manager.id] == nil else { return }
        guard let backend = try? backend(for: manager) as? HermesBackend else {
            if confirmation != nil { errorMessage = "Code update is unconfirmed: the box connection is unavailable." }
            return
        }
        boxInstallTransport.refreshing.insert(target)
        if confirmation != nil { boxInstallTransport.confirming.insert(target); errorMessage = nil }
        objectWillChange.send()
        defer {
            boxInstallTransport.refreshing.remove(target)
            boxInstallTransport.confirming.remove(target)
            objectWillChange.send()
        }
        await cleanUpdaterSessions(on: target, backend: backend)
        guard (defaults.stringArray(forKey: "updates.transport.cleanup." + target) ?? []).isEmpty else {
            if confirmation != nil { errorMessage = "Temporary updater session cleanup is pending; retry when the box is reachable." }
            return
        }
        let session = "\(sessionNamespace)agentapp_update_status_\(UUID().uuidString.lowercased())"
        let key = "updates.transport.cleanup." + target
        defaults.set((defaults.stringArray(forKey: key) ?? []) + [session], forKey: key)
        var confirmCall = confirmation.map(BoxUpdateConfirmCall.init)
        do {
            try Task.checkCancellation()
            guard try await backend.sessionTransport() == .nativeSessions else {
                throw StagedInstall.Failure.refused("native Hermes sessions required")
            }
            _ = try await backend.createSession(title: "", systemPrompt: manager.outboundPersona, id: session)
            let instructions: String
            if let confirmation {
                instructions = """
                The user clicked \(confirmation.title). This confirms only bundle \(confirmation.version) on this box.
                Run exactly this in one terminal call:
                ```sh
                \(confirmation.command)
                ```
                Then run exactly this as a separate terminal call:
                ```sh
                \(StagedInstall.statusCommand)
                ```
                Never retry with another version or on another box. Do not stage, fetch or pull anything.
                Do not modify Hermes, enable plugins or restart anything. Do not emit skills_installed.
                A reply cannot establish success; report pending_confirm, deferral, failure or reload_pending.
                """
            } else {
                instructions = "Run exactly this in one terminal call: \(StagedInstall.statusCommand). Do not change anything."
            }
            let stream = try await backend.send(.init(sessionID: session, systemPrompt: manager.outboundPersona,
                messages: [(role: "user", content: confirmation?.title ?? "Read the installed SwarmHub skill versions.")],
                managementText: instructions))
            var call = UpdaterStatusCall()
            for try await event in stream {
                switch event {
                case .tool(let tool):
                    let status: BoxUpdaterStatus?
                    if confirmCall != nil {
                        status = confirmCall?.consume(tool, previous: boxInstallTransport.status[target])
                    } else { status = call.consume(tool) }
                    if let status {
                        noteBoxUpdaterStatus(status, on: target)
                        // A mutable bot must still belong to the captured destination before recording its skills.
                        if connection(of: manager) == target, confirmCall == nil || confirmCall?.succeeded == true {
                            recordUpdaterSkills(status, manager: manager)
                        }
                    }
                case .approval(let approval):
                    try? await backend.resolveApproval(approval, approved: false)
                    throw StagedInstall.Failure.refused("updater turn requested approval")
                case .failed: throw StagedInstall.Failure.refused("updater turn failed")
                default: break
                }
            }
            if let confirmCall {
                if let failure = confirmCall.failure {
                    boxInstallTransport.status[target] = failure
                    errorMessage = failure.detail
                } else if !confirmCall.succeeded {
                    errorMessage = "No matching updater status received; code update is unconfirmed. Refresh before retrying."
                } else if boxInstallTransport.status[target]?.reload_pending == true {
                    errorMessage = "Code update applied. Reload pending."
                }
            }
        } catch {
            _ = await Task { try? await backend.cancel(sessionID: session) }.value
            if confirmation != nil { errorMessage = "Code update is unconfirmed: \(error.localizedDescription)" }
        }
        if Task.isCancelled { _ = await Task { try? await backend.cancel(sessionID: session) }.value }
        await Task { await self.cleanUpdaterSessions(on: target, backend: backend) }.value
    }
}
