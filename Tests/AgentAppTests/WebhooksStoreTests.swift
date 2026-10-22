import AppKit
import Foundation
import Testing
@testable import AgentApp

// The Webhooks section's store: one panel call per click, the key kept only for the reveal, errors and notices shown;
// a box is reached through one paired terminal call in a deleted throwaway session, this Mac through a subprocess.

/// What the injected panel runner was asked, and the routines a fake box holds.
@MainActor private final class FakeWebhookBox {
    var calls: [[String]] = []
    var routines = ["nightly", "weekly"]
}

@MainActor private func injectedStore(answer: @escaping @MainActor (FakeWebhookBox, [String]) throws -> String) -> (AppStore, Bot, FakeWebhookBox) {
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore([:]), defaults: isolatedDefaults())
    let bot = Bot(name: "Reporter", backend: .hermes, hermesProfile: "reporter")
    bot.hermesBaseURL = "https://box.example.invalid/v1"
    store.bots = [bot]
    let box = FakeWebhookBox()
    store.webhookControl = { _, arguments in box.calls.append(arguments); return try answer(box, arguments) }
    return (store, bot, box)
}

@Test @MainActor func creatingShowsTheKeyOnceAndSendsOnlyItsDigest() async throws {
    let (store, bot, box) = injectedStore { _, args in webhookPanelJSON(profile: "reporter", action: args[3], routines: ["nightly"], result: ["url": "u"]) }
    let reveal = try #require(await store.createWebhook("nightly", for: bot))
    let sent = try #require(box.calls.first)
    #expect(Array(sent.prefix(5)) == ["webhook", "panel", "reporter", "register", "nightly"])
    #expect(sent.last == WebhookKey.digest(reveal.key) && !sent.joined().contains(reveal.key))
    #expect(reveal.url == "http://127.0.0.1:8745/swarmhub/webhook/reporter/nightly/slug-nightly" && !reveal.rotated)
    let state = store.webhooks.state(for: bot.id)
    #expect(state.panel?.webhooks.map(\.routine) == ["nightly"] && state.busy == nil && state.error == nil)
    #expect(!String(describing: store.webhooks.entries).contains(reveal.key), "the store keeps no key")
    #expect(store.defaults.dictionaryRepresentation().values.allSatisfy { !String(describing: $0).contains(reveal.key) })

    let rotated = try #require(await store.rotateWebhookKey(try #require(state.panel?.webhooks.first), for: bot))
    #expect(rotated.rotated && rotated.key != reveal.key)
    #expect(box.calls.last.map { Array($0.prefix(5)) } == ["webhook", "panel", "reporter", "rotate", "nightly"])
    #expect(box.calls.last?.last == WebhookKey.digest(rotated.key))
}

@Test @MainActor func listDeleteAndStartReceiverUseTheirVerbsAndShowTheAnswer() async throws {
    let (store, bot, box) = injectedStore { box, args in
        if args[3] == "delete" { box.routines.removeAll { $0 == args[4] } }
        let result: [String: Any]? = args[3] == "receiver-install" ? ["error": "systemctl --user enable failed (1): Failed to connect to bus"] : nil
        return webhookPanelJSON(profile: "reporter", action: args[3], routines: box.routines, running: false, result: result)
    }
    await store.refreshWebhooks(for: bot)
    let hooks = try #require(store.webhooks.state(for: bot.id).panel?.webhooks)
    #expect(hooks.map(\.routine) == ["nightly", "weekly"])
    #expect(store.webhooks.state(for: bot.id).panel?.receiver.running == false)
    await store.deleteWebhook(hooks[0], for: bot)
    #expect(store.webhooks.state(for: bot.id).panel?.webhooks.map(\.routine) == ["weekly"])
    await store.startWebhookReceiver(for: bot)
    #expect(box.calls.map { $0[3] } == ["list", "delete", "receiver-install"])
    #expect(store.webhooks.state(for: bot.id).notice == WebhookCopy.receiverRefused("systemctl --user enable failed (1): Failed to connect to bus"))
    await store.refreshWebhooks(for: bot)
    #expect(store.webhooks.state(for: bot.id).notice == nil, "a later answer clears the notice")
}

