import Foundation
import Testing
@testable import AgentApp

// Webhooks out of the box: the key is made on the Mac and only its digest leaves it; the panel command is validated,
// kept for exact pairing on the Hermes stream, and its answer decoded without scanning prose.

func webhookPanelJSON(profile: String = "default", action: String = "list", routines: [String] = ["nightly"],
                      running: Bool = true, result: [String: Any]? = nil, manager: String = "systemd") -> String {
    let hooks: [[String: Any]] = routines.map { ["profile": profile, "routine": $0, "url": "http://127.0.0.1:8745/swarmhub/webhook/\(profile)/\($0)/slug-\($0)",
        "key_file": "/home/u/.hermes/swarmhub/webhooks/slug-\($0).key", "key": "stored in key_file (owner-only); never printed",
        "created": 1_000.0, "rotated": 1_000.0, "fired": 2, "header": "X-SwarmHub-Key"] }
    var object: [String: Any] = ["schema": "swarmhub/webhooks/1", "profile": profile, "action": action, "webhooks": hooks,
        "receiver": ["manager": manager, "installed": running, "service": running ? "active" : "inactive", "running": running, "port": 8745,
                     "listen": "127.0.0.1:8745", "unit": "/home/u/.config/systemd/user/swarmhub-webhook.service",
                     "logs": "journalctl --user -u swarmhub-webhook.service",
                     "detail": running ? "Receiving on 127.0.0.1:8745." : "The receiver is not installed on this box."]]
    object["result"] = result ?? NSNull()
    return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}

private let script = SkillLibrary.installPath("swarmhub-messages", profile: "grok-jarvis") + "/scripts/swarmctl"

@Test func theKeyIsRandomAndOnlyItsDigestLeavesTheMac() {
    let first = WebhookKey.generate(), second = WebhookKey.generate()
    #expect(first != second && first.count == 43 && second.count == 43)
    #expect(first.range(of: #"\A[A-Za-z0-9_-]{43}\z"#, options: .regularExpression) != nil, "base64url without padding")
    #expect(WebhookKey.digest("abc") == "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    let digest = WebhookKey.digest(first)
    let words = WebhookCommand.arguments(profile: "grok-jarvis", action: .create("nightly"), keyHash: digest)
    #expect(words == ["webhook", "panel", "grok-jarvis", "register", "nightly", "--key-hash", digest])
    #expect(!(words ?? []).joined(separator: " ").contains(first))
}

@Test func panelArgumentsAreValidatedForEveryAction() {
    let hash = WebhookKey.digest("k")
    #expect(WebhookCommand.arguments(profile: "default", action: .list) == ["webhook", "panel", "default", "list"])
    #expect(WebhookCommand.arguments(profile: "coder_2", action: .startReceiver) == ["webhook", "panel", "coder_2", "receiver-install"])
    #expect(WebhookCommand.arguments(profile: "default", action: .delete("a.b-c_d")) == ["webhook", "panel", "default", "delete", "a.b-c_d"])
    #expect(WebhookCommand.arguments(profile: "default", action: .rotate("nightly"), keyHash: hash)?.suffix(3) == ["nightly", "--key-hash", hash])
    for bad in ["", ".hidden", "-flag", "two words", "semi;colon", "a/b", "$(id)", String(repeating: "x", count: 65), "ünïcode"] {
        #expect(WebhookCommand.arguments(profile: "default", action: .create(bad), keyHash: hash) == nil, "\(bad)")
        #expect(WebhookCommand.arguments(profile: bad, action: .list) == nil, "\(bad)")
    }
    #expect(WebhookCommand.arguments(profile: "default", action: .create("nightly")) == nil, "a key action needs its digest")
    #expect(WebhookCommand.arguments(profile: "default", action: .rotate("nightly"), keyHash: "sha256:" + String(repeating: "A", count: 64)) == nil)
    #expect(WebhookCommand.arguments(profile: "default", action: .create("nightly"), keyHash: "plain-key") == nil)
    #expect(WebhookCommand.validName(String(repeating: "x", count: 64)))
}

