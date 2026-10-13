import Foundation
import Testing
@testable import AgentApp

// P13: the pure role policy (resolve, Codable, reasons, the listed-only rule). Synthetic names only.

private let alpha = ModelChoice(provider: "lab-one", model: "model-alpha")!
private let beta = ModelChoice(provider: "lab-one", model: "model-beta")!
private let coder = ModelChoice(provider: "lab-coder", model: "model-coder")!

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T { try JSONDecoder().decode(type, from: Data(json.utf8)) }
private func encoded<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

// MARK: Resolve

@Test func conversationResolvesBotThenOptOutThenTorvliDefaultThenBox() {
    let withDefault = ModelDefaults(conversation: alpha)
    let cases: [(ModelSetting, ModelDefaults?, ResolvedModel)] = [
        (.inherit, nil, .init(choice: nil, source: .boxDefault)),
        (.inherit, withDefault, .init(choice: alpha, source: .torvliDefault)),
        (.box, nil, .init(choice: nil, source: .boxDefault)),
        (.box, withDefault, .init(choice: nil, source: .boxDefault)),
        (.choice(beta), nil, .init(choice: beta, source: .bot)),
        (.choice(beta), withDefault, .init(choice: beta, source: .bot)),
    ]
    for (setting, defaults, expected) in cases {
        #expect(ModelPolicy.resolve(role: .conversation, settings: .init(conversation: setting), defaults: defaults) == expected, "\(setting) with \(String(describing: defaults))")
    }
    #expect(ModelPolicy.resolve(role: .conversation, settings: nil, defaults: nil) == .init(choice: nil, source: .boxDefault), "the display's nil inputs read box default")
}

@Test func codingFallsThroughToConversation() {
    let both = ModelDefaults(conversation: alpha, coding: coder), conversationOnly = ModelDefaults(conversation: alpha)
    let cases: [(ModelSetting, ModelSetting, ModelDefaults?, ResolvedModel)] = [
        (.inherit, .inherit, nil, .init(choice: nil, source: .sameAsConversation)),
        (.inherit, .inherit, conversationOnly, .init(choice: alpha, source: .sameAsConversation)),
        (.inherit, .inherit, both, .init(choice: coder, source: .torvliDefault)),
        (.choice(beta), .box, both, .init(choice: beta, source: .sameAsConversation)),
        (.box, .box, both, .init(choice: nil, source: .sameAsConversation)),
        (.inherit, .choice(beta), both, .init(choice: beta, source: .bot)),
        (.box, .choice(coder), nil, .init(choice: coder, source: .bot)),
    ]
    for (conversation, coding, defaults, expected) in cases {
        #expect(ModelPolicy.resolve(role: .coding, settings: .init(conversation: conversation, coding: coding), defaults: defaults) == expected, "\(conversation)/\(coding)")
    }
}

// MARK: Codable

@Test func settingsRoundTripAndUnknownKindsReadAsInherit() throws {
    let settings = BotModelSettings(conversation: .choice(alpha), coding: .box)
    #expect(try decode(BotModelSettings.self, encoded(settings)) == settings)
    #expect(try encoded(settings) == #"{"coding":{"kind":"box"},"conversation":{"kind":"choice","model":"model-alpha","provider":"lab-one"}}"#)
    #expect(try decode(ModelSetting.self, #"{"kind":"galaxy","model":"model-alpha","provider":"lab-one"}"#) == .inherit)
    #expect(try decode(ModelSetting.self, #"{"kind":"choice","provider":"lab-one"}"#) == .inherit, "a pinned mode without a choice reads as inherit")
    #expect(try decode(ModelSetting.self, #"{"kind":"choice","provider":"lab-one","model":"bad\u0007id"}"#) == .inherit)
    #expect(try decode(ModelSetting.self, #"{"kind":7}"#) == .inherit)
    #expect(try decode(BotModelSettings.self, "{}") == BotModelSettings())
    #expect(BotModelSettings().isEmpty && !settings.isEmpty)
}

