import Foundation
import Testing
@testable import AgentApp

// P51: folds in the store: unfold state per row and memory only, names from the store, groups name each author.

@MainActor private func makeStore() -> AppStore {
    AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { _ in MockBackend() }, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
}

@MainActor @Test func unfoldingIsPerRowAndNotSaved() {
    let url = temporaryStore()
    let first = AppStore(storeURL: url, autoConfigureHermes: false, backendFactory: { _ in MockBackend() }, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let a = UUID(), b = UUID()
    #expect(!first.technicalFolds.isOpen(TechnicalFolds.key(a)), "rows start folded")
    first.technicalFolds.toggle(TechnicalFolds.key(a))
    #expect(first.technicalFolds.isOpen(TechnicalFolds.key(a)) && !first.technicalFolds.isOpen(TechnicalFolds.key(b)))
    #expect(!first.technicalFolds.isOpen(TechnicalFolds.key(a, "all")), "Show all is its own switch")
    first.save()
    let second = AppStore(storeURL: url, autoConfigureHermes: false, backendFactory: { _ in MockBackend() }, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    #expect(second.technicalFolds.open.isEmpty, "a relaunch starts folded")
    first.technicalFolds.toggle(TechnicalFolds.key(a))
    #expect(first.technicalFolds.open.isEmpty)
}

@MainActor @Test func theStoreNamesBotsByProfileAndGroupsByAuthor() {
    let store = makeStore()
    let jarvis = Bot(name: "Jarvis", backend: .hermes, hermesProfile: "grok-jarvis"), infra = Bot(name: "Infra", backend: .hermes, hermesProfile: "grok-infra")
    store.bots = [jarvis, infra]
    let asked = ChatMessage(role: .user, content: "[Message from grok-infra via SwarmHub]\nDisk at 91%?")
    #expect(store.technicalLayout([asked], botName: jarvis.name).folds[asked.id]?.summary == "Infra → Jarvis: Disk at 91%?")
    let group = GroupChat(name: "Ops", memberIDs: [jarvis.id, infra.id])
    let request = ChatMessage(role: .assistant, content: "[[SWARMHUB_APP_REQUEST_00000000-0000-4000-8000-0000000051A1]]\n{\"action\":\"execute\",\"tool\":\"SLACK_SEND_MESSAGE\",\"arguments\":{}}", authorID: infra.id)
    let normal = ChatMessage(role: .assistant, content: "Sent.", authorID: infra.id)
    let layout = store.technicalLayout([request, normal], in: group)
    #expect(layout.folds[request.id]?.summary == "Infra used Slack · Send message · no result")
    #expect(layout.folds[normal.id] == nil && layout.visible([request, normal]).count == 2)
}
