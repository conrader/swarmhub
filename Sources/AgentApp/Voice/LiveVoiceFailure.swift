import Foundation

/// P55: why live voice stopped, in words: the step that failed, the error's type and code, and a redacted message.
/// The text names the step (microphone, ChatGPT account, ChatGPT's answer, Codex's timeout, the audio device), so a
/// failure is never just a blink back to "Ready to talk".
struct LiveVoiceFailure: Equatable {
    /// The steps of `CodexVoiceSession.start()`, in order, then the live session's own.
    enum Step: String, Equatable {
        case account, microphone, threadStart = "thread/start", realtimeStart = "thread/realtime/start",
             audioDevice = "audio device", sendAudio = "thread/realtime/appendAudio", realtime = "thread/realtime", playback
        var title: String {
            switch self {
            case .account: "ChatGPT account check"
            case .microphone: "Microphone access"
            case .threadStart: "Opening a Codex thread"
            case .realtimeStart: "Starting live voice"
            case .audioDevice: "Starting the audio device"
            case .sendAudio: "Sending your voice"
            case .realtime: "Live voice"
            case .playback: "Playing ChatGPT's voice"
            }
        }
    }
    let step: Step
    /// The error's type (and case, for SwarmHub's own enums); never its payload.
    let type: String
    let code: Int64?
    /// Already redacted (`VoiceRedaction`).
    let detail: String
    /// The line the voice window shows.
    let message: String

    /// Microphone access is off: the window offers System Settings → Privacy & Security → Microphone.
    var opensMicrophoneSettings: Bool { step == .microphone && type == "VoiceDictationError.permissionDenied" }

    /// What "Copy details" copies: step, type, code and the redacted message.
    var details: String {
        ["SwarmHub live voice failure", "Step: \(step.title) (\(step.rawValue))", "Error: \(type)",
         "Code: \(code.map(String.init) ?? "none")", "Message: \(detail.isEmpty ? "none" : detail)"].joined(separator: "\n")
    }

    /// The `com.konrad.agentapp:voice` log line.
    var logLine: String {
        "voice failed step=\(step.rawValue) type=\(type) code=\(code.map(String.init) ?? "none") message=\"\(detail)\""
    }

    init(step: Step, type: String, code: Int64? = nil, detail: String, message: String) {
        self.step = step; self.type = type; self.code = code; self.detail = detail; self.message = message
    }

    /// A thrown error at `step`; `timeout` is how long that step's request waited.
    init(step: Step, error: Error, timeout: Int? = nil) {
        let type = Self.typeName(error)
        if let rpc = error as? CodexRPCError {
            let detail = VoiceRedaction.redact(rpc.message)
            self.init(step: step, type: type, code: rpc.code, detail: detail, message: "ChatGPT refused live voice: \(rpc.code) \(detail)")
            return
        }
        let detail = VoiceRedaction.redact(error.localizedDescription)
        let live = error as? LiveVoiceError, codex = error as? CodexVoiceError
        let message: String
        if step == .microphone, case VoiceDictationError.permissionDenied? = error as? VoiceDictationError {
            message = "Microphone access is off for SwarmHub — turn it on in System Settings → Privacy & Security → Microphone."
        } else if step == .microphone { message = "The microphone could not be used: \(detail)" }
        else if live == .timedOut || codex == .timedOut { message = "Codex did not answer within \(timeout ?? 30) s (\(step.title.lowercased()))." }
        else if live == .signInRequired || codex == .signInRequired { message = "Your ChatGPT account can't use live voice here: \(detail)" }
        else if live == .disconnected || codex == .disconnected {
            message = "The ChatGPT connection closed during: \(step.title.lowercased()). Reconnect ChatGPT and try again."
        } else if step == .audioDevice { message = "The audio device could not start: \(detail)" }
        else if step == .playback { message = "ChatGPT's voice could not be played: \(detail)" }
        else { message = "\(step.title) failed: \(detail)" }
        self.init(step: step, type: type, detail: detail, message: message)
    }

    /// The account cannot use voice (`VoiceAccount.voiceAccessMessage`).
    static func account(_ reason: String) -> LiveVoiceFailure {
        let detail = VoiceRedaction.redact(reason)
        return LiveVoiceFailure(step: .account, type: "VoiceAccount.canUseVoice", detail: detail,
                                message: "Your ChatGPT account can't use live voice here: \(detail)")
    }

