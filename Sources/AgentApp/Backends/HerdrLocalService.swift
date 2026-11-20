import Foundation

/// What `swarmhub-herdr service status|install --json` says about this Mac (`HerdrWorkspace/src/service.rs`): the
/// service program, Herdr Core, the job that keeps the service running, and the agent programs it looked for. Every
/// name and sentence here is the service's own; the app adds none.
struct HerdrLocalReport: Decodable, Equatable, Sendable {
    struct Job: Decodable, Equatable, Sendable { let installed: Bool; let loaded: Bool; let answers: Bool; var pid: Int? = nil; let label: String }
    struct Core: Decodable, Equatable, Sendable { let installed: Bool; var path: String? = nil; var version: String? = nil; let running: Bool }
    /// An agent program the service has a starter template for. `how`: what to do when it is not on this Mac.
    /// `firstTime`: what it asks a person the first time it starts for the service, and what the answer allows.
    struct Program: Decodable, Equatable, Identifiable, Sendable {
        let id: String; let name: String; let installed: Bool; let template: String; let how: String
        var firstTime: String? = nil
    }
    let version: String; let target: String; let canInstall: Bool; let program: String; let port: Int
    let service: Job; let core: Core; let programs: [Program]
    var agentsFolder: String? = nil, dataFolder: String? = nil
    /// After an install: what it did, one sentence each.
    var did: [String]? = nil
    /// After an install that answered the AIs' first-time questions: per AI program, whether nothing will be asked
    /// (`done`), what was done (`what`) or why not (`why`).
    struct FirstTime: Decodable, Equatable, Sendable { let id: String; let done: Bool; var what: String? = nil; var why: String? = nil }
    var firstTime: [FirstTime]? = nil

    /// The agent programs that are not on this Mac, each with what to do about it.
    var missing: [Program] { programs.filter { !$0.installed } }
    func program(template: String) -> Program? { programs.first { $0.template == template } }
}

/// What `service remove --json` says: what it took away and what it left, one sentence each.
struct HerdrLocalRemoval: Decodable, Equatable, Sendable { var did: [String] = []; var kept: [String] = [] }

/// Why a service command ended without doing what was asked, with the service's own word for it (`kind`):
/// `port_busy`, `no_session`, `core_download`, `core_signature`, `core_install`, `not_started`, `failed`; and the
/// app's own `not_run` when the program could not be run at all.
struct HerdrLocalFailure: LocalizedError, Equatable, Sendable {
    let kind: String; let message: String
    var errorDescription: String? { message }
}

/// The SwarmHub service program on this Mac: where it is put, and its `service` commands run as child processes.
/// The app puts the program there only after it has checked it against the signed release (`WorkspaceRelease`);
/// everything else about setting this Mac up is the program's own work. Foundation only.
struct HerdrLocalService: Sendable {
    /// The home folder everything goes under. The app's own, so a check with a scratch home touches nothing else.
    var home = NSHomeDirectory()
    /// Added to the child's environment on top of the app's own; checks name scratch folders and a job name here.
    var environment: [String: String] = [:]
    var label: String? = nil

    /// The kind of machine this app runs on, as releases name it.
    static var target: String {
        #if arch(arm64)
        "aarch64-macos"
        #else
        "x86_64-macos"
        #endif
    }

    private func path(_ relative: String) -> String { (home as NSString).appendingPathComponent(relative) }
    var programPath: String { path(".local/bin/swarmhub-herdr") }
    var isPlaced: Bool { FileManager.default.isExecutableFile(atPath: programPath) }
    /// Herdr Core's command is where Herdr's own installer puts it, so setting up need not fetch it.
    var hasCore: Bool { ["hc", "herdr-core"].contains { FileManager.default.isExecutableFile(atPath: path(".local/bin/\($0)")) } }
    /// Herdr Core's command, for opening one of its terminals.
    var corePath: String { ["hc", "herdr-core"].map { path(".local/bin/\($0)") }.first { FileManager.default.isExecutableFile(atPath: $0) } ?? path(".local/bin/hc") }

    private struct ReleaseProof: Codable {
        let manifest: Data
        let signature: String
    }

    private var proofURL: URL { URL(fileURLWithPath: programPath).appendingPathExtension("release.json") }

