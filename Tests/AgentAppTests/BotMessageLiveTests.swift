import Foundation
import Testing
@testable import AgentApp

// P41 2: bot-to-bot messages visible while they happen. Parsing the live command (2026-10-15) from the full command
// line, never the 80-character preview. Synthetic only.

/// Jarvis's terminal command on the box; the script path alone is 88 characters.
let liveBotMsgCommand = "/home/hermes/.hermes/profiles/grok-jarvis/skills/swarmhub/swarmhub-messages/scripts/bot-msg --from grok-jarvis --to grok-infra --wait 300 -- 'Can you check the backup disk on box 2?'"

@Test(arguments: [
    (liveBotMsgCommand, "grok-jarvis", "Can you check the backup disk on box 2?"),
    ("bot-msg --to grok-infra --from grok-jarvis --wait 300 -- hi", "grok-jarvis", "hi"),
    ("../scripts/bot-msg --wait 60 --to grok-infra -- 'relative'", nil, "relative"),
    ("cd ~ && \"$HOME/.hermes/skills/swarmhub/swarmhub-messages/scripts/bot-msg\" --to grok-infra -- quoted", nil, "quoted"),
    ("sh scripts/bot-msg.sh --to grok-infra -- 'tell coder: use --to coder next time'", nil, "tell coder: use --to coder next time")
] as [(String, String?, String)])
func liveBotMsgCommandsParse(_ command: String, _ from: String?, _ text: String) throws {
    let call = try #require(BotMessageCall.parse(command: command))
    #expect(call.to == "grok-infra" && call.from == from && call.text == text)
}

@Test func theLiveCommandsPreviewIsCutBeforeTheRecipient() {
    let preview = ToolEvent.preview(liveBotMsgCommand)
    #expect(preview?.count == ToolEvent.previewLimit && preview?.contains("--to") == false, "the 80-character cut loses --to")
}

@Test func aStreamWithoutArgsStillGivesTheWholeCommand() throws {
    let backend = HermesBackend(baseURL: URL(string: "http://127.0.0.1:8642/v1")!, apiKey: "sk-synthetic-key", profile: "grok-jarvis")
    let started = backend.nativeTool("tool.started", ["tool_name": "terminal", "tool_call_id": "c1", "preview": liveBotMsgCommand])
    #expect(started.preview?.count == ToolEvent.previewLimit, "the shown preview stays short")
    #expect(started.command == liveBotMsgCommand)
    var activity = ToolActivity()
    activity.apply(started, at: Date(timeIntervalSince1970: 1_000))
    #expect(activity.steps[0].botMessage?.to == "grok-infra" && activity.steps[0].botMessage?.from == "grok-jarvis")
    // The legacy stream's label works the same way.
    let legacy = backend.legacyTool(["tool": "terminal", "label": liveBotMsgCommand, "toolCallId": "c2", "status": "running"])
    #expect(legacy.command == liveBotMsgCommand)
    // A preview is never parsed: a cut command with no `command` gives no call.
    var cut = ToolActivity()
    cut.apply(ToolEvent(phase: .started, name: "terminal", preview: "bot-msg --to grok-infra -- hi"), at: .now)
    #expect(cut.steps[0].botMessage == nil)
    // Other commands are not kept, and a key in the line is removed.
    #expect(backend.nativeTool("tool.started", ["tool_name": "terminal", "preview": "ls -la"]).command == nil)
    let keyed = backend.nativeTool("tool.started", ["tool_name": "terminal", "preview": "bot-msg --to grok-infra -- 'sk-synthetic-key'"])
    #expect(keyed.command?.contains("sk-synthetic-key") == false)
}