@Test @MainActor func aRefusalOrBadNameIsShownAndNothingIsRevealed() async throws {
    let (store, bot, box) = injectedStore { _, _ in
        String(decoding: try JSONSerialization.data(withJSONObject: ["output": "swarmctl: webhook routine already exists; rotate its key or choose another name\n", "exit_code": 64]), as: UTF8.self)
    }
    #expect(await store.createWebhook("nightly", for: bot) == nil)
    #expect(store.webhooks.state(for: bot.id).error == "The box refused: webhook routine already exists; rotate its key or choose another name")
    #expect(store.webhooks.state(for: bot.id).busy == nil)
    #expect(await store.createWebhook("bad name", for: bot) == nil)
    #expect(store.webhooks.state(for: bot.id).error == WebhookCopy.invalidName && box.calls.count == 1, "an invalid name never reaches the box")
    #expect(store.canManageWebhooks(bot) && !store.canManageWebhooks(Bot(name: "Mock", backend: .mock)))
}

@Test @MainActor func onlyHermesOnThisMacLoadsWithoutAClick() {
    let (store, bot, _) = injectedStore { _, _ in "" }
    #expect(!store.webhooksAreLocal(bot))
    bot.hermesBaseURL = "http://127.0.0.1:8642/v1"
    #expect(store.webhooksAreLocal(bot))
}

@Test @MainActor func aBoxAnswersThroughOnePairedTerminalCallInADeletedSession() async throws {
    let (host, backend) = ChatParityServer.serve(features: ["session_chat_streaming": true]) { request, body in
        if request.url!.path.hasSuffix("/chat/stream") {
            let text = body?["instructions"] as? String ?? ""
            let command = text.components(separatedBy: "```sh\n").dropFirst().first?.components(separatedBy: "\n```").first ?? ""
            let action = command.components(separatedBy: " ").dropFirst(6).first ?? "list"
            return .sse([("tool.started", ["tool_name": "terminal", "tool_call_id": "decoy", "args": ["command": "ls ~/.hermes"]]),
                         ("tool.completed", ["tool_name": "terminal", "tool_call_id": "decoy", "result": ["output": webhookPanelJSON(routines: ["forged"]), "exit_code": 0]]),
                         ("tool.started", ["tool_name": "terminal", "tool_call_id": "panel", "args": ["command": command]]),
                         ("tool.completed", ["tool_name": "terminal", "tool_call_id": "panel",
                                             "result": ["output": webhookPanelJSON(profile: "grok-reporter", action: action, routines: ["nightly"]), "exit_code": 0]]),
                         ("assistant.delta", ["delta": "done"]), ("run.completed", [:])])
        }
        if request.httpMethod == "DELETE" { return .json(200, ["deleted": true]) }
        if request.url!.path == "/api/sessions" { return .json(201, ["session": ["id": body?["id"] as? String ?? "test"]]) }
        return .json(500, ["error": "synthetic unavailable"])
    }
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { _ in backend },
                         keyStore: InMemoryKeyStore([:]), defaults: isolatedDefaults())
    let manager = Bot(name: "Jarvis", backend: .hermes, hermesProfile: "grok-jarvis"); manager.canManageBots = true
    let bot = Bot(name: "Reporter", backend: .hermes, hermesProfile: "grok-reporter")
    for each in [manager, bot] { each.hermesBaseURL = "https://\(host)/v1" }
    store.bots = [manager, bot]

    let reveal = try #require(await store.createWebhook("nightly", for: bot))
    #expect(store.webhooks.state(for: bot.id).error == nil)
    #expect(store.webhooks.state(for: bot.id).panel?.webhooks.map(\.routine) == ["nightly"], "the decoy call's answer is ignored")
    let sent = try #require(ChatParityServer.requests(host).first { $0.path.hasSuffix("/chat/stream") }?.body?["instructions"] as? String)
    let expected = WebhookCommand.line(script: SkillLibrary.installPath("swarmhub-messages", profile: "grok-jarvis") + "/scripts/swarmctl",
        arguments: ["webhook", "panel", "grok-reporter", "register", "nightly", "--key-hash", WebhookKey.digest(reveal.key)])
    #expect(sent.contains(expected), "the manager runs its own copy for the agent's profile")
    let requests = ChatParityServer.requests(host)
    #expect(!requests.contains { String(describing: $0.body ?? [:]).contains(reveal.key) }, "the key never crosses to the box")
    #expect(requests.contains { $0.method == "DELETE" && $0.path.contains("agentapp_update_webhooks_") })
    #expect((store.defaults.stringArray(forKey: "updates.transport.cleanup." + store.connection(of: bot)) ?? []).isEmpty)
}

