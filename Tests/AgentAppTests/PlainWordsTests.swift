import Foundation
import Testing
@testable import AgentApp

// What the person reads instead of the app's internals: a passed-on message without the lines for the agent, an agent
// program by the name people use, a helper's model by its label, and one plain line for what a reply asked for.

@Test func aPassedOnMessageShowsOnlyTheWordsThatAreSomeones() {
    let request = HerdrPassedOn(HerdrBotRelay.request(from: "Boppy", HerdrBotAsk(name: "Legal", purpose: "People keep sending me contracts.")))
    #expect(request.botName == "Legal" && request.body == "People keep sending me contracts.", "a request reads as the name and the purpose: \(request)")
    #expect(HerdrPassedOn(HerdrBotRelay.request(from: "Boppy", HerdrBotAsk(name: "Legal", purpose: ""))).body == "")
    let message = HerdrPassedOn(HerdrBotRelay.message(from: "Boppy", "Which contracts are open?\nI need the list today."))
    #expect(message.botName == nil && message.body == "Which contracts are open?\nI need the list today.")
    #expect(HerdrPassedOn(HerdrBotRelay.reply(from: "Legal", "Two are open.")).body == "Two are open.")
    let outcome = HerdrPassedOn(HerdrBotRelay.answer(from: "Jarvis", [.created("Legal")]))
    #expect(outcome.body == "The bot \"Legal\" you asked for now exists. The person can chat with it.", "the lines for the agent alone are not shown: \(outcome.body)")
    #expect(HerdrPassedOn("Just words.").body == "Just words.")
    // The sidebar reads the same words, never the machine text.
    let row = ChatMessage(role: .user, content: HerdrBotRelay.request(from: "Boppy", HerdrBotAsk(name: "Legal", purpose: "Contracts.")), metadata: [HerdrBotRelay.Key.kind: HerdrBotRelay.request])
    #expect(SidebarFragment.text(messages: [row], draft: nil, isWorking: false, archiveNewest: nil) == "Asks for a new bot: Legal")
}

@Test func anAgentProgramGoesByTheNamePeopleUse() throws {
    #expect(HerdrProgramName.friendly(display: "Claude", program: "Claude Code") == "Claude", "the server's own short name wins")
    #expect(HerdrProgramName.friendly(display: nil, program: "Claude Code") == "Claude" && HerdrProgramName.friendly(display: " ", program: "Codex") == "Codex")
    #expect(HerdrProgramName.friendly(display: nil, program: "Some CLI Agent") == "Some" && HerdrProgramName.friendly(display: nil, program: "Code") == "Code" && HerdrProgramName.friendly(display: nil, program: nil) == nil)
    let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
    let sent = try decoder.decode(HerdrClient.Template.self, from: Data(#"{"name":"swarmhub-one","description":null,"error":null,"runtime":{"harness":"Program One Code","provider":null,"model":null,"display_name":"One"}}"#.utf8))
    #expect(sent.label == "One" && sent.programName == "One", "display_name is read from the server")
    let one = HerdrClient.Template(name: "starter-one", description: nil, error: nil, runtime: .init(harness: "Program One Code", provider: nil, model: nil))
    let again = HerdrClient.Template(name: "starter-one-b", description: nil, error: nil, runtime: .init(harness: "Program One Code", provider: nil, model: nil))
    let two = HerdrClient.Template(name: "starter-two", description: nil, error: nil, runtime: .init(harness: "Two", provider: nil, model: nil))
    #expect(one.label == "Program One", "never the template's name beside the program's")
    #expect(HerdrProgramName.labels(for: [one, two]) == ["starter-one": "Program One", "starter-two": "Two"])
    #expect(HerdrProgramName.labels(for: [one, again, two]) == ["starter-one": "Program One · starter-one", "starter-one-b": "Program One · starter-one-b", "starter-two": "Two"], "only two that would read the same are told apart")
    #expect(HerdrClient.Template(name: "bare", description: nil, error: nil, runtime: nil).label == "bare")
    // A helper reads by its model's label: the server's, else the one the app saw for that id, else the id.
    HerdrModelNames.remember([.init(id: "test-model-x", label: "Model X 2.0")])
    let helper = HerdrClient.Helper(address: "t1", createdMs: 1, name: "h", model: "test-model-x", difficulty: "easy", state: "live")
    #expect(helper.runLine == "Model X 2.0" && helper.difficultyLine == "Easy task")
    #expect(HerdrClient.Helper(address: "t1", createdMs: 1, name: "h", model: "test-model-x", modelLabel: "From the server", state: "live").runLine == "From the server")
    #expect(HerdrClient.Helper(address: "t1", createdMs: 1, name: "h", model: "never-seen", state: "live").runLine == "never-seen")
}

@Test func whatAReplyAskedForReadsAsOnePlainLine() {
    func lines(_ json: String) -> [String] { SwarmhubSummary.lines(in: "Done.\n\n```swarmhub\n\(json)\n```").map(\.summary) }
    #expect(lines(#"{"op":"create_bot","name":"Legal"}"#) == ["Suggested a new bot: Legal"])
    #expect(lines(#"{"op":"message_bot","to":"Boppy","message":"hi"}"#) == ["Wrote to Boppy"])
    #expect(lines(#"{"op":"something_new"}"#).isEmpty && lines("not json").isEmpty, "a block the app does not know gets no line")
    #expect(HerdrSkillsCopy.readable("code-review") == "Code review" && HerdrSkillsCopy.readable("brand") == "Brand")
}
