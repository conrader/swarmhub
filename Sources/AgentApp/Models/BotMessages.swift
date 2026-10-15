import Foundation

/// P34 D4: one `bot-msg --to X` call, read from the full command of a step (`tool.started` args, else the uncut first
/// line Hermes showed; never the 80-character preview, P41), and, once the step ends, what the other bot answered (or
/// the queued thread id).
struct BotMessageCall: Codable, Equatable, Sendable {
    var to: String; var from: String?; var text: String; var noWait = false; var reply: String?

    static let textLimit = 4000

    /// The script's file names (P41: `.sh`/`.py` wrappers too).
    static let scriptNames: Set<String> = ["bot-msg", "bot-msg.sh", "bot-msg.py"]

    /// Whether a shell word runs the script: its last path component is the script, at any path (a quoted word only
    /// when it is a path, so `echo 'bot-msg …'` stays text).
    static func isScript(_ word: String, quoted: Bool) -> Bool {
        guard let name = word.split(separator: "/").last, scriptNames.contains(String(name)) else { return false }
        return !quoted || word.contains("/")
    }

    /// The call in a shell command: the first word naming `bot-msg` anywhere in the command (any path), its options
    /// in any order up to `--`, and the text after it (one word, or the rest joined; a `--to` inside the text is text).
    /// Nil when the command does not run bot-msg or names no recipient.
    static func parse(command: String) -> BotMessageCall? {
        guard command.contains("bot-msg") else { return nil }
        let words = ShellWords.split(command)
        guard let start = words.firstIndex(where: { isScript($0.word, quoted: $0.quoted) }) else { return nil }
        var to: String?, from: String?, noWait = false, text: [String] = []
        var index = start + 1, afterDashes = false
        while index < words.count {
            let (word, quoted) = words[index]
            if !quoted, ["&&", "||", ";", "|", "&"].contains(word) { break }
            if afterDashes { text.append(word) }
            else {
                switch word {
                case "--to": to = words[safe: index + 1]?.word; index += 1
                case "--from": from = words[safe: index + 1]?.word; index += 1
                case "--wait": index += 1
                case "--no-wait": noWait = true
                case "--": afterDashes = true
                default: if word.hasPrefix("--to=") { to = String(word.dropFirst(5)) } else if word.hasPrefix("--from=") { from = String(word.dropFirst(7)) }
                }
            }
            index += 1
        }
        guard let to, !to.isEmpty, to.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }) else { return nil }
        return BotMessageCall(to: to, from: from, text: String(text.joined(separator: " ").prefix(textLimit)), noWait: noWait)
    }

    /// The text the recipient got, without bot-msg's own first line.
    static func strippingHeader(_ text: String) -> (sender: String?, text: String) {
        guard text.hasPrefix("[Message from "), let end = text.range(of: " via SwarmHub]") else { return (nil, text) }
        let sender = String(text[text.index(text.startIndex, offsetBy: 14)..<end.lowerBound])
        let rest = text[end.upperBound...].drop { $0 == "\n" || $0 == " " }
        return (sender, String(rest))
    }

    /// The reply in a terminal result: its `output` when the result is a JSON object (Hermes' terminal tool), else the text.
    static func reply(fromResult raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        if let data = raw.data(using: .utf8), let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            let output = (json["output"] ?? json["stdout"] ?? json["result"]) as? String
            return output.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(textLimit)) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.prefix(textLimit))
    }
}

