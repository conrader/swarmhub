import Foundation
import Testing
@testable import AgentApp

// P45 6: `@` in a 1:1 chat builds the bot-msg hand-off; a bot without swarmhub-messages gets the install offer first.
// Scripted backend; no network.

@MainActor private func mentionStore(_ backend: ScriptedTurnBackend, skilled: Bool) -> (AppStore, Bot) {
    let (store, jarvis) = steerStore(backend)
    jarvis.name = "Jarvis"; jarvis.hermesProfile = "grok-jarvis"
    if skilled { for skill in store.skillLibrary where AppStore.messagingSkills.contains(skill.name) { jarvis.installedSkills[skill.name] = skill.version.description } }
    let infra = Bot(name: "Infra", backend: .hermes, hermesProfile: "grok-infra")
    let infraOps = Bot(name: "Infra Ops", backend: .hermes, hermesProfile: "grok-infra-ops")
    let elsewhere = Bot(name: "Elsewhere", backend: .hermes, hermesProfile: "grok-other"); elsewhere.hermesBaseURL = "https://other.example.com/v1"
    store.bots += [infra, infraOps, elsewhere]
    return (store, jarvis)
}

@Test func aLeadingMentionIsParsedLongestNameFirst() {
    let names = ["Infra", "Infra Ops"]
    #expect(MentionHandOff.parse("@Infra is the disk ok?", names: names)! == ("Infra", "is the disk ok?"))
    #expect(MentionHandOff.parse("@infra ops: restart nginx", names: names)! == ("Infra Ops", "restart nginx"))
    #expect(MentionHandOff.parse("@Infrastructure plan", names: names) == nil, "a longer word is not the name")
    #expect(MentionHandOff.parse("ask @Infra later", names: names) == nil && MentionHandOff.parse("@Infra", names: names) == nil)
}

@MainActor @Test func theMentionPickerOffersBotsOnTheSameConnection() {
    let (store, jarvis) = mentionStore(ScriptedTurnBackend(), skilled: true)
    #expect(store.mentionTargets(for: jarvis).map(\.name) == ["Infra", "Infra Ops"])
    #expect(GroupRouting.suggestions(for: "In", names: store.mentionTargets(for: jarvis).map(\.name)) == ["Infra", "Infra Ops"])
}

@MainActor @Test func atBotInAOneToOneChatSendsTheHandOff() async throws {
    let backend = ScriptedTurnBackend(); let (store, jarvis) = mentionStore(backend, skilled: true)
    #expect(store.submitComposer(text: "@Infra is the backup disk healthy?"))
    try await backend.calls.wait { $0.contains { $0.hasPrefix("send:[SwarmHub hand-off]") } }
    let sent = try #require(backend.calls.all.first { $0.hasPrefix("send:") })
    #expect(sent.contains("pass this message to Infra (Hermes profile `grok-infra`) with SwarmHub's bot-msg") && sent.hasSuffix("Message for Infra:\nis the backup disk healthy?"))
    let row = try #require(jarvis.messages.first { $0.role == .user })
    #expect(row.metadata[AutomationKey.display] == "@Infra is the backup disk healthy?", "the bubble shows what was typed")
    await backend.emit(.token("Asked Infra."), .completed); await backend.end()
    try await waitUntil { !store.anyTurnRunning }
}

@MainActor @Test func withoutTheMessagingSkillTheInstallIsOfferedFirst() async throws {
    let backend = ScriptedTurnBackend(); let (store, jarvis) = mentionStore(backend, skilled: false)
    #expect(!store.submitComposer(text: "@Infra ping"), "the draft stays")
    #expect(store.mentionSkillOffer == jarvis.id && jarvis.messages.isEmpty && backend.calls.all.isEmpty)
    // Plain text and unknown names are untouched.
    #expect(store.mentionSend("@Nobody hello", in: jarvis) == .none && store.mentionSend("hello @Infra", in: jarvis) == .none)
}
