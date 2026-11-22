import Foundation
import Testing
@testable import AgentApp

// A program the server marks as beta ("Gemini (beta)"): its name and note as the server sends them, its place in
// the lists, the name of a bot on it, and its tool calls and questions in the chat's own words.

private func model(_ id: String, _ label: String? = nil) -> HerdrClient.Template.Model { .init(id: id, label: label) }

private let geminiProgram = HerdrProgram(template: "swarmhub-gemini", name: "Gemini (beta)", takesModel: true, models: [model("auto", "Auto"), model("pro", "Pro")],
                                  modelAgent: "Gemini CLI", beta: true, note: "Gemini is in beta: a reply arrives all at once.")
private let codexProgram = HerdrProgram(template: "swarmhub-codex", name: "Codex", takesModel: true, models: [])
private let claudeProgram = HerdrProgram(template: "swarmhub-claude", name: "Claude", takesModel: true, models: [])

@Test func aBetaProgramIsReadWithItsNameAndItsNote() throws {
    let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
    let sent = try decoder.decode(HerdrClient.Template.self, from: Data(#"{"name":"swarmhub-gemini","description":"Gemini CLI (beta)","error":null,"runtime":{"harness":"Gemini CLI","provider":"Google","model":null,"display_name":"Gemini (beta)"},"models":[{"id":"auto","label":"Auto","provider":"Google"}],"model_agent":"Gemini CLI","beta":true,"note":"Gemini is in beta: a reply arrives all at once."}"#.utf8))
    #expect(sent.beta == true && sent.note == "Gemini is in beta: a reply arrives all at once.")
    #expect(sent.label == "Gemini (beta)" && sent.programName == "Gemini (beta)" && sent.takesModel, "every list shows the server's name")
    let plain = try decoder.decode(HerdrClient.Template.self, from: Data(#"{"name":"swarmhub-codex","description":null,"error":null,"runtime":{"harness":"Codex","provider":null,"model":null,"display_name":"Codex"}}"#.utf8))
    #expect(plain.beta == nil && plain.note == nil, "a server from before betas sends neither")
    // A main bot asked for a bot "on gemini" gets this program, by its real name or the one people read.
    #expect(HerdrBotRequest.template(for: "gemini", in: [plain, sent])?.name == "swarmhub-gemini")
    #expect(HerdrBotRequest.template(for: "Gemini (beta)", in: [plain, sent])?.name == "swarmhub-gemini")
}

@Test func aBetaProgramIsNeverTheDefaultWhileAnotherIsOffered() {
    #expect(HerdrOffer.betaLast([geminiProgram, codexProgram, claudeProgram]).map(\.template) == ["swarmhub-codex", "swarmhub-claude", "swarmhub-gemini"])
    #expect(HerdrOffer.betaLast([codexProgram, claudeProgram]).map(\.template) == ["swarmhub-codex", "swarmhub-claude"], "the server's order is kept")
    #expect(HerdrOffer.betaLast([geminiProgram]).map(\.template) == ["swarmhub-gemini"], "alone, it is the one there is")
    // The wizard's main bot starts on the first program of the offer.
    var draft = HerdrMainBotDraft()
    draft.begin(offer: HerdrOffer(programs: HerdrOffer.betaLast([geminiProgram, codexProgram])), bots: [])
    #expect(draft.template == "swarmhub-codex" && draft.model == HerdrModelChoice.recommended)
    var only = HerdrMainBotDraft()
    only.begin(offer: HerdrOffer(programs: HerdrOffer.betaLast([geminiProgram])), bots: [])
    #expect(only.template == "swarmhub-gemini")
    // Recommended is the first model the server lists; the app keeps no Gemini model names.
    #expect(HerdrModelChoice.suggested(program: "Gemini CLI", offered: geminiProgram.models)?.id == "auto")
    #expect(geminiProgram.starterName == "gemini")
}

@Test func aBotOnABetaProgramIsNamedWithoutTheMark() {
    #expect(HerdrProgramName.botName("Gemini (beta)") == "Gemini" && HerdrProgramName.botName("Gemini (Beta)") == "Gemini")
    #expect(HerdrProgramName.botName("Codex") == "Codex" && HerdrProgramName.botName(" (beta)") == " (beta)", "a name that is only the mark stays")
    // A bot already called Gemini covers the program, so the wizard does not offer a second one.
    let offer = HerdrOffer(programs: [codexProgram, geminiProgram])
    #expect(offer.others(than: "swarmhub-codex", taken: [], names: []).map(\.template) == ["swarmhub-gemini"])
    #expect(offer.others(than: "swarmhub-codex", taken: [], names: ["gemini"]).isEmpty)
    #expect(offer.label(geminiProgram) == "Gemini (beta)" && offer.names == "Codex and Gemini (beta)")
}

@Test func geminiToolCallsAndQuestionsReadInTheChatsWords() {
    #expect(["run_shell_command", "read_many_files", "list_directory", "grep_search", "search_file_content", "write_file", "replace", "google_web_search", "write_todos"].map(HerdrBackend.toolName)
        == ["bash", "read_file", "read_file", "read_file", "read_file", "edit_file", "edit_file", "web_search", "todo"])
    #expect(HerdrBackend.toolName("read_file") == "read_file" && HerdrBackend.toolName("web_fetch") == "fetch" && HerdrBackend.toolName("save_memory") == "save_memory")
    #expect(ActivityCopy.label(HerdrBackend.toolName("run_shell_command")) == "Running a command")
    // The sign-in question and a question the program asks itself are named by the server's kind.
    #expect(HerdrPrompt.actionable(kind: "auth", screen: "How would you like to authenticate for this project?\n1. Sign in with Google\n(Use Enter to select)"))
    #expect(HerdrPrompt.actionable(kind: "question", screen: "Which of the two files do you mean?"))
    #expect(!HerdrPrompt.actionable(kind: nil, screen: "How would you like to authenticate for this project?"))
    // Refused in its terminal: the composer is back, so nothing is asked any more, whatever the status still says.
    #expect(!HerdrPrompt.actionable(kind: "permission", screen: "> Type your message or @path/to/file\n? for shortcuts"))
}