    /// Reuse a service whose installed bytes still match a manifest signed by the bundled release key.
    func hasVerifiedProgram(publicKey: String = WorkspaceRelease.bundledKey) -> Bool {
        guard isPlaced, let data = try? Data(contentsOf: proofURL),
              let proof = try? JSONDecoder().decode(ReleaseProof.self, from: data),
              let release = try? WorkspaceRelease.verified(manifest: proof.manifest, signature: proof.signature, publicKey: publicKey) else { return false }
        return matchesInstalledProgram(release)
    }

    func matchesInstalledProgram(_ release: WorkspaceRelease) -> Bool {
        guard isPlaced, let asset = release.asset(for: Self.target) else { return false }
        let url = URL(fileURLWithPath: programPath)
        guard (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize == asset.size,
              let program = try? Data(contentsOf: url, options: .mappedIfSafe) else { return false }
        return WorkspaceRelease.matches(program, asset)
    }

    func rememberVerifiedProgram(_ release: WorkspaceRelease) {
        let proof = ReleaseProof(manifest: release.manifestData, signature: release.signature)
        if let data = try? JSONEncoder().encode(proof) { try? data.write(to: proofURL, options: .atomic) }
    }

    /// Puts a checked program in place in one step, for this account to run.
    func place(_ program: Data) throws {
        let target = URL(fileURLWithPath: programPath), folder = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let draft = folder.appendingPathComponent(".swarmhub-herdr-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: draft) }
        guard FileManager.default.createFile(atPath: draft.path, contents: program, attributes: [.posixPermissions: 0o755]) else {
            throw HerdrLocalFailure(kind: "not_placed", message: "The \(AppConstants.name) service could not be saved in \(folder.path).")
        }
        guard rename(draft.path, target.path) == 0 else {
            throw HerdrLocalFailure(kind: "not_placed", message: "The \(AppConstants.name) service could not be saved in \(folder.path).")
        }
    }

    func status(port: Int? = nil) async throws -> HerdrLocalReport { try Self.answer(try await run("status", port: port, limit: 60)) }
    /// Sets this Mac up: Herdr Core when it is missing, the access key, the starter templates, and the job that starts
    /// the service now and at every login. Returns once the service answers.
    /// `answerFirstTime`: the person agreed that the questions an AI asks the first time are answered for them, for
    /// the bots' folder and the service's own reporting commands only.
    func install(port: Int, answerFirstTime: Bool = false) async throws -> HerdrLocalReport {
        try Self.answer(try await run("install", port: port, limit: 900, extra: answerFirstTime ? ["--answer-first-time"] : []))
    }
    /// Stops the service and removes what `install` put on this Mac. Conversations stay.
    func remove() async throws -> HerdrLocalRemoval {
        let report: HerdrLocalRemoval = try Self.answer(try await run("remove", port: nil, limit: 120))
        if !isPlaced { try? FileManager.default.removeItem(at: proofURL) }
        return report
    }

    private struct Refusal: Decodable { let error: String; var kind: String? = nil }

    /// A command's answer, or its refusal in the service's own sentence.
    static func answer<T: Decodable>(_ output: Data) throws -> T {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        if let refusal = try? decoder.decode(Refusal.self, from: output) { throw HerdrLocalFailure(kind: refusal.kind ?? "failed", message: refusal.error) }
        guard let answer = try? decoder.decode(T.self, from: output) else {
            throw HerdrLocalFailure(kind: "failed", message: "The \(AppConstants.name) service on this Mac gave an answer the app could not read.")
        }
        return answer
    }

    func arguments(_ verb: String, port: Int?, extra: [String] = []) -> [String] {
        ["service", verb] + (port.map { ["--port", String($0)] } ?? []) + (label.map { ["--label", $0] } ?? []) + extra + ["--json"]
    }

    /// Runs one `service` command and returns what it printed. It is ended when it takes longer than `limit` seconds.
    private func run(_ verb: String, port: Int?, limit: TimeInterval, extra: [String] = []) async throws -> Data {
        let process = Process(), out = Pipe()
        process.executableURL = URL(fileURLWithPath: programPath); process.arguments = arguments(verb, port: port, extra: extra)
        process.environment = ProcessInfo.processInfo.environment.merging(["HOME": home]) { _, new in new }.merging(environment) { _, new in new }
        process.standardInput = FileHandle.nullDevice; process.standardOutput = out; process.standardError = FileHandle.nullDevice
        let notRun = HerdrLocalFailure(kind: "not_run", message: "The \(AppConstants.name) service on this Mac could not be run.")
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do { try process.run() } catch { continuation.resume(throwing: notRun); return }
                let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + limit, execute: timer)
                let data = out.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit(); timer.cancel()
                if data.isEmpty { continuation.resume(throwing: notRun) } else { continuation.resume(returning: data) }
            }
        }
    }
}

