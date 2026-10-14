import Darwin
import Foundation
import Testing
@testable import AgentApp

// MARK: --check-server against the fake gateway

@MainActor private func checkServer(profile: String = "default", key: String = "key-default", configure: (E2EServer.State) -> Void = { _ in }) async -> (checks: [HeadlessCheckServer.Check], lines: [String], state: E2EServer.State) {
    let server = E2EServer.serve()
    server.state.with { $0.keys = ["default": "key-default", "vanilla-a": "key-a", "vanilla-b": "key-b"] }
    configure(server.state)
    let backend = HermesBackend(baseURL: URL(string: "https://\(server.host)")!, apiKey: key, profile: profile, session: server.session)
    var lines: [String] = []
    let checks = await HeadlessCheckServer.run(backend: backend, tag: "t3st", output: { lines.append($0) })
    return (checks, lines, server.state)
}

@MainActor @Test func checkServerPassesEveryCheckAndReportsTheSkillsBugAsKnown() async {
    let (checks, lines, state) = await checkServer(profile: "vanilla-a", key: "key-a") { $0.skillsStatus = 500 }
    #expect(checks.map(\.id) == HeadlessCheckServer.ids)
    #expect(checks.filter { $0.outcome == .fail }.isEmpty, "\(lines)")
    #expect(checks.first { $0.id == "skills" }?.outcome == .known)
    #expect(checks.first { $0.id == "skills" }?.detail.contains("skills_enumeration") == true)
    #expect(checks.first { $0.id == "health" }?.detail.hasPrefix("Hermes 0.22.0 · works") == true)
    #expect(lines.last == "Check-server: 9 passed, 1 known, 0 failed")
    #expect(lines.dropLast().allSatisfy { $0.hasPrefix("PASS ") || $0.hasPrefix("KNOWN ") })

    let requests = state.requests()
    // Everything goes through the profile prefix; the only writes are one self-test session's create and delete.
    #expect(requests.allSatisfy { $0.path.hasPrefix("/p/vanilla-a/") })
    let writes = requests.filter { $0.method != "GET" }
    #expect(writes.map(\.method) == ["POST", "DELETE"])
    let id = "\(AppConstants.selfTestPrefix)vanilla-t3st"
    #expect(writes.first?.body?["id"] as? String == id && writes.last?.path == "/p/vanilla-a/api/sessions/\(id)")
    #expect(!requests.contains { $0.path.contains("/chat") }, "no chat turn is sent")
    #expect(requests.last?.method == "GET" && requests.last?.path.hasSuffix("/api/sessions/\(id)") == true, "gone is verified")
}

@MainActor @Test func checkServerFailsAuthWithAnotherProfilesKeyAndNeverPrintsIt() async {
    let (checks, lines, _) = await checkServer(profile: "vanilla-b", key: "key-a")
    #expect(checks.first { $0.id == "auth" } == .init(id: "auth", outcome: .fail, detail: "HTTP 401: the server rejected this key for profile vanilla-b"))
    #expect(checks.first { $0.id == "health" }?.outcome == .pass, "/health needs no key")
    #expect(checks.filter { $0.id != "health" }.allSatisfy { $0.outcome == .fail })
    #expect(checks.first { $0.id == "sessions" }?.detail == "HTTP 401: the server rejected this bot's key.")
    #expect(!lines.joined().contains("key-a"))
}

@MainActor @Test func checkServerFailsASkillsErrorOnAVersionWithoutThatBugAndASessionThatSurvivesDelete() async {
    let (checks, _, _) = await checkServer { $0.version = "0.20.5"; $0.skillsStatus = 500; $0.deleteKeepsSession = true }
    #expect(checks.first { $0.id == "skills" }?.outcome == .fail)
    #expect(checks.first { $0.id == "session-write" }?.outcome == .fail)
    #expect(checks.first { $0.id == "session-write" }?.detail.contains("still exists") == true)
}

@MainActor @Test func checkServerFlagsAProfileThePrefixIgnored() async {
    // With multiplexing off the gateway answers every prefix as the default agent.
    let (checks, _, _) = await checkServer(profile: "vanilla-a", key: "key-a") { $0.multiplex = false }
    #expect(checks.first { $0.id == "models" } == .init(id: "models", outcome: .fail, detail: "\(HermesBackend.multiplexOffMessage) (first model hermes-agent)"))
    let (defaults, _, _) = await checkServer()
    #expect(defaults.first { $0.id == "models" } == .init(id: "models", outcome: .pass, detail: "1 listed: hermes-agent"))
}

// MARK: Arguments, key file and report

@MainActor @Test func checkServerRefusesBadArgumentsAndLooseKeyFiles() throws {
    #expect(HeadlessCommands.runIfRequested(arguments: ["AgentApp", "--check-server", "http://127.0.0.1:1"]) == 64)
    #expect(HeadlessCommands.runIfRequested(arguments: ["AgentApp", "--check-server", "ftp://x", "--profile", "default", "--key-file", "/tmp/x"]) == 64)
    let directory = FileManager.default.temporaryDirectory.appending(path: "check-server-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appending(path: "k.key")
    try Data("secret-key\n".utf8).write(to: file)
    chmod(file.path, 0o644)
    if case .success = HeadlessCheckServer.readKey(at: file.path) { Issue.record("a 0644 key file must be refused") }
    chmod(file.path, 0o600)
    #expect((try? HeadlessCheckServer.readKey(at: file.path).get()) == "secret-key")
    #expect(HeadlessCommands.runIfRequested(arguments: ["AgentApp", "--check-server", "http://127.0.0.1:1", "--profile", "default", "--key-file", directory.appending(path: "none").path]) == 2)
}

@MainActor @Test func checkServerAppendsTheReportWithMode0600() throws {
    let path = FileManager.default.temporaryDirectory.appending(path: "check-server-\(UUID().uuidString).txt").path
    defer { unlink(path) }
    #expect(HeadlessCheckServer.append(["one"], to: path))
    chmod(path, 0o644)
    #expect(HeadlessCheckServer.append(["two", "three"], to: path))
    #expect(try String(contentsOfFile: path, encoding: .utf8) == "one\ntwo\nthree\n")
    #expect((try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int) == 0o600)
}
