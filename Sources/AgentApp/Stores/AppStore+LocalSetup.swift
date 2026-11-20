import AppKit
import Foundation

/// "This Mac" as a place bots run: the app gets the SwarmHub service from the signed release, checks it, and has it
/// set this Mac up (`HerdrLocalService`); and it finds out, before the first message does, whether an AI still has a
/// question for the person. Nothing here answers such a question or changes an AI program's settings.
extension AppStore {
    /// The service program on this Mac. A check names scratch folders and a job name of its own through the app's
    /// environment, which the program inherits.
    /// A development launch that calls another folder home (for a store of its own) names the person's real home in
    /// `SWARMHUB_SERVICE_HOME`, so this Mac is set up where its AI programs are signed in.
    var localService: HerdrLocalService {
        var service = HerdrLocalService()
        if let home = ProcessInfo.processInfo.environment["SWARMHUB_SERVICE_HOME"], home.hasPrefix("/") { service.home = home }
        return service
    }

    /// Gets this Mac ready to run bots. The service program is fetched only when it is not here yet, and is put in
    /// place only after its signature and digest were checked against the release key (`WorkspaceRelease`). The
    /// program then does the rest: Herdr Core when it is missing, the access key, the starter templates, and the job
    /// that starts it now and at every login.
    /// `answerFirstTime`: the person left "answer my AIs' first questions" on.
    func setUpThisMac(port: Int, answerFirstTime: Bool, progress: @MainActor (HerdrLocalSetup.Step) -> Void) async throws -> HerdrLocalReport {
        let service = localService
        if !service.hasVerifiedProgram() {
            progress(.fetching())
            let release = try await WorkspaceRelease.latest()
            if !service.matchesInstalledProgram(release) {
                let program = try await release.downloadProgram(for: HerdrLocalService.target) { progress(.fetching($0)) }
                try Task.checkCancellation()
                try service.place(program)
            }
            service.rememberVerifiedProgram(release)
        }
        try Task.checkCancellation()
        progress(.installing)
        do { return try await service.install(port: port, answerFirstTime: answerFirstTime) }
        catch let failure as HerdrLocalFailure where failure.kind == "port_busy" { throw HerdrLocalFailure(kind: failure.kind, message: WizardCopy.portBusy(port)) }
    }

    /// What the service on this Mac says is installed; nil when the app did not put a service here.
    func localReport(port: Int?) async -> HerdrLocalReport? {
        let service = localService
        return service.isPlaced ? try? await service.status(port: port) : nil
    }

    /// Whether the AI of `program` can take a message on this Mac right now (`HerdrClient.firstRunCheck`).
    func checkAI(_ program: HerdrProgram, on server: HerdrServer, key: String?, note: String?) async -> HerdrAICheck {
        var check = HerdrAICheck(template: program.template, name: program.name, note: note)
        do { check.state = try await herdrClient(for: server, token: key).firstRunCheck(template: program.template) }
        catch { check.state = .failed(error.localizedDescription) }
        return check
    }

    /// The lines of a file that opens `agent`'s terminal on this Mac: Herdr Core's own viewer, in Terminal. The
    /// person answers there; closing the window leaves the AI running.
    nonisolated static func terminalScript(core: String, address: String, name: String, environment: [String: String]) -> String {
        func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
        let carried = ["HC_SESSION", "HC_SOCKET", "XDG_STATE_HOME", "XDG_CONFIG_HOME", "XDG_RUNTIME_DIR"].compactMap { key in
            environment[key].flatMap { $0.isEmpty ? nil : "export \(key)=\(quoted($0))" }
        }
        return (["#!/bin/sh", "# Opens \(name)'s own window so you can answer its question. Close the window when you are done."] + carried
                + ["exec \(quoted(core)) attach \(quoted(address))"]).joined(separator: "\n") + "\n"
    }

    /// Opens the terminal of an AI that waits for an answer. Returns false when Terminal could not be opened.
    @discardableResult func answerInTerminal(_ check: HerdrAICheck) -> Bool {
        let agent: HerdrClient.AgentRef
        switch check.state {
        case .asks(_, let ref), .unready(let ref): agent = ref
        default: return false
        }
        return openInTerminal(script: Self.terminalScript(core: localService.corePath, address: agent.address, name: check.name, environment: ProcessInfo.processInfo.environment), name: check.name)
    }

    /// Writes `script` as a file only this account can read and run, and opens it in Terminal.
    @discardableResult func openInTerminal(script: String, name: String) -> Bool {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("\(AppConstants.name)-answers", isDirectory: true)
        let file = folder.appendingPathComponent("Answer \(name.filter { $0.isLetter || $0.isNumber || $0 == " " }).command")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        } catch { return false }
        return ExternalLink.open(file)
    }

    /// Stops the service on this Mac and removes what setting it up installed. Conversations and Herdr Core stay.
    func removeLocalService() async throws -> HerdrLocalRemoval { try await localService.remove() }
}
