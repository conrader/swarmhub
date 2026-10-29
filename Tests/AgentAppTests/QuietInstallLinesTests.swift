import Foundation
import Testing
@testable import AgentApp

// uxfix3: Hermes 0.22 never reports the peer-plugin enable receipt on this API, so every bot of an all-bots install
// ended "unverified" (17 warning lines, uxfix1-e2e). The skills are in: that line is a note now. A receipt that shows
// a failed enable, a block, or a failed install stays a warning.

@MainActor @Test func anUnreportedPeerEnableIsANoteNotAWarning() {
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore([:]), defaults: isolatedDefaults())
    let manager = Bot(name: "Jarvis", backend: .hermes, hermesProfile: "grok-jarvis"), bot = Bot(name: "Boppy", backend: .hermes, hermesProfile: "grok-boppy")
    store.bots = [manager, bot]
    let quiet = SkillInstallResult.unconfirmedPeerEnable(profile: "grok-boppy")
    #expect(quiet.status == .peerEnableUnverified && quiet.isInfo && quiet.detail.contains("hermes -p grok-boppy plugins list"))
    store.recordSkillInstallResult(quiet, bot: bot, manager: manager)
    #expect(manager.messages.last?.metadata[TurnKey.tone] == nil, "no warning triangle")
    #expect(store.chatHistory(manager, excluding: ChatMessage(role: .assistant, content: "")).isEmpty, "a result line is never sent to the model")
    for loud in [SkillInstallResult(status: .failed, detail: "Skills not fully installed: x"),
                 SkillInstallResult(status: .peerEnableBlocked, detail: PeerPluginEnablement.blockedDetail),
                 SkillInstallResult(status: .peerEnableUnverified, detail: "Peer plugin installed; enablement not verified (enable exit 1, list exit 0).")] {
        #expect(!loud.isInfo)
        store.recordSkillInstallResult(loud, bot: bot, manager: manager)
        #expect(manager.messages.last?.metadata[TurnKey.tone] == "warning")
    }
}