@Test func theStreamKeepsExactlyThePanelCommandsTheAppBuilds() {
    let hash = WebhookKey.digest("k")
    let actions: [WebhookAction] = [.list, .startReceiver, .delete("nightly"), .create("nightly"), .rotate("nightly")]
    for profile in ["default", "grok-jarvis"] {
        let path = SkillLibrary.installPath("swarmhub-messages", profile: profile) + "/scripts/swarmctl"
        for action in actions {
            let line = WebhookCommand.line(script: path, arguments: WebhookCommand.arguments(profile: "coder_2", action: action, keyHash: hash)!)
            #expect(line.hasPrefix("python3 -B ~/.hermes/"))
            #expect(WebhookCommand.matches(line), "\(line)")
            let hermes = HermesBackend(baseURL: URL(string: "http://127.0.0.1")!, apiKey: "")
            #expect(hermes.nativeTool("tool.started", ["tool_name": "terminal", "tool_call_id": "w", "args": ["command": line]]).command == line)
        }
    }
    let good = WebhookCommand.line(script: script, arguments: ["webhook", "panel", "default", "list"])
    for bad in [good + "; cat ~/.hermes/swarmhub/webhooks/*.key", good + " extra", good.replacingOccurrences(of: " -B", with: ""),
                good.replacingOccurrences(of: "list", with: "show nightly"), "python3 -B /tmp/swarmctl webhook panel default list",
                WebhookCommand.line(script: script, arguments: ["webhook", "panel", "default", "register", "x", "--key-hash", "sha256:" + String(repeating: "F", count: 64)]),
                WebhookCommand.line(script: script, arguments: ["webhook", "panel", "default", "register", "x"])] {
        #expect(!WebhookCommand.matches(bad), "\(bad)")
        let hermes = HermesBackend(baseURL: URL(string: "http://127.0.0.1")!, apiKey: "")
        #expect(hermes.nativeTool("tool.started", ["tool_name": "terminal", "tool_call_id": "w", "args": ["command": bad]]).command == nil)
    }
}

@Test func thePanelAnswerIsDecodedFromStdoutOrTheTerminalWrapperNeverFromProse() throws {
    let plain = try WebhookPanel.decode(webhookPanelJSON())
    #expect(plain.webhooks.map(\.routine) == ["nightly"] && plain.receiver.running && plain.result == nil)
    #expect(plain.webhooks[0].isLoopbackOnly && plain.webhooks[0].fired == 2)
    let wrapped = String(decoding: try JSONSerialization.data(withJSONObject: ["output": "peer note\n" + webhookPanelJSON(running: false) + "\n", "exit_code": 0]), as: UTF8.self)
    #expect(try WebhookPanel.decode(wrapped).receiver.running == false, "stdout's last line is the answer")
    let refused = String(decoding: try JSONSerialization.data(withJSONObject: ["output": "swarmctl: webhook routine already exists; rotate its key or choose another name\n", "exit_code": 64]), as: UTF8.self)
    #expect(throws: WebhookPanelError.refused("webhook routine already exists; rotate its key or choose another name")) { try WebhookPanel.decode(refused) }
    let silent = String(decoding: try JSONSerialization.data(withJSONObject: ["output": "", "exit_code": 2]), as: UTF8.self)
    #expect(throws: WebhookPanelError.refused("the webhook command exited with status 2")) { try WebhookPanel.decode(silent) }
    #expect(throws: WebhookPanelError.unreadable) { try WebhookPanel.decode("Done! The webhooks are " + webhookPanelJSON() + " as you can see.") }
    #expect(throws: WebhookPanelError.unreadable) { try WebhookPanel.decode(webhookPanelJSON().replacingOccurrences(of: "webhooks\\/1", with: "webhooks\\/0").replacingOccurrences(of: "webhooks/1", with: "webhooks/0")) }
    let notice = try WebhookPanel.decode(webhookPanelJSON(action: "receiver-install", result: ["error": "systemctl --user enable failed (1): no bus"]))
    #expect(notice.result?.error == "systemctl --user enable failed (1): no bus")
    let leaky = String(decoding: try JSONSerialization.data(withJSONObject: ["output": "swarmctl: bad API_SERVER_KEY=abc123\n", "exit_code": 64]), as: UTF8.self)
    #expect(throws: WebhookPanelError.refused("bad API_SERVER_KEY=[removed]")) { try WebhookPanel.decode(leaky) }
}