/// Getting this Mac ready from the setup window, when nothing answers here yet: offered with what will be installed,
/// under way, or stopped with the reason in one sentence.
enum HerdrLocalSetup: Equatable, Sendable {
    enum Step: Equatable, Sendable {
        case fetching(WorkspaceRelease.DownloadProgress? = nil)
        case installing
    }
    /// `hasCore`: Herdr Core is already on this Mac, so it is not installed again.
    case offer(hasCore: Bool)
    case working(Step)
    case failed(String)

    var isWorking: Bool { if case .working = self { true } else { false } }

    var isInstalling: Bool { self == .working(.installing) }

    /// One sentence for a failure, whatever threw it: the service's own, the release check's, or the network's.
    static func line(for error: Error) -> String {
        if let failure = error as? HerdrLocalFailure { return failure.message }
        if let failure = error as? WorkspaceRelease.Failure {
            switch failure {
            case .unreachable: return "This Mac could not finish downloading the \(AppConstants.name) service. Check the internet connection, then try again."
            case .noProgram: return "This version of the \(AppConstants.name) service is not published for this kind of Mac yet."
            default: return failure.localizedDescription
            }
        }
        return error.localizedDescription
    }
}

/// Whether one of a server's AIs can take a message right now, found by starting it once with no task. An agent
/// program asks a person a question the first time it runs somewhere new (may it work in this folder, may it run
/// these commands), and it asks in its terminal, where no chat shows it. Setup finds that out before the first
/// message does.
struct HerdrAICheck: Equatable, Identifiable, Sendable {
    enum State: Equatable, Sendable {
        case checking
        case ready
        /// It waits at a question. `screen`: what its terminal shows; `agent`: the terminal to answer it in.
        case asks(screen: String, agent: HerdrClient.AgentRef)
        case unready(HerdrClient.AgentRef)
        case failed(String)
    }
    let template: String
    /// The AI's name as the server gives it.
    let name: String
    var state = State.checking
    /// What this AI asks the first time and what the answer allows, in the service's words; nil when it gave none.
    var note: String? = nil
    var id: String { template }

    /// The agent a check starts: one per AI, reused by the next check, so answering its question is what makes it ready.
    static func agentName(template: String) -> String { String("setup-" + template.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }).prefix(32).description }

    /// The question as its terminal shows it: the lines with words in them, without the frames a terminal program
    /// draws, the last few when there are many.
    static func question(from screen: String, lines limit: Int = 12) -> String {
        let frame = CharacterSet(charactersIn: "─━│┃┌┐└┘├┤┬┴┼╭╮╰╯═║╔╗╚╝▏▕▁▔-_=|+*·•❯›> \t")
        let lines = screen.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in line.unicodeScalars.contains { !frame.contains($0) } }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "│┃║ ")) }
        return lines.suffix(limit).joined(separator: "\n")
    }
}

extension HerdrClient {
    /// Starts the AI of `template` once with no task (nothing is sent to a model) and waits for it to say it is
    /// ready. Ready: its agent is ended again. Not ready within `wait`: it is asking something, and its agent keeps
    /// running so the question can be answered in its terminal; the next check finds that agent and looks again.
    func firstRunCheck(template: String, wait: Duration = .seconds(45), every: Duration = .seconds(1)) async -> HerdrAICheck.State {
        let name = HerdrAICheck.agentName(template: template)
        do {
            let agent: Agent
            switch try await warm(name: name, template: template) {
            case .started(let started, _), .running(let started, _): agent = started
            case .unavailable: return .ready
            }
            let clock = ContinuousClock(), deadline = clock.now + wait
            while true {
                guard let now = try await workspace().agents.first(where: { $0.ref == agent.ref }), now.isLive else {
                    return .failed("It stopped while it was starting. Open Terminal and start it once by hand to see why.")
                }
                if now.status?.state == "blocked" || clock.now >= deadline {
                    let output = (try? await screen(of: agent.ref)) ?? ""
                    if HerdrPrompt.actionable(kind: now.status?.kind, screen: output) {
                        return .asks(screen: HerdrAICheck.question(from: output), agent: agent.ref)
                    }
                }
                if now.ready != false, now.status?.state != "blocked" { try? await end(now); return .ready }
                if clock.now >= deadline { return .unready(agent.ref) }
                try await Task.sleep(for: every)
            }
        } catch { return .failed(error.localizedDescription) }
    }
}
