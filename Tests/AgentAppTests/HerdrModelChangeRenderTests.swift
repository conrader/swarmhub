import AppKit
import SwiftUI
import Testing
@testable import AgentApp

/// The card above the main bot's composer for a change of the bots' AI and model: asked about, applied, and after
/// fresh agents were started. Rendered offscreen for review and written to `$TMPDIR/AgentAppSnapshots-set-model/`.
/// Synthetic bots only.
@MainActor @Test func theModelChangeCardRenders() async throws {
    let store = AppStore(storeURL: temporaryStore(), autoStart: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    store.saveHerdrServer(store.herdrServers[0], token: "t")
    let jarvis = Bot(name: "Jarvis", backend: .herdr)
    let others = (1...22).map { Bot(name: "Bot \($0)", backend: .herdr) }
    store.bots = [jarvis] + others
    store.setCanManageBots(jarvis, true)
    let server = store.herdrServer(for: jarvis)

    let folder = FileManager.default.temporaryDirectory.appending(path: "AgentAppSnapshots-set-model", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    func render(_ name: String, height: CGFloat) async throws {
        let view = VStack { Spacer(); HerdrModelChangeCard(manager: jarvis) }.padding(.vertical, 16).environmentObject(store)
            .defaultAppStorage(store.defaults).frame(width: 820, height: height).background(Color(nsColor: .windowBackgroundColor))
        let data = try #require(await SnapshotRenderer.png(view, size: NSSize(width: 820, height: height), scale: 2))
        let image = try #require(NSBitmapImageRep(data: data))
        #expect(image.pixelsWide == 1640, "\(name)")
        try data.write(to: folder.appending(path: "\(name).png"))
    }

    // Asked about: nothing is changed until Apply.
    jarvis.messages = [ChatMessage(role: .user, content: "Could everyone run on Sol?"),
                       ChatMessage(role: .assistant, content: "I can switch them.\n\n```swarmhub\n{\"op\":\"set_model\",\"decision\":\"ask\",\"bots\":\"all\",\"runtime\":\"Codex\",\"model\":\"sol 6.2\"}\n```")]
    #expect(store.pendingHerdrModels(for: jarvis).count == 1 && SwarmhubSummary.lines(in: jarvis.messages[1].content).map(\.summary) == ["Asked to switch all bots to Codex · sol 6.2"])
    try await render("0-asked", height: 150)

    // Applied: what was changed while the sessions are being checked.
    store.dismissHerdrModel(try #require(store.pendingHerdrModels(for: jarvis).first))
    let changes = store.bots.map { HerdrModelPlan.Change(bot: $0.id, name: $0.name, template: "tpl-codex", model: "gpt-6.2-sol", beforeTemplate: "", beforeModel: "") }
    let record = AppStore.HerdrModelRecord(manager: jarvis.id, server: server.id, label: "Codex · GPT-6.2 Sol", changes: changes, at: Date())
    store.herdrModelRecords = [record]
    try await render("1-applied", height: 150)

    // After automatic rollover: three bots will switch on their next direct message.
    var after = record
    after.fresh = Array(changes.prefix(20).map(\.bot))
    after.rolloverSummary = "20 bots are ready to use the selected model now. 3 bots will switch on the next direct message after the current turn."
    store.herdrModelRecords = [after]
    #expect(store.herdrModelRecord(by: jarvis, on: server)?.notFresh == 3)
    try await render("2-some-still-answering", height: 150)
}