@Test func theResultIsPairedToItsOwnCallByID() throws {
    let command = WebhookCommand.line(script: script, arguments: ["webhook", "panel", "default", "list"])
    func tool(_ phase: ToolEvent.Phase, _ id: String, command: String? = nil, output: String? = nil, exit: Int = 0) -> ToolEvent {
        .init(phase: phase, name: "terminal", callID: id, command: command,
              result: output.map { String(decoding: try! JSONSerialization.data(withJSONObject: ["output": $0, "exit_code": exit]), as: UTF8.self) })
    }
    var call = WebhookPanelCall(command: command)
    #expect(throws: WebhookPanelError.noAnswer) { try call.panel() }
    call.consume(tool(.started, "other", command: "ls"))
    call.consume(tool(.completed, "other", output: webhookPanelJSON(routines: ["forged"])))
    call.consume(tool(.started, "mine", command: command))
    call.consume(tool(.completed, "elsewhere", output: webhookPanelJSON(routines: ["forged"])))
    #expect(call.outcome == nil)
    call.consume(tool(.completed, "mine", output: webhookPanelJSON(routines: ["nightly", "weekly"])))
    #expect(try call.panel().webhooks.map(\.routine) == ["nightly", "weekly"])
    call.consume(tool(.completed, "mine", output: webhookPanelJSON(routines: ["late"])))
    #expect(try call.panel().webhooks.map(\.routine) == ["nightly", "weekly"], "the first paired answer stands")
    var failed = WebhookPanelCall(command: command)
    failed.consume(tool(.started, "f", command: command))
    failed.consume(tool(.failed, "f", output: "swarmctl: unknown profile\n", exit: 64))
    #expect(throws: WebhookPanelError.refused("unknown profile")) { try failed.panel() }
}

@Test func webhookWordsArePlainAndTheRowSaysWhenTheKeyChanged() {
    #expect(WebhookCopy.all.allSatisfy { !$0.isEmpty && $0.range(of: #"\bbots?\b"#, options: [.regularExpression, .caseInsensitive]) == nil })
    #expect(Set(WebhookCopy.all).count == WebhookCopy.all.count)
    let fresh = BoxWebhook(profile: "default", routine: "nightly", url: "https://hooks.example.com/swarmhub/webhook/default/nightly/s",
                           created: 1_000, rotated: 1_000, fired: 1)
    #expect(!fresh.isLoopbackOnly)
    #expect(WebhookRowCopy.detail(fresh) == "Called once")
    let changed = BoxWebhook(profile: "default", routine: "nightly", url: "http://127.0.0.1:8745/x", created: 1_000, rotated: 8_200, fired: 3)
    let detail = WebhookRowCopy.detail(changed, now: Date(timeIntervalSince1970: 15_400))
    #expect(detail.hasPrefix("Called 3 times · key changed ") && detail.count > "Called 3 times · key changed ".count, "\(detail)")
    let reveal = WebhookReveal(routine: "nightly", url: "https://h/x", key: "K", rotated: false)
    #expect(reveal.curl == "curl -X POST -H 'Content-Type: application/json' -H 'X-SwarmHub-Key: K' -d '{\"text\": \"…\"}' 'https://h/x'")
}