    /// `thread/realtime/error`: its message (and a code, should a Codex build send one) through the same redaction.
    static func realtimeError(_ params: JSONValue, starting: Bool) -> LiveVoiceFailure {
        let code = params["code"]?.intValue
        let detail = VoiceRedaction.redact(params["message"]?.stringValue ?? "no message")
        let text = (code.map { "\($0) " } ?? "") + detail
        return LiveVoiceFailure(step: starting ? .realtimeStart : .realtime, type: "thread/realtime/error", code: code, detail: detail,
                                message: starting ? "ChatGPT refused live voice: \(text)" : "ChatGPT stopped live voice: \(text)")
    }

    /// `thread/realtime/closed` before the session went live.
    static func closedEarly(_ params: JSONValue) -> LiveVoiceFailure {
        let detail = VoiceRedaction.redact(params["reason"]?.stringValue ?? "no reason given")
        return LiveVoiceFailure(step: .realtimeStart, type: "thread/realtime/closed", detail: detail,
                                message: "ChatGPT closed live voice before it started: \(detail)")
    }

    private static func typeName(_ error: Error) -> String {
        switch error {
        case let error as LiveVoiceError: "LiveVoiceError.\(error)"
        case let error as CodexVoiceError: "CodexVoiceError.\(error)"
        case let error as VoiceDictationError: "VoiceDictationError.\(error)"
        default:
            // Foundation errors keep their domain; other payloads are never printed here.
            error is CodexRPCError || error is VoiceAudioStartError ? String(describing: Swift.type(of: error)) :
                "\(Swift.type(of: error)) (\((error as NSError).domain))"
        }
    }
}

/// P55: what a voice diagnostic may show, copy or log. Provider messages can carry request headers, bearer tokens,
/// signed URLs, emails or account ids, so: credential and `x-`/`openai-` headers are removed to the end of their line;
/// bearer/basic credentials, JWTs, `sk-…` keys, emails and `token=`/`key=`/`secret=`/`password=`-style values are
/// replaced; any run of 32+ token characters is replaced; URLs (with or without a scheme) lose their user part, query
/// string and fragment; control characters and newlines become spaces; the result is at most 300 characters.
enum VoiceRedaction {
    static let limit = 300
    /// Runs on the raw text: a header is removed to the end of its line (cookies carry `;`-separated values).
    private static let header = try! NSRegularExpression(pattern:
        #"(?i)\b(?:authorization|proxy-authorization|cookie|set-cookie|x-[a-z0-9-]+|openai-[a-z0-9-]+|chatgpt-account-id|api-key)[ \t]*:[^\r\n]*"#)
    private static let rules: [(NSRegularExpression, String)] = [
        (#"(?i)\b(?:bearer|basic)\s+[A-Za-z0-9._~+/=-]+"#, "[credential removed]"),
        (#"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]*)?"#, "[token removed]"),
        (#"\bsk-[A-Za-z0-9_-]{6,}"#, "[key removed]"),
        (#"(?i)\b((?:access|refresh|id|session|auth)?_?(?:token|api_?key|apikey|secret|password|client_secret|session_?id))\b(["']?\s*[:=]\s*["']?)[^\s"',&;}]+"#, "$1$2[removed]"),
        (#"(?i)\b([a-z][a-z0-9+.-]*://)[^\s/@"'<>]*@"#, "$1"),
        (#"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+"#, "[email removed]"),
        (#"(?i)\b([a-z][a-z0-9+.-]*://[^\s?#"'<>]+)[?#][^\s"'<>;]*"#, "$1"),
        (#"(?i)\b((?:[a-z0-9-]+\.)+[a-z]{2,}(?::\d+)?/[^\s?#"'<>]*)[?#][^\s"'<>;]*"#, "$1"),
        (#"[A-Za-z0-9_+/=-]{32,}"#, "[token removed]")
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    static func redact(_ text: String) -> String {
        var value = header.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "[header removed]")
        value = String(value.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : Character($0) })
        for (rule, template) in rules {
            value = rule.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: template)
        }
        value = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return value.count <= limit ? value : String(value.prefix(limit - 1)) + "…"
    }
}
