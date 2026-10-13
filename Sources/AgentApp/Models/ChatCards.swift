import Foundation

/// Inline cards parsed from assistant Markdown (syntax documented in README → "Card syntax").
enum ChatBlock: Equatable {
    case markdown(String)
    case code(language: String, body: String)
    /// Question with options; picking one sends it as the user's reply.
    case choices(prompt: String, options: [String])
    /// Draft with Send ("Send it" to the bot) and Copy.
    case draft(DraftCard)
    case image(alt: String, url: String)
}

struct DraftCard: Equatable { var to: String?; var subject: String?; var body: String }

enum ChatCardParser {
    static let choicesMarker = "<!-- choices -->"

    static func parse(_ text: String) -> [ChatBlock] {
        var blocks: [ChatBlock] = []; var prose: [String] = []
        let lines = text.components(separatedBy: "\n"); var index = 0
        func flush() { if !prose.isEmpty { blocks += proseBlocks(prose.joined(separator: "\n")); prose = [] } }
        while index < lines.count {
            guard let fence = fenceOpening(lines[index]) else { prose.append(lines[index]); index += 1; continue }
            flush()
            var body: [String] = []; index += 1
            while index < lines.count, !closesFence(lines[index], length: fence.length) { body.append(lines[index]); index += 1 }
            index += 1
            blocks.append(fencedBlock(language: fence.info, body: body))
        }
        flush()
        return markTrailingChoices(blocks)
    }

    private static func fenceOpening(_ line: String) -> (length: Int, info: String)? {
        let trimmed = line.drop { $0 == " " }
        guard line.count - trimmed.count <= 3 else { return nil }
        let length = trimmed.prefix { $0 == "`" }.count
        guard length >= 3 else { return nil }
        let info = trimmed.dropFirst(length).trimmingCharacters(in: .whitespaces)
        guard !info.contains("`") else { return nil }
        return (length, info.split(separator: " ").first.map(String.init) ?? "")
    }

