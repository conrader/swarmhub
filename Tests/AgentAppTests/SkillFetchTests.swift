import Foundation
import Testing
@testable import AgentApp

// uxfix1-e2e: large skill files never travel through the model. A clean build fetches the files it ships unchanged from
// its own commit on the box (digest checked before anything is written); SKILL.md and rendered files stay heredocs.
// The shell cases run the real generated command against a file:// copy of the bundled files. Synthetic only.

private let commit = String(repeating: "ab12", count: 10)

@MainActor private func fetchStore(sha: String?) -> (AppStore, Bot, Bot) {
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { _ in MockBackend() },
                         keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    store.managerTemplateOverride = "manager text"
    store.skillSourceSHA = sha
    let jarvis = Bot(name: "Jarvis", backend: .hermes, hermesProfile: "grok-jarvis"); jarvis.canManageBots = true
    let infra = Bot(name: "Infra", backend: .hermes, hermesProfile: "grok-infra")
    store.bots = [jarvis, infra]; store.selectedBot = jarvis
    return (store, jarvis, infra)
}

@MainActor private func messagesSkill(_ store: AppStore) throws -> BundledSkill { try #require(store.skillLibrary.first { $0.name == "swarmhub-messages" }) }

@MainActor @Test func aCleanBuildFetchesTheFilesItShipsUnchangedAndWritesTheRestAsHeredocs() throws {
    let (store, _, infra) = fetchStore(sha: commit)
    let skill = try messagesSkill(store)
    let files = try #require(store.renderedSkillFiles(skill, profile: "grok-infra", codingOrder: .standard))
    let plan = try #require(SkillFetch.plan(skill: skill, rendered: files, folder: SkillLibrary.installPath(skill.name, profile: "grok-infra"), sourceSHA: commit))
    #expect(plan.base == "https://raw.githubusercontent.com/conrader/swarmhub/\(commit)/Resources/Skills/swarmhub-messages/")
    #expect(!plan.names.contains("SKILL.md") && plan.names.contains("scripts/peer-runtime.py") && plan.names.count >= 10)
    let text = try #require(try store.skillInstallInstructions([skill], profile: "grok-infra", botName: infra.name))
    #expect(text.contains(plan.base) && text.contains("cat > \(SkillLibrary.installPath(skill.name, profile: "grok-infra"))/SKILL.md"))
    #expect(!text.contains("cat > \(SkillLibrary.installPath(skill.name, profile: "grok-infra"))/scripts/peer-runtime.py"), "a fetched file is never retyped")
    let heredocs = try #require(try fetchStore(sha: nil).0.skillInstallInstructions([skill], profile: "grok-infra", botName: infra.name))
    #expect(text.utf8.count * 4 < heredocs.utf8.count, "the model's text shrinks from \(heredocs.utf8.count) to \(text.utf8.count) bytes")
}

@MainActor @Test func noCommitDevModeAndTheManagerSkillKeepHeredocs() throws {
    let (store, _, _) = fetchStore(sha: nil)
    let skill = try messagesSkill(store)
    let files = try #require(store.renderedSkillFiles(skill, profile: "grok-infra", codingOrder: .standard))
    #expect(SkillFetch.plan(skill: skill, rendered: files, folder: "~/x", sourceSHA: nil) == nil)
    #expect(SkillFetch.plan(skill: skill, rendered: files, folder: "~/x", sourceSHA: "abc") == nil, "only a full commit")
    #expect(SkillFetch.buildCommit(AppBuildInfo(version: "1", sourceSHA: commit, dirty: true)) == nil, "a dirty build has no commit to point at")
    #expect(SkillFetch.buildCommit(AppBuildInfo(version: "1", sourceSHA: commit, dirty: false)) == commit)
    let manager = try #require(store.skillLibrary.first { $0.name == SkillLibrary.managerSkill })
    let managerFiles = try #require(store.renderedSkillFiles(manager, profile: "grok-jarvis", codingOrder: .standard))
    let managerPlan = try #require(SkillFetch.plan(skill: manager, rendered: managerFiles, folder: "~/x", sourceSHA: commit))
    #expect(managerPlan.names.allSatisfy { $0.hasPrefix("scripts/") } && !managerPlan.names.isEmpty, "references live elsewhere in the repository")
    let (devStore, _, _) = fetchStore(sha: commit)
    let dev = try #require(try devStore.skillInstallInstructions([skill], profile: "grok-infra", botName: "Infra", devMode: true))
    #expect(!dev.contains("raw.githubusercontent.com"), "dev mode keeps its guarded heredocs")
}

@MainActor @Test func theFetchCommandWritesOnlyAVerifiedTree() async throws {
    guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { return }
    let (store, _, _) = fetchStore(sha: commit)
    let skill = try messagesSkill(store)
    let folder = SkillLibrary.installPath(skill.name, profile: "grok-infra")
    let files = try #require(store.renderedSkillFiles(skill, profile: "grok-infra", codingOrder: .standard))
    let plan = try #require(SkillFetch.plan(skill: skill, rendered: files, folder: folder, sourceSHA: commit))
    let root = FileManager.default.temporaryDirectory.appending(path: "fetch-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let mirror = root.appending(path: "mirror", directoryHint: .isDirectory), home = root.appending(path: "home", directoryHint: .isDirectory)
    for name in plan.names {
        let url = mirror.appending(path: name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(try #require(skill.files.first { $0.path == name }).content.utf8).write(to: url)
    }
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let local = SkillFetch.Plan(base: mirror.absoluteString, destination: plan.destination, digest: plan.digest, names: plan.names)
    let ok = try run(SkillFetch.command(local), home: home)
    #expect(ok.status == 0, "\(ok.output)")
    let landed = home.appending(path: String(folder.dropFirst(2)), directoryHint: .isDirectory)
    for name in plan.names {
        #expect(try String(contentsOf: landed.appending(path: name), encoding: .utf8) == skill.files.first { $0.path == name }?.content, "\(name)")
    }
    // A file that differs from the build's copy fails the tree digest: nothing is written.
    try FileManager.default.removeItem(at: landed)
    try Data("tampered\n".utf8).write(to: mirror.appending(path: plan.names[0]))
    let bad = try run(SkillFetch.command(local), home: home)
    #expect(bad.status != 0 && bad.output.contains("\(SkillFetch.failure) \(folder) digest mismatch"), "\(bad.output)")
    #expect(!FileManager.default.fileExists(atPath: landed.path))
}

private func run(_ script: String, home: URL) throws -> (status: Int32, output: String) {
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", script]
    process.environment = ["PATH": "/usr/bin:/bin", "HOME": home.path]
    process.standardOutput = pipe; process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}
