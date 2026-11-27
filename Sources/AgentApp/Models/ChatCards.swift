import Foundation

/// Inline cards parsed from assistant Markdown (syntax documented in docs/reference.md → "Card syntax").
enum ChatBlock: Equatable {
    case markdown(String)
    case code(language: String, body: String)
    /// Question with options; picking one sends it as the user's reply.
    case choices(prompt: String, options: [String])
    case multiChoices(prompt: String, options: [String])
    /// Draft with inline Edit, Copy, and Send actions.
    case draft(DraftCard)
    case pageDraft(PageDraft)
    case image(alt: String, url: String)
}

struct PageDraft: Codable, Equatable {
    let title: String
    let markdown: String

    var quotedText: String { title + "\n" + markdown }

    enum Decision: String {
        case approve, shorten

        var reply: String {
            switch self {
            case .approve: "I approve the wording of this Page draft."
            case .shorten: "Make this Page draft shorter and return a revised draft for review."
            }
        }
    }
}

struct DraftCard: Hashable, Encodable {
    var to: String?
    var subject: String?
    var body: String
    var channel: String? = nil

    var isEmail: Bool {
        channel?.caseInsensitiveCompare("Email") == .orderedSame || subject != nil
    }
}

enum ChatCardParser {
    static let choicesMarker = "<!-- choices -->"

    /// Parse the visible reply consistently for rendering, card indexes, and action validation.
    static func parseVisibleReply(_ text: String) -> [ChatBlock] {
        parse(SwarmhubBlock.visibleText(text, preservingWhitespace: true), preservingProseWhitespace: true)
    }

    /// Optionally recognize tilde fences when inspecting prose without changing saved card indexes.
    /// The renderer can keep prose whitespace for line structure and list indentation.
    static func parse(_ text: String, includingTildeFences: Bool = false, preservingProseWhitespace: Bool = false, interpretCards: Bool = true) -> [ChatBlock] {
        var blocks: [ChatBlock] = []; var prose: [String] = []
        let lines = text.components(separatedBy: "\n"); var index = 0
        func flush() {
            guard !prose.isEmpty else { return }
            let text = prose.joined(separator: "\n")
            if interpretCards { blocks += proseBlocks(text, preservingWhitespace: preservingProseWhitespace) }
            else { appendMarkdown(text, preservingWhitespace: true, to: &blocks) }
            prose = []
        }
        while index < lines.count {
            guard let fence = fenceOpening(lines[index], includingTildeFences: includingTildeFences) else { prose.append(lines[index]); index += 1; continue }
            flush()
            var body: [String] = []; index += 1
            while index < lines.count, !closesFence(lines[index], mark: fence.mark, length: fence.length) { body.append(lines[index]); index += 1 }
            let closed = index < lines.count
            index += 1
            blocks.append(interpretCards ? fencedBlock(language: fence.info, body: body, closed: closed) : .code(language: fence.info, body: body.joined(separator: "\n")))
        }
        flush()
        return interpretCards ? markTrailingChoices(blocks, preservingWhitespace: preservingProseWhitespace) : blocks
    }

    /// First cut at or after the receipt that keeps a fenced block in one bubble.
    /// An unfinished block continues in its original row until its closing line arrives.
    static func steerBoundary(in text: String, after prefix: String) -> String.Index? {
        let cut = text.index(text.startIndex, offsetBy: prefix.count)
        guard prefix.contains("`") || prefix.contains("~") else { return cut }
        var lineStart = text.startIndex
        while lineStart < cut {
            let lineEnd = text[lineStart...].firstIndex(of: "\n") ?? text.endIndex
            let next = lineEnd == text.endIndex ? lineEnd : text.index(after: lineEnd)
            guard let fence = fenceOpening(String(text[lineStart..<lineEnd]), includingTildeFences: true) else {
                lineStart = next
                continue
            }
            lineStart = next
            var closed = false
            while lineStart < text.endIndex {
                let end = text[lineStart...].firstIndex(of: "\n") ?? text.endIndex
                closed = closesFence(String(text[lineStart..<end]), mark: fence.mark, length: fence.length)
                lineStart = end == text.endIndex ? end : text.index(after: end)
                if closed { break }
            }
            if !closed { return nil }
            if lineStart >= cut { return lineStart }
        }
        return cut
    }