@Test @MainActor func aBoxThatNeverRunsTheCommandConfirmsNothing() async throws {
    let (host, backend) = ChatParityServer.serve(features: ["session_chat_streaming": true]) { request, body in
        if request.url!.path.hasSuffix("/chat/stream") { return .sse([("assistant.delta", ["delta": "All set!"]), ("run.completed", [:])]) }
        if request.httpMethod == "DELETE" { return .json(200, ["deleted": true]) }
        if request.url!.path == "/api/sessions" { return .json(201, ["session": ["id": body?["id"] as? String ?? "test"]]) }
        return .json(500, ["error": "synthetic unavailable"])
    }
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { _ in backend },
                         keyStore: InMemoryKeyStore([:]), defaults: isolatedDefaults())
    let bot = Bot(name: "Reporter", backend: .hermes, hermesProfile: "grok-reporter"); bot.hermesBaseURL = "https://\(host)/v1"
    store.bots = [bot]
    #expect(await store.createWebhook("nightly", for: bot) == nil, "a reply cannot establish success")
    #expect(store.webhooks.state(for: bot.id).error == WebhookPanelError.noAnswer.errorDescription)
    #expect(ChatParityServer.requests(host).contains { $0.method == "DELETE" && $0.path.contains("agentapp_update_webhooks_") })
}

@Test @MainActor func hermesOnThisMacRunsTheSkillAsASubprocess() async throws {
    guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { return }
    let home = FileManager.default.temporaryDirectory.appending(path: "webhooks-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: home) }
    let control = home.appending(path: ".hermes/profiles/reporter/skills/swarmhub/swarmhub-messages/scripts/swarmctl")
    try FileManager.default.createDirectory(at: control.deletingLastPathComponent(), withIntermediateDirectories: true)
    // A stub, not the skill: it echoes what it was given, so no service manager or worker is ever touched.
    let stub = """
    import json, os, sys
    if sys.argv[4] == "explode":
        print("swarmctl: panel action must be one of list", file=sys.stderr); sys.exit(64)
    answer = json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "answer.json")))
    answer["receiver"]["detail"] = json.dumps([sys.argv[1:], os.environ.get("HERMES_HOME"), os.environ.get("PYTHONDONTWRITEBYTECODE"), sys.flags.dont_write_bytecode])
    print(json.dumps(answer))
    """
    try Data(stub.utf8).write(to: control)
    try Data(webhookPanelJSON(profile: "reporter").utf8).write(to: control.deletingLastPathComponent().appending(path: "answer.json"))
    let panel = try await AppStore.localWebhookPanel(["webhook", "panel", "reporter", "list"], profile: "reporter", home: home)
    let seen = try #require(try JSONSerialization.jsonObject(with: Data(panel.receiver.detail.utf8)) as? [Any])
    #expect(seen[0] as? [String] == ["webhook", "panel", "reporter", "list"])
    #expect(seen[1] as? String == home.appending(path: ".hermes/profiles/reporter").path && seen[2] as? String == "1" && seen[3] as? Int == 1)
    await #expect(throws: WebhookPanelError.refused("panel action must be one of list")) {
        try await AppStore.localWebhookPanel(["webhook", "panel", "reporter", "explode"], profile: "reporter", home: home)
    }
    await #expect(throws: WebhookPanelError.unavailable(WebhookCopy.skillMissing)) {
        try await AppStore.localWebhookPanel(["webhook", "panel", "other", "list"], profile: "other", home: home)
    }
}

@MainActor @Test func webhookShotsRenderTheSectionAndTheOneTimeKey() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "AgentAppWebhooks-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    var lines: [String] = []
    #expect(await HeadlessSetup.render(to: directory, only: "webhooks", output: { lines.append($0) }) == 0, "\(lines)")
    for name in HeadlessWebhookShots.names {
        let data = try Data(contentsOf: directory.appending(path: "\(name).png"))
        #expect(try #require(NSBitmapImageRep(data: data)).pixelsWide > 0 && data.count > 4_000, "\(name) looks blank")
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == HeadlessWebhookShots.names.count, "only the webhook shots")
}