/// A POSIX-ish word splitter: whitespace, '…', "…" (with \" \\ \$ \`), backslash escapes; `;`, `&&`, `||`, `|`, `&`
/// stand alone. `quoted` is true for a word that had any quoting (so a quoted `&&` is text).
enum ShellWords {
    static func split(_ text: String) -> [(word: String, quoted: Bool)] {
        var words: [(String, Bool)] = [], current = "", quoted = false, inWord = false
        var chars = Array(text)[...]
        func flush() { if inWord { words.append((current, quoted)) }; current = ""; quoted = false; inWord = false }
        while let c = chars.popFirst() {
            switch c {
            case " ", "\t", "\n": flush()
            case "'":
                inWord = true; quoted = true
                while let n = chars.popFirst(), n != "'" { current.append(n) }
            case "\"":
                inWord = true; quoted = true
                while let n = chars.popFirst(), n != "\"" {
                    if n == "\\", let next = chars.first, "\"\\$`".contains(next) { current.append(chars.removeFirst()) } else { current.append(n) }
                }
            case "\\":
                inWord = true
                if let next = chars.popFirst(), next != "\n" { current.append(next) }
            case ";", "|", "&":
                flush()
                if c != ";", chars.first == c { chars.removeFirst(); words.append((String([c, c]), false)) } else { words.append((String(c), false)) }
            default: inWord = true; current.append(c)
            }
        }
        flush()
        return words
    }
}

fileprivate extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// One thread between two bots: the recipient's session `swarmhub-from-<from>` titled "From <from>" (profile names).
struct BotThreadKey: Hashable, Identifiable, Sendable {
    var from: String; var to: String
    /// P42: a session other than `swarmhub-from-<from>` (a oneshot command's); nil for the usual one.
    private(set) var session: String?
    init(from: String, to: String, session: String? = nil) {
        self.from = from; self.to = to
        self.session = session == Self.sessionID(from: from) || session?.isEmpty == true ? nil : session
    }
    var id: String { "\(from)→\(to)" + (session.map { "|\($0)" } ?? "") }
    var sessionID: String { session ?? Self.sessionID(from: from) }
    static let sessionPrefix = "swarmhub-from-"
    static func sessionID(from sender: String) -> String { sessionPrefix + sender }
    /// The sender of a recipient session, from its id (`swarmhub-from-<bot>`) or its title (`From <bot>`).
    static func sender(sessionID: String, title: String?) -> String? {
        if sessionID.hasPrefix(sessionPrefix) { return String(sessionID.dropFirst(sessionPrefix.count)) }
        if let title, title.hasPrefix("From "), title.count > 5 { return String(title.dropFirst(5)) }
        return nil
    }
}

/// One line of a thread: who wrote it (a profile) and what, oldest first.
struct BotThreadLine: Identifiable, Equatable, Sendable {
    var id: String; var author: String; var text: String; var date: Date?
}

/// The Activity tab's and ⌘K's row for a thread: its last line and when.
struct BotThreadSummary: Identifiable, Equatable, Sendable {
    var key: BotThreadKey; var lastLine: String; var date: Date?
    var id: String { key.id }
}

/// A recipient's session row as the session list shows it (P34 D6): the mark changes when a message lands.
struct BotThreadRow: Equatable, Sendable {
    var sessionID: String; var sender: String; var mark: String; var updatedAt: Date?; var preview: String?
}

enum BotMessageCopy {
    static func chip(_ name: String) -> String { "→ \(name)" }
    static func arrival(from: String, to: String) -> String { "\(from) wrote to \(to)" }
    static let openThread = "Open conversation"
    /// P41: the sender's step while bot-msg waits, and once the recipient answered.
    static func asking(_ name: String) -> String { "Asked \(name)…" }
    static func replied(_ name: String) -> String { "\(name) replied" }
    static func chip(_ name: String, _ state: BotMessageChipState) -> String {
        switch state {
        case .sent: chip(name)
        case .asking: asking(name)
        case .replied: replied(name)
        }
    }
    /// P41: the recipient while a sender's bot-msg step runs (sidebar and chat header).
    static func incoming(from name: String) -> String { "\(ChatActivityPhase.working.label) · message from \(name)" }
    static func pollFailed(_ reason: String) -> String { "Couldn’t check bot messages: \(reason)" }
    static func paletteTitle(_ a: String, _ b: String) -> String { "\(a) ↔ \(b)" }
    static let sectionTitle = "Bot messages"
    static let empty = "No messages between bots yet."
    static let notConnected = "Shown from the sender’s steps; connect the other bot to read the whole thread."
    static let queued = "Sent without waiting; the reply lands in the thread."
}
