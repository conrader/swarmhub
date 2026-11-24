import Foundation
import Testing
@testable import AgentApp

@Test func proseChoicesKeepTheirLabelsAndReplyWithTheirMarkers() {
    let numbered = """
    I can go either way.

    Tell me which way you want to go:

    1. **Build X now** — it can start today.
    2. Ask Infra first: they can confirm the plan.

    (or both)
    """
    #expect(ChatChoiceInference.options(in: numbered) == [
        .init(label: "Build X now", reply: "1"), .init(label: "Ask Infra first", reply: "2"), .init(label: "Both", reply: "Both")
    ])
    #expect(ChatCardParser.parse(numbered) == [.markdown(numbered)])

    let lettered = "Which option would you prefer?\r\nA) __Build__ now\r\nB) Ask Infra first (or both)"
    #expect(ChatChoiceInference.options(in: lettered) == [
        .init(label: "Build", reply: "A"), .init(label: "Ask Infra first", reply: "B"), .init(label: "Both", reply: "Both")
    ])
    let inline = "Tell me which way you want to go: 1. Build X now 2. Ask Infra first (or both)"
    #expect(ChatChoiceInference.options(in: inline)?.map(\.reply) == ["1", "2", "Both"])
    let followUp = "How do you want to proceed?\n1. Build\n2. Ask Infra\n\nYou can also choose both."
    #expect(ChatChoiceInference.options(in: followUp)?.map(\.reply) == ["1", "2", "Both"])
    let long = "Choose one:\n1. Ask the infrastructure team for a full review before starting the migration\n2. Start now"
    #expect(ChatChoiceInference.options(in: long)?.first == .init(label: "Ask the infrastructure team for a full review…", reply: "1"))
}

@Test(arguments: [
    "The draft is ready. Should I send it?",
    "**Would you like me to run the tests?**",
    "Does that cover everything? (Yes/No)",
    "Is the order correct? Yes / No",
]) func finalBinaryQuestionsOfferYesAndNo(_ text: String) {
    #expect(ChatChoiceInference.options(in: text) == [.init(label: "Yes", reply: "Yes"), .init(label: "No", reply: "No")])
}

@Test(arguments: [
    "Steps:\n1. Build\n2. Test",
    "Open questions from the meeting:\n1. When is the release?\n2. Should I run more tests?",
    "How do I install it?\n1. Download the package\n2. Run the installer",
    "First choose the build settings and follow these steps:\n1. Build\n2. Test",
    "Which option did I pick?\n1. I built the package\n2. I ran the tests",
    "Tell me how you did it:\n1. Build\n2. Test",
    "Would you like me to build it or ask Infra?",
    "Should I start?\n\nI already ran the build.",
    "Choose one:\n1. Build\n3. Test",
    "Choose one:\n1. Build\n2. Test\n\nHere are the results.",
    "```text\nWhich way?\n1. Build\n2. Test\n```",
    "~~~text\nWhich way?\n1. Build\n2. Test",
    "    Would you like me to start?",
    "> Which way?\n> 1. Build\n> 2. Test",
    "```choices\nWhich one?\n- Build\n- Test\n```\n\nShould I start?",
    "Which way?\n<!-- choices -->\n1. Build\n2. Test",
]) func ordinaryListsCodeAndExistingCardsDoNotGetInferredChoices(_ text: String) {
    #expect(ChatChoiceInference.options(in: text) == nil)
}

@MainActor @Test func botInstructionsUseTheExistingChoicesFenceAndReachRunningAgentsOnce() throws {
    let note = HerdrBackend.choiceNote
    let fence = try #require(note.range(of: "```choices"))
    #expect(ChatCardParser.parse(String(note[fence.lowerBound...])) == [
        .choices(prompt: "Which way should I go?", options: ["Start now", "Wait for Infra"])
    ])
    let entry = (marker: HerdrBackend.choiceMarker, note: note)
    #expect(HerdrClient.notes(reminder: nil, once: [entry], tasks: ["an earlier message"]) == [note])
    #expect(HerdrClient.notes(reminder: nil, once: [entry], tasks: [note]).isEmpty)
}
