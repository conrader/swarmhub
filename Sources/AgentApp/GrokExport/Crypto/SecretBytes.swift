import Foundation

/// A string-valued secret (access token, machine id, team id) that never prints its contents.
/// Not `Codable`, so it cannot be written to a store or report; its `description` is redacted (Rule 2).
/// Swift strings cannot be zeroed, so the honest guarantee is "memory only, never saved or logged" (Rule 6).
struct SecretBytes: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    private let value: String

    init(_ value: String) { self.value = value }

    /// The only reader. Callers keep the result in a local and never store it.
    func reveal() -> String { value }

    var isEmpty: Bool { value.isEmpty }

    var description: String { "<secret \(value.isEmpty ? "empty" : "\(value.count) chars")>" }
    var debugDescription: String { description }
}
