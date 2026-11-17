import AppKit
import SwiftUI

/// More shots of `--render-setup`: a chat with messages between bots of several colours, folded and with one
/// unfolded, and the same exchange in the chat of the bot that wrote. All synthetic and in memory, like
/// `HeadlessHerdrShots`: nothing connects and nothing of the real app is read.
@MainActor enum HeadlessPolishShots {
    static let messages = ["polish-messages-folded", "polish-messages-unfolded", "polish-messages-sender"]
    static let names = messages

    /// What one bot asks of another in the shots: a long message, as bots write them.
    static let brief = """
        Please set up the registry MCP on the build box. What I need:

        1. Install the server from the team's package index, pinned to the version in `tools.lock`.
        2. Register it for both agent programs, with the read-only token from the vault.
        3. Run the client once and check that registration succeeds and the MCP responds.
        4. Write down what you changed in `docs/build-box.md`.

        Do not restart the build agents while a build is running. If the token is missing, stop and tell me: I will ask for one.

        When you are done, answer with the version you installed and the three tools it lists.
        """

    /// Three bots of different colours around Infra, one of them with a white face (black on a light window).
    struct Cast { let store: AppStore; let jarvis: Bot, infra: Bot, boppy: Bot, research: Bot; let unfolded: UUID }

    static func cast() -> Cast {
        let store = SetupPreview.makeStore(backendFactory: { _ in MockBackend() }); store.isSetupPreview = false
        store.saveHerdrServer(store.herdrServers[0], token: nil)
        func bot(_ name: String, _ title: String, _ shape: String, _ colour: AvatarColour) -> Bot {
            let bot = Bot(name: name, title: title, backend: .herdr); bot.avatarMark = AvatarMark(shape: shape, colour: colour.rawValue); bot.avatarMarkMigrated = false
            return bot
        }
        let jarvis = bot("Jarvis", "Chief of staff", "teardrop", .black), infra = bot("Infra", "Servers and backups", "hex", .cyan)
        let boppy = bot("Boppy", "Product", "squircle", .brown), research = bot("Research", "Sources and links", "star", .violet)
        jarvis.canManageBots = true
        store.bots = [jarvis, infra, boppy, research]
        store.defaults.set(AppStore.introStarted, forKey: AppStore.herdrIntroKey(jarvis.id))
        func id(_ bot: Bot) -> String { bot.id.uuidString.lowercased() }
        func passed(_ text: String, _ kind: String, from sender: Bot) -> ChatMessage {
            var metadata = [HerdrBotRelay.Key.kind: kind, HerdrBotRelay.Key.asker: id(kind == HerdrBotRelay.answer ? infra : sender), HerdrBotRelay.Key.name: sender.name]
            if kind == HerdrBotRelay.answer { metadata[HerdrBotRelay.ExchangeKey.from] = id(sender) }
            return ChatMessage(role: .user, content: text, metadata: metadata)
        }
        // The reply of the report: its steps began while a word was half written.
        let said = "I installed the registry server, pinned to the locked version, and registered it for both agent programs. Next I run the client once to check that registration succeeds and the MCP responds.\n\nIt does: the client lists three tools (`search`, `fetch`, `publish`)."
        let reply = ChatMessage(role: .assistant, content: said, createdAt: .now - 300)
        var steps = ToolActivity()
        let cut = said.utf16.count - said[said.range(of: "on succeeds")!.lowerBound...].utf16.count
        for (index, command) in ["registry-client register --all", "registry-client ping", "registry-client tools", "git diff --stat docs/build-box.md"].enumerated() {
            steps.apply(ToolEvent(phase: .started, name: "bash", preview: command, callID: "\(index)"), at: .now - 280 + Double(index * 6), textOffset: cut)
            steps.apply(ToolEvent(phase: .completed, name: "bash", callID: "\(index)"), at: .now - 276 + Double(index * 6))
        }
        steps.finish(at: .now - 256); reply.activity = steps
        let first = passed(HerdrBotRelay.message(from: jarvis.name, brief), HerdrBotRelay.message, from: jarvis)
        infra.messages = [first, reply,
                          AppOnlyLine.line(HerdrMessageLine.sent.render(infra.name, research.name, "Which version of the registry server does the team's package index list as stable today? I need the exact number for `tools.lock`.")),
                          passed(HerdrBotRelay.reply(from: research.name, "2.4.1 is the newest stable version. 2.5.0 is out as a release candidate only, so I would not pin it yet."), HerdrBotRelay.answer, from: research),
                          passed(HerdrBotRelay.message(from: boppy.name, "Can the build box also publish the design tokens after each build? No hurry."), HerdrBotRelay.message, from: boppy),
                          ChatMessage(role: .assistant, content: "Yes. I added a step that publishes the tokens when a build passes.")]
        jarvis.messages = [ChatMessage(role: .user, content: "Have Infra set up the registry MCP on the build box."),
                           ChatMessage(role: .assistant, content: "I asked Infra to do it and to report back with the version."),
                           AppOnlyLine.line(HerdrMessageLine.sent.render(jarvis.name, infra.name, brief)),
                           passed(HerdrBotRelay.reply(from: infra.name, "Done. Version 2.4.1 is installed and registered for both agent programs; the client lists `search`, `fetch` and `publish`. Nothing was restarted."), HerdrBotRelay.answer, from: infra),
                           ChatMessage(role: .assistant, content: "Infra finished: the registry MCP runs on the build box, version 2.4.1.")]
        // In Jarvis's chat the answer is addressed to Jarvis.
        jarvis.messages[3].metadata[HerdrBotRelay.Key.asker] = id(jarvis)
        return Cast(store: store, jarvis: jarvis, infra: infra, boppy: boppy, research: research, unfolded: first.id)
    }

    static func render(write: (String, Data?) -> Void, png: @MainActor (AnyView, AppStore, NSSize) async -> Data?) async {
        let cast = cast(), chat = NSSize(width: 860, height: 760)
        cast.store.selectedBot = cast.infra
        write(messages[0], await png(AnyView(ChatView(bot: cast.infra).frame(width: chat.width, height: chat.height)), cast.store, chat))
        let tall = NSSize(width: chat.width, height: 1_000)
        write(messages[1], await png(AnyView(ChatView(bot: cast.infra, unfolded: [cast.unfolded]).frame(width: tall.width, height: tall.height)), cast.store, tall))
        cast.store.selectedBot = cast.jarvis
        let small = NSSize(width: chat.width, height: 520)
        write(messages[2], await png(AnyView(ChatView(bot: cast.jarvis).frame(width: small.width, height: small.height)), cast.store, small))
    }
}
