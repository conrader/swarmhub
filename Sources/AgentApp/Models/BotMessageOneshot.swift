import Foundation

/// P42 6: the other route between bots: `hermes -p <bot> chat [-Q] --oneshot … -q '<text>'` run in a bot's terminal
/// (a bot without SwarmHub's messaging skill). Its sender is the bot whose step ran it; the recipient (`-p`) answers in
/// a session of source `oneshot`, found by listing them after the step began.
extension BotMessageCall {
    /// bot-msg, else the oneshot command.
    static func call(in command: String) -> BotMessageCall? { parse(command: command) ?? parseOneshot(command: command) }

    /// Whether a command might hold either route (a cheap check before splitting it).
    static func mentionsCall(_ command: String) -> Bool { command.contains("bot-msg") || (command.contains("hermes") && command.contains("chat")) }

    /// `hermes` (any path) with `-p|--profile <bot>`, the `chat` subcommand and a `-q|--query <text>` (or `--oneshot`),
    /// options in any order. Nil for anything else.
    static func parseOneshot(command: String) -> BotMessageCall? {
        guard command.contains("hermes") else { return nil }
        let words = ShellWords.split(command)
        guard let start = words.firstIndex(where: { word in word.word.split(separator: "/").last == "hermes" && (!word.quoted || word.word.contains("/")) }) else { return nil }
        var to: String?, text: String?, chat = false, oneshot = false
        var index = start + 1
        while index < words.count {
            let (word, quoted) = words[index]
            if !quoted, ["&&", "||", ";", "|", "&"].contains(word) { break }
            let next = index + 1 < words.count ? words[index + 1].word : nil
            switch word {
            case "-p", "--profile": to = next; index += 1
            case "-q", "--query": text = next; index += 1
            case "chat": if !quoted { chat = true }
            case "--oneshot": oneshot = true
            default:
                if word.hasPrefix("--profile=") { to = String(word.dropFirst(10)) }
                else if word.hasPrefix("--query=") { text = String(word.dropFirst(8)) }
            }
            index += 1
        }
        guard chat, text != nil || oneshot, let to, !to.isEmpty,
              to.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }) else { return nil }
        var call = BotMessageCall(to: to, from: nil, text: String((text ?? "").prefix(textLimit)))
        call.oneshot = true
        return call
    }
}
