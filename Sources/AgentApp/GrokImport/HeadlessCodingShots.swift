import AppKit
import SwiftUI

/// P31 shots of `--render-setup`: Settings → Models with the SwarmHub-wide "Coding agent" row, a bot editor's Models
/// section with its own coding agent, and the Update banner a changed coding order raises. Synthetic store, mock backend.
@MainActor enum HeadlessCodingShots {
    static let names = ["p31-settings-models", "p31-editor-models", "p31-editor-models-default", "p31-banner-coding-changed"]

    static func render(write: (String, Data?) -> Void, png: @MainActor (AnyView, AppStore, NSSize) async -> Data?) async {
        let store = SetupPreview.makeStore(backendFactory: { _ in MockBackend() }); store.isSetupPreview = false
        let jarvis = Bot(name: "Jarvis", persona: "You are Jarvis.", backend: .hermes, hermesProfile: "grok-jarvis")
        jarvis.canManageBots = true
        let coder = Bot(name: "Coder", persona: "You write code.", backend: .hermes, hermesProfile: "coder")
        coder.modelSettings = BotModelSettings(codingAgent: .codexOnly)
        store.bots = [jarvis, coder]; store.selectedBot = coder
        write(names[0], await png(AnyView(Form { SettingsModelsPane(cache: store.botInfo) }.formStyle(.grouped)), store, NSSize(width: 760, height: 900)))
        for (name, bot) in [(names[1], coder), (names[2], jarvis)] {
            let section = BotModelSettingsSection(cache: store.botInfo, bot: bot, pendingBackend: .hermes, conversation: .constant(.inherit), coding: .constant(.inherit),
                                                  codingAgent: .constant(bot.modelSettings?.codingAgent))
            write(name, await png(AnyView(Form { section }.formStyle(.grouped)), store, NSSize(width: 560, height: 360)))
        }
        // Installed with Claude Code first, now set to Codex only: the existing Update banner.
        if let skill = store.skillLibrary.first(where: { $0.name == "swarmhub-coding" }) {
            coder.installedSkills = [skill.name: skill.version.description]
            coder.installedSkillVariants = [skill.name: CodingOrder.standard.argument]
        }
        write(names[3], await png(AnyView(ChatView(bot: coder)), store, NSSize(width: 760, height: 420)))
    }
}
