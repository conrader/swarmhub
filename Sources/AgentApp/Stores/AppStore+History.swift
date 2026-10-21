import Foundation

extension AppStore {
    static func mergeHermesHistory(local: [ChatMessage], server: [BackendMessage]) -> [ChatMessage]? {
        // P38 B: the connected-apps loop's request and result rows are protocol, never chat.
        let server = server.filter { !ConnectedAppsChat.isInternalMessage($0) }
        guard !server.isEmpty else { return local.isEmpty ? [] : nil }
        let remoteTurns = server.enumerated().filter { ["user", "assistant"].contains($0.element.role) }
        let localTurns = local.filter { [MessageRole.user, .assistant].contains($0.role) && $0.presentation == .text && !$0.content.isEmpty && !$0.isSteer }
        if localTurns.isEmpty {
            return local + server.compactMap { Self.chatMessage($0) }
        }

        // Find the longest suffix of locally-known server-visible turns anywhere in the server
        // transcript. For established histories require a complete user -> assistant pair, and use
        // the latest matching window so repeated short turns cannot append an earlier duplicate tail.
        var matchedServerEnd: Int?
        let maximum = min(localTurns.count, remoteTurns.count)
        let minimum = localTurns.count >= 2 ? 2 : 1
        if maximum >= minimum {
            for count in stride(from: maximum, through: minimum, by: -1) {
                let suffix = localTurns.suffix(count)
                let includesFullPair = zip(suffix, suffix.dropFirst()).contains {
                    $0.role == .user && $1.role == .assistant
                }
                if localTurns.count >= 2 && !includesFullPair { continue }
                for start in stride(from: remoteTurns.count - count, through: 0, by: -1) {
                    let candidate = remoteTurns[start..<(start + count)]
                    if zip(suffix, candidate).allSatisfy({ local, remote in
                        local.role.rawValue == remote.element.role && Self.sameText(local.outgoingText, remote.element.content)
                    }) {
                        matchedServerEnd = candidate.last!.offset
                        break
                    }
                }
                if matchedServerEnd != nil { break }
            }
        }
        guard let end = matchedServerEnd else { return nil }
        let additions = server.dropFirst(end + 1).compactMap { Self.chatMessage($0) }
        return local + additions
    }

    /// Server rows render image parts as `[Image: …]` lines; local messages keep images as attachments.
    /// P12: OpenClaw's delivery directives and `NO_REPLY` are normalised the same way on both sides.
    nonisolated static func comparable(_ content: String) -> String {
        OpenClawText.comparable(content).components(separatedBy: "\n").filter { !($0.hasPrefix("[Image: ") && $0.hasSuffix("]")) }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// P19: text over `HermesBackend.maxTextPartScalars` went out split; a hard cut (a window without a line
    /// break or space) comes back from the server with one extra `\n`, possibly inside a word, so long texts
    /// are compared with all whitespace removed. Short texts compare exactly as before.
    nonisolated static func sameText(_ local: String, _ remote: String) -> Bool {
        let left = comparable(local), right = comparable(remote)
        if left == right { return true }
        let limit = HermesBackend.maxTextPartScalars
        guard left.unicodeScalars.count > limit || right.unicodeScalars.count > limit else { return false }
        func squeezed(_ text: String) -> String { String(String.UnicodeScalarView(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })) }
        return squeezed(left) == squeezed(right)
    }

    static func chatMessage(_ row: BackendMessage) -> ChatMessage? {
        guard let role = MessageRole(rawValue: row.role), !row.content.isEmpty else { return nil }
        var metadata = row.outOfBand ? [SteerKey.outOfBand: "1"] : [:]
        if let kind = row.displayKind { metadata[HermesDisplayKey.kind] = kind }
        return ChatMessage(role: role, content: row.content, createdAt: row.createdAt ?? .now, metadata: metadata)
    }
}
