import Foundation

/// How a webhook panel call reaches the agent's profile: an injected runner (tests), a subprocess for Hermes on this
/// Mac (no model, like `ManagedLocalControl`), or one terminal call in a throwaway session on the box, the native
/// management-turn transport the box updater's status read uses. The command carries names and a key digest only.
extension AppStore {
    func runWebhookPanel(_ arguments: [String], for bot: Bot) async throws -> WebhookPanel {
        if let webhookControl { return try WebhookPanel.decode(try await webhookControl(bot, arguments)) }
        if webhooksAreLocal(bot) {
            return try await Self.localWebhookPanel(arguments, profile: bot.hermesProfile ?? "default",
                                                    home: managedHome ?? FileManager.default.homeDirectoryForCurrentUser)
        }
        return try await webhookBoxTurn(arguments, for: bot)
    }

    nonisolated static func localWebhookPanel(_ arguments: [String], profile: String, home: URL) async throws -> WebhookPanel {
        try await Task.detached {
            let root = home.appending(path: ".hermes")
            let profileRoot = profile == "default" ? root : root.appending(path: "profiles/\(profile)")
            let control = profileRoot.appending(path: "skills/\(SkillLibrary.category)/swarmhub-messages/scripts/swarmctl")
            guard FileManager.default.fileExists(atPath: control.path) else { throw WebhookPanelError.unavailable(WebhookCopy.skillMissing) }
            let process = Process(), output = Pipe(), errors = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", "-B", control.path] + arguments
            process.environment = ["HOME": home.path, "PATH": "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin",
                                   "PYTHONDONTWRITEBYTECODE": "1", "HERMES_HOME": profileRoot.path]
            process.standardOutput = output; process.standardError = errors; process.standardInput = FileHandle.nullDevice
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let problem = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw WebhookPanelError.refusal(String(decoding: problem.prefix(4096), as: UTF8.self), exit: Int(process.terminationStatus))
            }
            return try WebhookPanel.decode(String(decoding: data, as: UTF8.self))
        }.value
    }

    /// The agent that manages the box runs the call (else the agent itself), in a session that is deleted afterwards.
    func webhookBoxTurn(_ arguments: [String], for bot: Bot) async throws -> WebhookPanel {
        let target = connection(of: bot), runner = manager(for: bot) ?? bot
        guard connection(of: runner) == target, isIdle(runner), !boxInstallTransport.refreshing.contains(target) else {
            throw WebhookPanelError.busy
        }
        let runnerProfile = runner.hermesProfile ?? "default"
        guard WebhookCommand.validName(runnerProfile), let backend = try? backend(for: runner) as? HermesBackend else {
            throw WebhookPanelError.unavailable(WebhookCopy.boxUnavailable)
        }
        // One temporary-session turn per box at a time: session cleanup deletes every listed id, so an updater turn or
        // another webhook call on this box must not run (and clean up) while this session is still open.
        boxInstallTransport.refreshing.insert(target)
        objectWillChange.send()
        defer { boxInstallTransport.refreshing.remove(target); objectWillChange.send() }
        await cleanUpdaterSessions(on: target, backend: backend)
        let key = "updates.transport.cleanup." + target
        guard (defaults.stringArray(forKey: key) ?? []).isEmpty else { throw WebhookPanelError.unavailable(WebhookCopy.cleanupPending) }
        let session = "\(sessionNamespace)agentapp_update_webhooks_\(UUID().uuidString.lowercased())"
        defaults.set((defaults.stringArray(forKey: key) ?? []) + [session], forKey: key)
        let command = WebhookCommand.line(
            script: SkillLibrary.installPath("swarmhub-messages", profile: runnerProfile) + "/scripts/swarmctl",
            arguments: arguments)
        var call = WebhookPanelCall(command: command)
        var failure: Error?
        do {
            guard try await backend.sessionTransport() == .nativeSessions else { throw WebhookPanelError.unavailable(WebhookCopy.nativeSessions) }
            _ = try await backend.createSession(title: "", systemPrompt: runner.outboundPersona, id: session)
            let instructions = """
            Run exactly this in one terminal call:
            ```sh
            \(command)
            ```
            Do not run anything else, retry, or change the command. Do not read or print any key file. Reply only "done".
            """
            let stream = try await backend.send(.init(sessionID: session, systemPrompt: runner.outboundPersona,
                messages: [(role: "user", content: WebhookCopy.turnRequest)], managementText: instructions))
            for try await event in stream {
                switch event {
                case .tool(let tool): call.consume(tool)
                case .approval(let approval):
                    try? await backend.resolveApproval(approval, approved: false)
                    throw WebhookPanelError.approvalRequested
                case .failed: throw WebhookPanelError.noAnswer
                default: break
                }
            }
        } catch {
            failure = error
            _ = await Task { try? await backend.cancel(sessionID: session) }.value
        }
        // A cancelled stream must not cancel its cleanup; the box's own answer wins over a later stream error.
        await Task { await self.cleanUpdaterSessions(on: target, backend: backend) }.value
        if call.outcome != nil || failure == nil { return try call.panel() }
        throw failure ?? WebhookPanelError.noAnswer
    }
}
