import Foundation

/// A Swarm Hub panel command's terminal call, paired to its result by the server's tool call id
/// (`WebhookPanelCall`, `BoxAlertsCall`).
protocol BoxCommandCall {
    init(command: String)
    var answered: Bool { get }
    mutating func consume(_ tool: ToolEvent)
}

enum LocalSwarmctlError: Error { case missing, failed(String, exit: Int) }

/// The two ways a Swarm Hub panel (Webhooks, Alerts) reaches a profile's `swarmctl` without an API of its own: a
/// subprocess for Hermes on this Mac, or one exact terminal call in a throwaway native session on the box.
extension AppStore {
    nonisolated static func localSwarmctl(_ arguments: [String], profile: String, home: URL) async throws -> String {
        try await Task.detached {
            let root = home.appending(path: ".hermes")
            let profileRoot = profile == "default" ? root : root.appending(path: "profiles/\(profile)")
            let control = profileRoot.appending(path: "skills/\(SkillLibrary.category)/swarmhub-messages/scripts/swarmctl")
            guard FileManager.default.fileExists(atPath: control.path) else { throw LocalSwarmctlError.missing }
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
                throw LocalSwarmctlError.failed(String(decoding: problem.prefix(4096), as: UTF8.self), exit: Int(process.terminationStatus))
            }
            return String(decoding: data, as: UTF8.self)
        }.value
    }

    /// The agent that manages `bot`'s box runs `swarmctl <arguments>` (else the agent itself) in a session named
    /// `agentapp_update_<kind>_…` that is deleted afterwards. Returns the paired call; the box's own answer wins over a
    /// later stream error, and no answer with a stream error throws that error.
    func swarmctlBoxTurn<Call: BoxCommandCall>(_ arguments: [String], for bot: Bot, as _: Call.Type, kind: String,
                                               request: String, nativeSessions: String) async throws -> Call {
        let target = connection(of: bot), runner = manager(for: bot) ?? bot
        guard connection(of: runner) == target, isIdle(runner), !boxInstallTransport.refreshing.contains(target) else {
            throw WebhookPanelError.busy
        }
        let runnerProfile = runner.hermesProfile ?? "default"
        guard WebhookCommand.validName(runnerProfile), let backend = try? backend(for: runner) as? HermesBackend else {
            throw WebhookPanelError.unavailable(WebhookCopy.boxUnavailable)
        }
        // One temporary-session turn per box at a time: session cleanup deletes every listed id, so an updater turn or
        // another panel call on this box must not run (and clean up) while this session is still open.
        boxInstallTransport.refreshing.insert(target)
        objectWillChange.send()
        defer { boxInstallTransport.refreshing.remove(target); objectWillChange.send() }
        await cleanUpdaterSessions(on: target, backend: backend)
        let key = "updates.transport.cleanup." + target
        guard (defaults.stringArray(forKey: key) ?? []).isEmpty else { throw WebhookPanelError.unavailable(WebhookCopy.cleanupPending) }
        let session = "\(sessionNamespace)agentapp_update_\(kind)_\(UUID().uuidString.lowercased())"
        defaults.set((defaults.stringArray(forKey: key) ?? []) + [session], forKey: key)
        let command = WebhookCommand.line(
            script: SkillLibrary.installPath("swarmhub-messages", profile: runnerProfile) + "/scripts/swarmctl",
            arguments: arguments)
        var call = Call(command: command)
        var failure: Error?
        do {
            guard try await backend.sessionTransport() == .nativeSessions else { throw WebhookPanelError.unavailable(nativeSessions) }
            _ = try await backend.createSession(title: "", systemPrompt: runner.outboundPersona, id: session)
            let instructions = """
            Run exactly this in one terminal call:
            ```sh
            \(command)
            ```
            Do not run anything else, retry, or change the command. Do not read or print any key file. Reply only "done".
            """
            let stream = try await backend.send(.init(sessionID: session, systemPrompt: runner.outboundPersona,
                messages: [(role: "user", content: request)], managementText: instructions))
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
        // A cancelled stream must not cancel its cleanup.
        await Task { await self.cleanUpdaterSessions(on: target, backend: backend) }.value
        if call.answered || failure == nil { return call }
        throw failure ?? WebhookPanelError.noAnswer
    }
}
