import Foundation

public enum CoreError: LocalizedError, Equatable, Sendable {
    case invalidAddress, invalidProfile, invalidIdentifier, missingKey, invalidResponse
    case insecureAddress, redirectRefused, http(Int), unsupported(String), storage, requestTooLarge
    case interruptedStream

    public var errorDescription: String? {
        switch self {
        case .invalidAddress: "Enter a server address starting with https://, without a password or query."
        case .invalidProfile: "Use a profile name containing letters, numbers, hyphens or underscores."
        case .invalidIdentifier: "The server returned an invalid resource identifier."
        case .missingKey: "Enter a key for this profile."
        case .invalidResponse: "The server returned an unexpected response."
        case .insecureAddress: "Use HTTPS for your agent server. Localhost on iPhone refers to the phone itself."
        case .redirectRefused: "The server redirected the request. Enter its final HTTPS address instead."
        case .http(let status): status == 401 || status == 403 ? "The server did not accept this profile key." : "The server refused the request (HTTP \(status))."
        case .unsupported(let reason): reason
        case .storage: "The local history could not be saved."
        case .requestTooLarge: "This conversation is too large for one request. Start a new chat or fork it."
        case .interruptedStream: "The connection ended before the server confirmed the result. Check the server before sending again."
        }
    }
}
