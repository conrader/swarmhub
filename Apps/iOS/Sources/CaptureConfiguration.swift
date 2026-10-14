import Foundation
import SwarmHubCore

/// Debug-only, network-free entry points for captures of the actual native views.
enum CaptureConfiguration {
    enum Screen: String { case chats, conversation, approvals, settings }
    static var screen: Screen? {
        #if DEBUG
        guard let value = argument("--capture-screen") else { return nil }
        return Screen(rawValue: value)
        #else
        return nil
        #endif
    }
    static var appearance: String? {
        guard screen != nil, let value = argument("--capture-appearance"), ["Dark", "Light"].contains(value) else { return nil }
        return value
    }
    static var tab: Int { screen == .approvals ? 1 : screen == .settings ? 2 : 0 }
    static var path: [String] { screen == .conversation ? ["sample-atlas"] : [] }
    private static func argument(_ name: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: name), CommandLine.arguments.indices.contains(index + 1) else { return nil }
        return CommandLine.arguments[index + 1]
    }

    static func messages(for name: String) -> [TranscriptMessage] {
        let content: String
        switch name {
        case "Mira": content = "The announcement is ready for your review."
        case "Patch": content = "The native iOS build and core tests passed."
        case "Scout": content = "Morning briefing: six updates worth a look."
        default: content = "I’d lead with the work your agents finish while you’re away.\n\nKeep three things easy to find: your conversations, the work that needs a decision, and the results already waiting for you."
        }
        return [
            .init(id: "sample-user", role: .user, text: "Find a simple direction for our mobile launch."),
            .init(id: "sample-response", role: .assistant, text: content)
        ]
    }
    @MainActor static func configure(_ store: MobileStore) {
        store.useSamples()
        for profile in store.profiles {
            store.caches[profile.id] = ChatCache(messages: messages(for: profile.name))
            store.capabilities[profile.id] = ServerCapabilities(features: ["session_chat_streaming"])
        }
        store.approvals = [MobileApproval(agentID: "sample-mira", request: .init(
            runID: "sample-run", requestID: "sample-request", title: "Send the launch announcement?",
            command: "Send the reviewed announcement to team@example.com", choices: ["once", "deny"]
        ))]
        store.booted = true
    }
}
