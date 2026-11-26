import Foundation

/// The blank line between two saved journal replies is implicit on screen, but is
/// part of the wire text when reconciling a snapshot or parsing the complete turn.
enum TurnReplyText {
    static let separator = "partSeparator"

    // Older multipart rows already share the trigger. New rows also name their origin
    // so even retries of a legacy reply with no explicit trigger can be assembled.
    static let origin = "partOrigin"

    static func turnID(of row: ChatMessage) -> String? {
        guard row.metadata[TurnKey.part] != nil else { return nil }
        return row.metadata[origin] ?? row.metadata[TurnKey.forUser]
    }

    static func complete(_ reply: ChatMessage, in conversation: any Conversation) -> String {
        guard let id = turnID(of: reply), reply.metadata[TurnKey.part] != "1",
              let index = conversation.messages.firstIndex(where: { $0 === reply }) else { return reply.content }
        return joined(conversation.messages[...index].filter { $0.role == .assistant && $0.authorID == reply.authorID && turnID(of: $0) == id })
    }

    static func joined(_ parts: [ChatMessage]) -> String {
        parts.map { ($0.metadata[separator] ?? "") + $0.content }.joined()
    }

    /// Apply revisions to the rows that displayed the draft. Return only new trailing
    /// output, so the caller can place it on either side of a pending steer receipt.
    static func replace(_ snapshot: String, parts: [ChatMessage], cumulative: Bool, saved: Bool, pending: Bool) -> String {
        guard let last = parts.last else { return snapshot }
        let old = joined(parts)
        if snapshot.hasPrefix(old) { return String(snapshot.dropFirst(old.count)) }

        // A reconnect can replay the saved prefix while a later draft is visible.
        // Only the final journal can retract that entire later part.
        if !saved, parts.count > 1, old.hasPrefix(snapshot) {
            var length = 0
            for part in parts.dropLast() {
                length += (part.metadata[separator]?.utf8.count ?? 0) + part.content.utf8.count
                if length == snapshot.utf8.count { return "" }
            }
        }

        // Some streams report just the new part. Herdr's own snapshots, in particular
        // the final saved journal, always describe the complete turn.
        let prefix = old.commonPrefix(with: snapshot, options: .literal)
        let trimmed = old.lastIndex(where: { !$0.isWhitespace }).map { old[...$0] }
        if trimmed == nil {
            revise(parts, from: old, to: "")
            return snapshot
        }
        if let trimmed, trimmed.count < old.count, snapshot.hasPrefix(String(trimmed)) {
            let length = max(prefix.count, trimmed.count)
            revise(parts, from: old, to: String(snapshot.prefix(length)))
            return String(snapshot.dropFirst(length))
        }
        if !cumulative && !saved {
            // A part-local draft can itself cross another receipt. A replay or
            // extension may therefore cover several trailing parts.
            for i in parts.indices.dropFirst() where !parts[i].content.isEmpty && snapshot.hasPrefix(parts[i].content) {
                let tail = parts[i].content + joined(Array(parts.dropFirst(i + 1)))
                if snapshot.hasPrefix(tail) { return String(snapshot.dropFirst(tail.count)) }
            }
            if pending, !old.hasPrefix(snapshot), let first = parts.first, !snapshot.hasPrefix(first.content) {
                return "\n\n" + snapshot
            }
            if prefix.isEmpty, !pending, !snapshot.contains("\n\n") {
                last.content = snapshot
                return ""
            }
        }

        // A corrected saved paragraph can arrive together with the next journal reply.
        // Keep the correction in its draft's row and the extra paragraphs after it.
        if pending || (parts.count > 1 && last.content.isEmpty) {
            let paragraphs = snapshot.components(separatedBy: "\n\n")
            let priorCount = old.components(separatedBy: "\n\n").count
            if paragraphs.count > priorCount {
                let corrected = paragraphs.prefix(priorCount).joined(separator: "\n\n")
                revise(parts, from: old, to: corrected)
                return String(snapshot.dropFirst(corrected.count))
            }
        }
        revise(parts, from: old, to: snapshot)
        return ""
    }

    /// Keep cuts in the unchanged prefix and suffix anchored to the same characters.
    /// Cuts inside replaced text keep as much of their old span as the revision allows.
    private static func revise(_ parts: [ChatMessage], from old: String, to text: String) {
        guard parts.count > 1 else { parts.first?.content = text; return }
        let prefix = old.commonPrefix(with: text, options: .literal).count
        let oldTail = old.dropFirst(prefix), newTail = text.dropFirst(prefix)
        let suffix = zip(oldTail.reversed(), newTail.reversed()).prefix { $0.0 == $0.1 }.count
        let oldEnd = old.count - suffix, newEnd = text.count - suffix
        // Journal separators provide a stronger anchor when both adjacent saved
        // paragraphs changed and the old cut is inside the replaced span.
        let paragraphs = text.components(separatedBy: "\n\n")
        var paragraph = 0, oldOffset = 0, newOffset = 0
        var start = text.startIndex
        for (index, part) in parts.enumerated() {
            let join = part.metadata[separator] ?? ""
            oldOffset += join.count + part.content.count
            paragraph += (join + part.content).components(separatedBy: "\n\n").count - 1
            let endOffset: Int
            if index == parts.count - 1 { endOffset = text.count }
            else if oldOffset <= prefix { endOffset = oldOffset }
            else if oldOffset >= oldEnd { endOffset = newEnd + oldOffset - oldEnd }
            else if parts[index + 1].metadata[separator] == "\n\n", paragraph + 1 < paragraphs.count {
                let boundary = paragraphs.prefix(paragraph + 1).joined(separator: "\n\n").count
                endOffset = max(prefix, min(boundary, newEnd))
            } else { endOffset = min(oldOffset, newEnd) }
            let offset = min(text.count, max(newOffset, endOffset))
            let end = text.index(start, offsetBy: offset - newOffset)
            let slice = text[start..<end]
            if slice.hasPrefix(join) { part.content = String(slice.dropFirst(join.count)) }
            else { part.metadata[separator] = nil; part.content = String(slice) }
            start = end
            newOffset = offset
        }
    }
}
