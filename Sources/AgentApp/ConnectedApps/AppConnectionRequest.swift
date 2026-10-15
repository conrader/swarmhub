import Foundation

/// Assistant-authored UI data. It cannot choose a destination URL, user identity or target bot.
struct AppConnectionRequest: Equatable, Sendable {
    let toolkit: String
    let reason: String

    static func parse(_ text: String) -> Self? {
        guard text.utf8.count <= 2048, let value = try? JSONDecoder().decode(ComposioValue.self, from: Data(text.utf8)),
              let fields = value.object, Set(fields.keys).isSubset(of: ["app", "reason"]),
              let app = value["app"].string, ComposioClient.validIdentifier(app),
              fields["reason"] == nil || value["reason"].string != nil else { return nil }
        let reason = value["reason"].string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard reason.count <= 240 else { return nil }
        return .init(toolkit: app.lowercased(), reason: reason)
    }

    static let instructions = """
    SwarmHub can display an app connection card inside your reply.
    When the task needs an app the user has not enabled for you, offer this card in your normal Markdown answer:
    ```connect-app
    {"app":"gmail","reason":"Connect Gmail so I can help with your inbox."}
    ```
    Use the app's exact Composio toolkit identifier in lowercase. Popular identifiers: gmail, googlecalendar, googledrive, slack, notion, github.
    The optional reason is plain text, at most 240 characters. Include only app and reason.
    The user clicks the card to sign in through SwarmHub and explicitly choose which account to allow for this bot.
    Do not include an authentication URL, API key, user ID or bot ID. Never claim a connection or permission was granted before it is enabled.
    Wait for the user to finish connecting and send a follow-up before continuing the app task.
    """
}