    private static func fenceOpening(_ line: String, includingTildeFences: Bool) -> (mark: Character, length: Int, info: String)? {
        let trimmed = line.drop { $0 == " " }
        guard line.count - trimmed.count <= 3, let mark = trimmed.first, mark == "`" || (includingTildeFences && mark == "~") else { return nil }
        let length = trimmed.prefix { $0 == mark }.count
        guard length >= 3 else { return nil }
        let info = trimmed.dropFirst(length).trimmingCharacters(in: .whitespaces)
        guard mark != "`" || !info.contains("`") else { return nil }
        return (mark, length, info.split(separator: " ").first.map(String.init) ?? "")
    }

    private static func closesFence(_ line: String, mark: Character, length: Int) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count >= length && trimmed.allSatisfy { $0 == mark }
    }

    private static func fencedBlock(language: String, body: [String], closed: Bool) -> ChatBlock {
        switch language.lowercased() {
        case "choices", "choices-multiple":
            var prompt: [String] = [], options: [String] = []
            for line in body where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                if let option = listItem(line) { options.append(option) } else { prompt.append(line.trimmingCharacters(in: .whitespaces)) }
            }
            if language.lowercased() == "choices-multiple", closed, options.count >= 2, Set(options).count == options.count {
                return .multiChoices(prompt: prompt.joined(separator: " "), options: options)
            }
            return language.lowercased() == "choices" && options.count >= 2 ? .choices(prompt: prompt.joined(separator: " "), options: options) : .code(language: language, body: body.joined(separator: "\n"))
        case "page-draft":
            let json = body.joined(separator: "\n")
            guard closed, let draft = try? JSONDecoder().decode(PageDraft.self, from: Data(json.utf8)),
                  !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !draft.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .code(language: language, body: json)
            }
            return .pageDraft(draft)
        case "draft", "email", "message":
            var draft = DraftCard(body: "")
            var rest = body[...]
            headers: while let line = rest.first, let colon = line.firstIndex(of: ":") {
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                switch key {
                case "to": draft.to = value
                case "subject": draft.subject = value
                case "channel", "via": draft.channel = value.isEmpty ? nil : value
                default: break headers
                }
                rest = rest.dropFirst()
            }
            if rest.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { rest = rest.dropFirst() }
            if draft.channel == nil, language.lowercased() == "email" { draft.channel = "Email" }
            draft.body = rest.joined(separator: "\n")
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
    private static func markTrailingChoices(_ blocks: [ChatBlock], preservingWhitespace: Bool) -> [ChatBlock] {
        guard case .markdown(let text)? = blocks.last, let marker = text.range(of: choicesMarker, options: .backwards) else { return blocks }
        let tail = text[marker.upperBound...].components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let options = tail.compactMap(numberedItem)
        guard options.count >= 2, options.count == tail.count else { return blocks }
        var result = Array(blocks.dropLast())
        appendMarkdown(String(text[..<marker.lowerBound]), preservingWhitespace: preservingWhitespace, to: &result)
        result.append(.choices(prompt: "", options: options))
        return result
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
    private static func proseBlocks(_ text: String, preservingWhitespace: Bool) -> [ChatBlock] {
        var blocks: [ChatBlock] = []; var cursor = text.startIndex
        for match in imagePattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text), let alt = Range(match.range(at: 1), in: text), let url = Range(match.range(at: 2), in: text),
                  isDisplayableImageURL(String(text[url])) else { continue }
            appendMarkdown(String(text[cursor..<range.lowerBound]), preservingWhitespace: preservingWhitespace, to: &blocks)
            blocks.append(.image(alt: String(text[alt]), url: String(text[url]))); cursor = range.upperBound
        }
        appendMarkdown(String(text[cursor...]), preservingWhitespace: preservingWhitespace, to: &blocks)
        return blocks
    }

    private static func appendMarkdown(_ text: String, preservingWhitespace: Bool, to blocks: inout [ChatBlock]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { blocks.append(.markdown(preservingWhitespace ? text : trimmed)) }
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
