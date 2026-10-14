import Foundation
import Testing
@testable import AgentApp

// P22 pure parts: key derivation, the manager text, the on-demand rule and swarmhub fences (synthetic only).

// MARK: Key derivation

/// Cross-check on any shell (the box computes it the same way):
/// `printf '%s' "swarmhub-bot-key:v1:p22-vanilla-test" | openssl dgst -sha256 -hmac "0123456789abcdef0123456789abcdef" -r | cut -c1-64`
/// → 82793b20bc24b9b067da8df7e7cc92ad0fd219af39fbf553776d7db48cdf1272
@Test func derivedKeyMatchesTheFixedOpenSSLVector() {
    let key = BotManagerText.derivedKey(managerKey: "0123456789abcdef0123456789abcdef", botName: "p22-vanilla-test")
    #expect(key == "82793b20bc24b9b067da8df7e7cc92ad0fd219af39fbf553776d7db48cdf1272")
    #expect(BotManagerText.derivedKey(managerKey: "0123456789abcdef0123456789abcdef", botName: "other") != key)
}

// MARK: Manager text

@Test func managerTextIsBundledAndFilledForDefaultAndNamedProfiles() throws {
    let template = try #require(BotManagerText.template())
    #expect(template.contains("{{MANAGER}}") && template.contains("{{MANAGER_ENV}}") && template.contains("```swarmhub"))
    let named = BotManagerText.filled(template, managerProfile: "grok-jarvis")
    #expect(!named.contains("{{") && named.contains("`grok-jarvis`") && named.contains("~/.hermes/profiles/grok-jarvis/.env"))
    #expect(named.contains("--clone-from grok-jarvis"))
    let standard = BotManagerText.filled(template, managerProfile: "default")
    #expect(standard.contains("`~/.hermes/.env`") && !standard.contains("profiles/default/.env") && !standard.contains("{{"))
}

@Test func packageBundlesTheBotManagerResource() throws {
    let package = try String(contentsOfFile: "Package.swift", encoding: .utf8)
    #expect(package.contains(#".copy("Resources/BotManager")"#))
    let release = try String(contentsOfFile: "scripts/package-release.sh", encoding: .utf8)
    #expect(release.contains(#"Resources/BotManager" "$APP_DIR/Contents/Resources/BotManager""#))
}

// MARK: Intent

@Test(arguments: [
    "Create a bot called rapper that writes lyrics", "make me a new agent for taxes", "Can you add an assistant for travel?",
    "retire the bot p22-test", "please delete bot old-helper", "show me the instructions of grok-rapper", "change its avatar to a red heart",
    "list bots", "Which bots do I have?", "edit the system prompt of the finance agent",
    "Stwórz bota do podatków", "utwórz nowego agenta", "dodaj bota", "zmień instrukcje Rappera", "zmień awatar", "usuń bota test", "lista botów"
])
func managementIntentMatches(_ text: String) { #expect(ManagementIntent.matches(text), "\(text)") }

@Test(arguments: ["Hi Jarvis, how are you?", "yes", "What is the weather in Warsaw?", "Napisz mi maila do szefa", "Add milk to my shopping list", "robot vacuum review"])
func ordinaryTextIsNoManagementIntent(_ text: String) { #expect(!ManagementIntent.matches(text), "\(text)") }

// MARK: Exchange window

@Test func exchangeOpensOnIntentAndKeepsFollowUpsForThreeTurns() {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    var decision = ManagementExchange.decide(text: "create a bot called x", exchange: nil, now: t0)
    #expect(decision.attach && decision.next != nil)
    for turn in 1...3 {
        decision = ManagementExchange.decide(text: "yes", exchange: decision.next, now: t0.addingTimeInterval(Double(turn) * 10))
        #expect(decision.attach, "follow-up \(turn)")
    }
    decision = ManagementExchange.decide(text: "yes", exchange: decision.next, now: t0.addingTimeInterval(40))
    #expect(!decision.attach && decision.next == nil)
}

@Test func exchangeClosesAfterTenMinutes() {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let opened = ManagementExchange.decide(text: "list bots", exchange: nil, now: t0).next
    #expect(ManagementExchange.decide(text: "yes", exchange: opened, now: t0.addingTimeInterval(599)).attach)
    #expect(!ManagementExchange.decide(text: "yes", exchange: opened, now: t0.addingTimeInterval(600)).attach)
}

@Test func ordinaryTextWithoutExchangeIsNotAttached() {
    #expect(!ManagementExchange.decide(text: "good morning", exchange: nil, now: .now).attach)
}

@Test func menuOpeningAttachesTheNextTurnWhateverItSays() {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let menu = ManagementExchange(openedAt: t0, awaitingOpening: true)
    let first = ManagementExchange.decide(text: "x", exchange: menu, now: t0.addingTimeInterval(5))
    #expect(first.attach && first.next?.followUps == 0 && first.next?.awaitingOpening == false)
}

// MARK: swarmhub fences

@Test func parsesTheLastSwarmhubFenceAsObjectOrArray() throws {
    let object = "Done.\n```swarmhub\n{\"op\": \"bot_created\", \"name\": \"p22-vanilla-test\", \"description\": \"Says PONG\", \"avatar\": {\"shape\": \"heart\", \"colour\": \"cyan\"}}\n```"
    #expect(SwarmhubBlock.ops(in: object) == [.botCreated(name: "p22-vanilla-test", description: "Says PONG", avatar: AvatarMark(shape: "heart", colour: "cyan"))])
    let array = "First\n```swarmhub\n{\"op\":\"bot_retired\",\"name\":\"old\"}\n```\nthen\n```swarmhub\n[{\"op\":\"instructions_changed\",\"name\":\"a\"},{\"op\":\"bot_retired\",\"name\":\"b\"}]\n```\n"
    #expect(SwarmhubBlock.ops(in: array) == [.instructionsChanged(name: "a"), .botRetired(name: "b")])
    let list = "```swarmhub\n{\"op\":\"bots\",\"list\":[{\"name\":\"x\",\"description\":\"X\"},{\"name\":\"bad name\"}]}\n```"
    #expect(SwarmhubBlock.ops(in: list) == [.bots([.init(name: "x", description: "X")])])
}

@Test func malformedOrUnknownBlocksAreIgnored() {
    #expect(SwarmhubBlock.ops(in: "no block here") == nil)
    #expect(SwarmhubBlock.ops(in: "```swarmhub\n{not json\n```") == [])
    #expect(SwarmhubBlock.ops(in: "```swarmhub\n[{\"op\":\"format_disk\"},{\"op\":\"avatar\",\"name\":\"a\",\"shape\":\"dragon\",\"colour\":\"red\"},{\"name\":\"x\"},{\"op\":\"bot_created\",\"name\":\"../etc\"}]\n```") == [])
    #expect(SwarmhubBlock.ops(in: "```json\n{\"op\":\"bot_retired\",\"name\":\"a\"}\n```") == nil)
}

@Test func swarmhubFencesAreHiddenFromTheChatView() {
    let reply = "Created **Rapper**.\n\n```swarmhub\n{\"op\":\"bot_created\",\"name\":\"rapper\"}\n```"
    #expect(SwarmhubBlock.visibleText(reply) == "Created **Rapper**.")
    #expect(!ChatCardParser.parse(SwarmhubBlock.visibleText(reply)).contains { if case .code = $0 { true } else { false } })
    #expect(SwarmhubBlock.visibleText("Streaming…\n```swarmhub\n{\"op\":") == "Streaming…")
    #expect(SwarmhubBlock.visibleText("```swift\nlet x = 1\n```") == "```swift\nlet x = 1\n```")
}
