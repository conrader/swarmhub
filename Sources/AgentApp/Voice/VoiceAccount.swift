import Combine
import Foundation

/// P38 C: what live voice needs from the ChatGPT connection: its state, its voice-access check and requests to its
/// private Codex app-server. The members are named as on P38 B's `ChatGPTConnection`, so that class conforms with an
/// empty extension; voice never signs in or reads ChatGPT credentials itself.
@MainActor protocol VoiceAccount: ObservableObject {
    var isConnected: Bool { get }
    var canUseVoice: Bool { get }
    var voiceAccessMessage: String { get }
    var plan: String? { get }
    var onVoiceNotification: ((String, JSONValue) -> Void)? { get set }
    var onDisconnect: (() -> Void)? { get set }
    func refresh(force: Bool)
    func request(_ method: String, params: [String: JSONValue], timeout: Duration) async throws -> JSONValue
}

@MainActor enum VoiceAccounts {
    /// The app's ChatGPT connection, registered by the ChatGPT connected app (P38 B). Nil in a build without it: live
    /// voice then says it is not set up and what it needs.
    static var chatGPT: (any VoiceAccount)?
    static let notSetUp = "Live voice is not set up: it needs the ChatGPT connected app, which signs in with your ChatGPT account."
}

/// Errors the voice session shows. Provider diagnostics can carry request headers or tokens, so only these fixed
/// lines reach the screen; an account error that is not one of them shows as `unavailable`.
enum LiveVoiceError: LocalizedError, Equatable {
    case disconnected, timedOut, invalidResponse, signInRequired, unavailable, audioUnavailable
    var errorDescription: String? {
        switch self {
        case .disconnected: "The Codex voice connection closed. Reconnect to try again."
        case .timedOut: "Codex did not respond in time. Check your connection and try again."
        case .invalidResponse: "This Codex build returned an unsupported voice response. Update ChatGPT or Codex and reconnect."
        case .signInRequired: "Sign in with ChatGPT to use your subscription for voice."
        case .unavailable: "Codex could not open live voice for this account. Check your plan, workspace permissions and voice availability, and update ChatGPT or Codex."
        case .audioUnavailable: "Could not start voice audio. Check your microphone and output device, then try again."
        }
    }
}
