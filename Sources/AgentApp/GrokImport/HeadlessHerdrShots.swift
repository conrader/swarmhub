import AppKit
import SwiftUI

/// Herdr shots of `--render-setup` (alone with `--only herdr`): the setup window's Herdr path (where it runs, this Mac
/// with nothing running, SSH, address, starter agents), Settings → Servers and keys with two servers, the simple page,
/// a Herdr bot's and a Hermes bot's Advanced settings, and a bot's request to create bots waiting above the composer.
/// All synthetic and in memory: Test results are built here, no server has a token, nothing connects.
@MainActor enum HeadlessHerdrShots {
    static let names = ["herdr-s1-where", "herdr-s3-this-mac-nothing", "herdr-s3-ssh", "herdr-s3-ssh-failed", "herdr-s3-address", "herdr-s4-starters",
                        "herdr-settings-servers", "herdr-settings-simple", "herdr-editor-advanced", "herdr-editor-move", "herdr-bot-request"]

    static func render(write: (String, Data?) -> Void, png: @MainActor (AnyView, AppStore, NSSize) async -> Data?) async {
        let store = SetupPreview.makeStore(backendFactory: { _ in MockBackend() }); store.isSetupPreview = false
        let wizard = HeadlessSetup.size
        let box = HerdrServer(id: "box1", name: "Studio server", kind: .ssh, address: HerdrServer.loopback(port: HerdrServer.defaultPort), sshHost: "studio.example.com", sshUser: "deploy")

        var nothing = SetupFlow(); nothing.apply(.pickHerdr(.local)); nothing.apply(.herdrTest(.nothingHere(port: HerdrServer.defaultPort)))
        var ssh = SetupFlow(); ssh.apply(.pickHerdr(.ssh)); ssh.herdr.sshHost = "studio.example.com"; ssh.herdr.sshUser = "deploy"; ssh.herdr.sshKeyPath = "~/.ssh/id_ed25519"
        var failed = ssh; failed.apply(.herdrTest(.failed(HerdrTunnel.Failure.ended("deploy@studio.example.com: Permission denied (publickey).").localizedDescription)))
        var address = SetupFlow(); address.apply(.pickHerdr(.address)); address.herdr.address = "http://127.0.0.1:8787"
        let starters = [HerdrStarter(template: "starter-one", name: "Claude", title: "Claude Code on Herdr", model: nil), HerdrStarter(template: "starter-two", name: "Codex", title: "Codex on Herdr", model: nil)]
        var choose = ssh; choose.apply(.herdrTest(.connected(server: box, key: nil, starters: starters))); choose.preselect(alreadyAdded: [])
        for (name, flow) in [(names[0], SetupFlow()), (names[1], nothing), (names[2], ssh), (names[3], failed), (names[4], address), (names[5], choose)] {
            write(name, await png(AnyView(SetupView(preset: flow)), store, wizard))
        }

        store.saveHerdrServer(store.herdrServers[0], token: nil); store.saveHerdrServer(box, token: nil)
        let jarvis = Bot(name: "Jarvis", title: "Chief of staff", persona: "You run the team.", backend: .herdr); jarvis.canManageBots = true
        let infra = Bot(name: "Infra", title: "Boxes and backups", backend: .hermes, hermesProfile: "grok-infra")
        store.bots = [jarvis, infra]; store.setHerdrServer(box.id, for: jarvis)
        let settings = NSSize(width: 760, height: 1_240)
        write(names[6], await png(AnyView(Form { SettingsAccountPane(cache: store.botInfo) }.formStyle(.grouped).frame(width: settings.width, height: settings.height).background(AppColor.panel)), store, settings))
        write(names[7], await png(AnyView(SettingsSimplePane(openAdvanced: {})), store, HeadlessSetup.settingsSize))
        let editor = NSSize(width: 560, height: 980)
        for (name, bot) in [(names[8], jarvis), (names[9], infra)] {
            write(name, await png(AnyView(Form { BotEditorAdvancedSection(bot: bot, fields: .constant(BotEditorFields(bot: bot))) }.formStyle(.grouped)
                .frame(width: editor.width, height: editor.height).background(AppColor.panel)), store, editor))
        }
        let block = "```swarmhub\n[{\"op\":\"create_bot\",\"name\":\"Research\",\"instructions\":\"You find and check sources, and answer with links.\",\"avatar\":{\"shape\":\"star\",\"colour\":\"blue\"}},{\"op\":\"create_bot\",\"name\":\"Writer\",\"instructions\":\"You turn notes into clear drafts.\",\"runtime\":\"Codex\"}]\n```"
        jarvis.messages = [ChatMessage(role: .user, content: "Create two bots: one for research and one for writing."), ChatMessage(role: .assistant, content: "I proposed Research and Writer.\n\n" + block)]
        let card = NSSize(width: 760, height: 220)
        write(names[10], await png(AnyView(HerdrBotRequestCard(manager: jarvis).frame(width: card.width, height: card.height).background(AppColor.chat)), store, card))
    }
}