    private static func closesFence(_ line: String, length: Int) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count >= length && trimmed.allSatisfy { $0 == "`" }
    }

    private static func fencedBlock(language: String, body: [String]) -> ChatBlock {
        switch language.lowercased() {
        case "choices":
            var prompt: [String] = [], options: [String] = []
            for line in body where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                if let option = listItem(line) { options.append(option) } else { prompt.append(line.trimmingCharacters(in: .whitespaces)) }
            }
            return options.count >= 2 ? .choices(prompt: prompt.joined(separator: " "), options: options) : .code(language: language, body: body.joined(separator: "\n"))
        case "draft":
            var draft = DraftCard(body: ""); var rest = body[...]
            while let line = rest.first, let colon = line.firstIndex(of: ":") {
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased(), value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if key == "to" { draft.to = value } else if key == "subject" { draft.subject = value } else { break }
                rest = rest.dropFirst()
            }
            if draft.to != nil || draft.subject != nil, rest.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { rest = rest.dropFirst() }
            draft.body = rest.joined(separator: "\n").trimmingCharacters(in: .newlines)
            return .draft(draft)
        default:
            return .code(language: language, body: body.joined(separator: "\n"))
        }
    }

    /// `- x`, `* x`, `+ x`, `1. x` or `1) x` → `x`.
    static func listItem(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if let first = trimmed.first, "-*+".contains(first), trimmed.dropFirst().first == " " { return nonEmpty(trimmed.dropFirst(2)) }
        return numberedItem(trimmed)
    }

    static func numberedItem(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let digits = trimmed.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let rest = trimmed.dropFirst(digits.count)
        guard let mark = rest.first, mark == "." || mark == ")", rest.dropFirst().first == " " else { return nil }
        return nonEmpty(rest.dropFirst(2))
    }

    private static func nonEmpty(_ value: Substring) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A numbered list that ends the message and is introduced by `<!-- choices -->` becomes a choices card.
    private static func markTrailingChoices(_ blocks: [ChatBlock]) -> [ChatBlock] {
        guard case .markdown(let text)? = blocks.last, let marker = text.range(of: choicesMarker, options: .backwards) else { return blocks }
        let tail = text[marker.upperBound...].components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let options = tail.compactMap(numberedItem)
        guard options.count >= 2, options.count == tail.count else { return blocks }
        let before = String(text[..<marker.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        return Array(blocks.dropLast()) + (before.isEmpty ? [] : [.markdown(before)]) + [.choices(prompt: "", options: options)]
    }

    // MARK: Images and links

    private static let imagePattern = try! NSRegularExpression(pattern: #"!\[([^\]\n]*)\]\(([^)\s]+)\)"#)
    private static let linkPattern = try! NSRegularExpression(pattern: #"(?<!!)\[[^\]\n]*\]\((https?://[^)\s]+)\)"#)
    private static let bareURLPattern = try! NSRegularExpression(pattern: #"(?<!\]\()(?<![<\[/\w])https?://[^\s<>()\[\]`"]+"#)
    private static let inlineCodePattern = try! NSRegularExpression(pattern: "`[^`\n]*`")

    static func isDisplayableImageURL(_ url: String) -> Bool {
        let lowered = url.lowercased()
        return lowered.hasPrefix("https://") || lowered.hasPrefix("http://") || lowered.hasPrefix("data:image/")
    }

    /// Splits prose around Markdown images with an http(s) or `data:image/` source.
    private static func proseBlocks(_ text: String) -> [ChatBlock] {
        var blocks: [ChatBlock] = []; var cursor = text.startIndex
        for match in imagePattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text), let alt = Range(match.range(at: 1), in: text), let url = Range(match.range(at: 2), in: text),
                  isDisplayableImageURL(String(text[url])) else { continue }
            appendMarkdown(String(text[cursor..<range.lowerBound]), to: &blocks)
            blocks.append(.image(alt: String(text[alt]), url: String(text[url]))); cursor = range.upperBound
        }
        appendMarkdown(String(text[cursor...]), to: &blocks)
        return blocks
    }

    private static func appendMarkdown(_ text: String, to blocks: inout [ChatBlock]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { blocks.append(.markdown(trimmed)) }
    }

    static func markdownImages(in text: String) -> [(alt: String, url: String)] {
        parse(text).compactMap { if case .image(let alt, let url) = $0 { (alt, url) } else { nil } }
    }

    /// Bare http(s) URLs outside Markdown links, inline code and angle brackets, de-duplicated in order.
    static func bareURLs(in markdown: String) -> [String] {
        let stripped = inlineCodePattern.stringByReplacingMatches(in: markdown, range: NSRange(markdown.startIndex..., in: markdown), withTemplate: "")
        var seen: Set<String> = []
        return bareURLPattern.matches(in: stripped, range: NSRange(stripped.startIndex..., in: stripped)).compactMap { match in
            guard let range = Range(match.range, in: stripped) else { return nil }
            let url = String(stripped[range]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?'*_"))
            return seen.insert(url).inserted ? url : nil
        }
    }

    /// Every link in a message's prose (Markdown links first, then bare URLs), excluding images and code.
    static func links(in text: String) -> [String] {
        var seen: Set<String> = []; var result: [String] = []
        for case .markdown(let prose) in parse(text) {
            let linked = linkPattern.matches(in: prose, range: NSRange(prose.startIndex..., in: prose)).compactMap { Range($0.range(at: 1), in: prose).map { String(prose[$0]) } }
            for url in linked + bareURLs(in: prose) where seen.insert(url).inserted { result.append(url) }
        }
        return result
    }

    /// "example.com/path…" for a pill label.
    static func pillLabel(_ url: String) -> String {
        guard let components = URLComponents(string: url), let host = components.host else { return url }
        let base = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let path = components.path == "/" ? "" : components.path
        let label = base + path
        return label.count > 42 ? String(label.prefix(41)) + "…" : label
    }
}
