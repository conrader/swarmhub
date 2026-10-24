import Foundation

/// autoctx1: "the conversation is too long for the model". Hermes ends such a turn as failed with chat copy that tells the
/// user to type /new or /compress (`agent/turn_failure_copy.py`); the words change between versions, so a machine code
/// is preferred where the box sends one (`failure_reason`, `turn_exit_reason`, an error `code`, `compression_exhausted`),
/// and the text is matched loosely otherwise. The backend tags a coded failure with `tag` so the store need not re-parse.
enum ContextOverflow {
    static let tag = "[context_overflow] "
    static let codes: Set<String> = ["context_overflow", "payload_too_large", "compression_disabled", "long_context_tier",
                                     "context_length_exceeded", "context_window_exceeded", "context_compression_timeout"]
    /// Lower-cased fragments of overflow copy (Hermes 0.21–0.22 and provider errors), and of its slash-command advice.
    static let phrases = ["grown too long", "grown too large", "conversation is too long", "conversation is too large", "too long for",
                          "context window", "context length", "context_length", "context-length", "maximum context", "context limit",
                          "context_overflow", "payload_too_large", "too large to send", "prompt is too long", "prompt too long",
                          "exceeds the context", "too many tokens", "/compress", "compression.enabled"]
    /// Text that mentions tokens for another reason (a rate limit) is not an overflow.
    static let exclusions = ["rate limit", "rate-limit", "per minute", "per min", "tpm", "quota"]

    static func hasCode(_ json: [String: Any]) -> Bool {
        let sources = [json, json["error"] as? [String: Any] ?? [:], json["hermes"] as? [String: Any] ?? [:]]
        return sources.contains { source in
            (source["compression_exhausted"] as? Bool) == true
                || ["failure_reason", "turn_exit_reason", "code", "error_code", "type", "reason"].contains { key in
                    (source[key] as? String).map { codes.contains($0.lowercased()) } ?? false
                }
        }
    }

    static func matches(_ text: String) -> Bool {
        let text = text.lowercased()
        if text.contains(tag.lowercased().trimmingCharacters(in: .whitespaces)) { return true }
        guard !exclusions.contains(where: { text.contains($0) }) else { return false }
        return phrases.contains { text.contains($0) }
    }

    static func isOverflow(_ end: TurnEnd) -> Bool {
        switch end {
        case .failedByBox(let text): return matches(text)
        case .error(let error): return isOverflow(error: error)
        default: return false
        }
    }

    static func isOverflow(error: Error) -> Bool {
        if let broken = error as? StreamBreak { return isOverflow(error: broken.underlying) }
        if case BackendError.http(let code, let text) = error { return code == 413 || ([400, 422].contains(code) && matches(text)) }
        if error is URLError || error is CancellationError { return false }
        return matches(error.localizedDescription)
    }

    /// Box copy that tells the user to type a session command: never shown as it is.
    static func hasSlashAdvice(_ text: String) -> Bool {
        let text = text.lowercased()
        return text.hasPrefix(tag.lowercased()) || ["/new", "/compress", "/retry"].contains { text.contains($0) && matches(text) }
    }

    /// The failure text without the tag, as the box wrote it.
    static func untagged(_ text: String) -> String { text.hasPrefix(tag) ? String(text.dropFirst(tag.count)) : text }
}

/// autoctx1: what the chat says instead of Hermes' raw error text, and what SwarmHub is doing about it. Never asks the
/// user to type a command.
enum TurnErrorCopy {
    static let compacting = "Conversation is too long, compacting…"
    static let startingNew = "Continuing in a new session…"
    static let compacted = "Conversation was compacted to fit the model; your message was sent again."
    static let newSession = "Conversation continued in a new session (history kept above); your message was sent again."
    static let newSessionNotSent = "Conversation continued in a new session (history kept above). Some steps of that reply had already run, so your message was not sent again; send it again if you still need it."
    static let tooLong = "This message is too long for the model even in a fresh session. Try a shorter message, or a model with a bigger context window."
    /// A turn SwarmHub could not move (a group round, a task thread).
    static let tooLongHere = "This conversation is too long for the model, even after Hermes compacted it. Try a shorter message, or a model with a bigger context window."
    static let stoppedTooLong = "This reply stopped because the conversation got too long for the model."
    static let installContextFull = "the model’s context was full. The next install starts in a fresh session."
    static let setupRetry = "Couldn’t reach the box; trying again…"
}