@Test func choicesHoldOnlyUsableIDs() throws {
    #expect(ModelChoice(provider: "", model: "model-alpha") == nil)
    #expect(ModelChoice(provider: "lab-one", model: String(repeating: "m", count: 201)) == nil)
    #expect(ModelChoice(provider: "lab\none", model: "model-alpha") == nil)
    #expect(ModelChoice(provider: "lab-one", model: String(repeating: "m", count: 200)) != nil)
    let defaults = ModelDefaults(conversation: alpha, coding: coder)
    #expect(try decode(ModelDefaults.self, encoded(defaults)) == defaults)
    #expect(try decode(ModelDefaults.self, #"{"conversation":{"provider":"lab-one","model":""},"coding":{"provider":"lab-coder","model":"model-coder"}}"#) == ModelDefaults(coding: coder))
    #expect(try encoded(defaults) == #"{"coding":{"model":"model-coder","provider":"lab-coder"},"conversation":{"model":"model-alpha","provider":"lab-one"}}"#, "slug and id strings only")
}

// MARK: Reasons and the listed-only rule

@Test func reasonStringsArePinned() {
    let expected: [(ModelRoleReason, String)] = [
        (.noLock, "This box can't switch a chat's model, so Torvli can't apply a model here."),
        (.noList, "This box doesn't list its models, so Torvli can't check a choice before using it."),
        (.noRow, "This box can't report a chat's model, so Torvli can't tell whether the chat is new."),
        (.legacy, "This box only has the older chat API, which has no per-chat model."),
        (.noFork, "Coding threads need conversation forks, which this box doesn't offer."),
        (.notOffered("model-coder"), "model-coder isn't offered by this bot's profile."),
        (.permanent, "Hermes can't unpin a chat, and a pinned chat has no fallback model."),
        (.boxOnly, "Set on the box. Hermes doesn't let apps read or change it."),
        (.subAgentsOff, "Sub-agents are turned off for this bot."),
        (.openClaw, "Managed in OpenClaw."),
    ]
    for (reason, text) in expected { #expect(reason.text == text) }
    #expect(ModelRolesModel.caption == "Torvli remembers these choices and applies them when it starts a chat. It does not change your box's own settings.")
    #expect(ModelRolesModel.conversationHelp == "Used for chats, group chats and threads Torvli starts.")
    #expect(ModelRolesModel.codingHelp == "Used for coding threads. Sub-agents use whatever the box sets.")
}

@Test func blockerFollowsTheApplyGates() {
    func info(_ features: [String: Bool], options: Bool = true) -> BotServerInfo {
        var info = BotServerInfo(); info.fetchedAt = .now; info.isRefreshing = false
        info.capabilities = HermesCapabilities(features: features)
        info.modelOptions = options ? .loaded(HermesModelOptions.parse(catalogPayload(.v0205))) : .unavailable("off")
        return info
    }
    let native = ["session_chat_streaming": true, "session_model_lock": true, "model_options": true]
    #expect(ModelRoleReason.blocker(nil) == nil, "nothing loaded, nothing claimed")
    #expect(ModelRoleReason.blocker(info(native)) == nil)
    #expect(ModelRoleReason.blocker(info(native.merging(["session_chat_streaming": false]) { $1 })) == .legacy)
    #expect(ModelRoleReason.blocker(info(native.merging(["session_model_lock": false]) { $1 })) == .noLock)
    #expect(ModelRoleReason.blocker(info(native, options: false)) == .noList)
    #expect(ModelRoleReason.blocker(info(native.merging(["session_resources": false]) { $1 })) == .noRow)
    var old = BotServerInfo(); old.fetchedAt = .now
    #expect(ModelRoleReason.blocker(old) == .legacy, "no /v1/capabilities means the older chat API")
}

@Test(arguments: CatalogShape.allCases) func offersOnlyListedEnabledPairs(shape: CatalogShape) {
    let options = HermesModelOptions.parse(catalogPayload(shape))
    #expect(ModelPickerModel.offers(options, alpha))
    #expect(!ModelPickerModel.offers(options, coder), "not listed")
    #expect(!ModelPickerModel.offers(options, ModelChoice(provider: "lab-1", model: "model-alpha")!), "by slug, as the picker rows store it")
    #expect(!ModelPickerModel.offers(options, ModelChoice(provider: "lab-paid", model: "paid-a")!), "disabled by plan")
    #expect(ModelPickerModel.offers(options, ModelChoice(provider: "lab-paid", model: "free-b")!))
    #expect(!ModelPickerModel.offers(options, ModelChoice(provider: "lab-two", model: "model-z")!), "skeleton")
}
