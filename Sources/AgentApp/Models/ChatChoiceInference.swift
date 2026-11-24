import Foundation

struct ChatChoiceOption: Equatable {
    let label: String
    let reply: String
}

enum ChatChoiceAnswer {
    case option(String)
    case other(String)

    func text(options: [String]) -> String? {
        switch self {
        case .option(let reply): return options.contains(reply) ? reply : nil
        case .other(let reply):
            let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }
}

enum ChatChoiceInference {
    static let answerKey = "picked.inferred"
    private static let lineItem = try! NSRegularExpression(pattern: #"^ {0,3}([0-9]{1,3}|[A-Za-z])[.)][ \t]+(\S.*)$"#)
    private static let inlineItem = try! NSRegularExpression(pattern: #"(?<!\S)([0-9]{1,3}|[A-Za-z])[.)][ \t]+(?=\S)"#)
    private static let choiceCue = try! NSRegularExpression(pattern: #"""
    (?ix)(?:^|[.!?][ \t]+)(?:please\s+)?(?:
        (?:tell\ me|let\ me\ know)(?:\s*:|\s+(?:which\b|(?:how|what|where)\s+you(?:\s+would|['’]d|\s+want)\b|your\ (?:choice|preference)\b).*)
      | (?:choose|pick|select)\s+(?:(?:one\b|an\ option\b|from\b).*|[^:?!]+:)
      | which\s+(?:(?:one|option|way|of\ these|of\ the\ following)\s*[:?]|.*\b(?:would\ you|do\ you|should\ (?:I|we)|works\ for\ you)\b.*)
      | (?:how|what)\s+(?:should\ I|would\ you\ like\ me\ to|do\ you\ want\ (?:to\ proceed|me\ to))\b.*
      | would\ you\ (?:like|prefer)\b.*\b(?:choose|pick|one\ of\ these)\b.*[:?]
      | (?:what|which)\s+.*\b(?:works|sounds)\ best\ for\ you\b.*
      | (?:do\ you\ want\ me\ to|would\ you\ like\ me\ to|would\ you\ prefer)\s*:
    )$
    """#)
    private static let stepCue = try! NSRegularExpression(pattern: #"(?i)\b(?:follow (?:these|the)|in this order|steps to|step.by.step|checklist)\b"#)
    private static let yesNoQuestion = try! NSRegularExpression(pattern: #"(?i)(?:^|[.!?][ \t]+)((?:should I|shall I|may I|can I|would you like|do you (?:want|agree|approve)|are you (?:ready|okay|happy)|(?:is|would) (?:that|this|it) (?:be )?(?:okay|ok|fine|acceptable))\b[^?]*\?)$"#)
    private static let alternatives = try! NSRegularExpression(pattern: #"(?i)\bor\b"#)
    private static let explicitYesNo = try! NSRegularExpression(pattern: #"(?i)\?\s*\(?yes\s*(?:/| or )\s*no\)?[.!]?$|\(yes\s*(?:/| or )\s*no\)\s*\?$"#)
    private static let bothSuffix = try! NSRegularExpression(pattern: #"(?i)(?:\(\s*(?:or\s+)?both\s*\)|[,;]?\s+or\s+both)[.!?]?$"#)
    private static let bothFooter = try! NSRegularExpression(pattern: #"(?i)^(?:\((?:or )?both\)|or both|(?:you can|feel free to) (?:also )?(?:choose|pick|select|do) both)[.!?]?$"#)
    private static let bothCue = try! NSRegularExpression(pattern: #"(?i)\b(?:or both|choose both|pick both)\b"#)
    private static let lead = try! NSRegularExpression(pattern: #"^(?:\*\*(.+?)\*\*|__(.+?)__)(?=[\s:.,!?–—-]|$)"#)

    /// Keep the original Markdown intact. Only infer from the trailing prose of a reply with no explicit card.
    static func options(in content: String) -> [ChatChoiceOption]? {
        let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")
        let visible = SwarmhubBlock.visibleText(normalized)
        let blocks = ChatCardParser.parse(visible, includingTildeFences: true)
        guard !blocks.contains(where: { if case .choices = $0 { true } else { false } }),
              case .markdown(let prose)? = blocks.last,
              let lastLine = normalized.split(separator: "\n").last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              !lastLine.hasPrefix("    "), !lastLine.hasPrefix("\t") else { return nil }
        var lines = prose.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let last = lines.last else { return nil }
        let footerAllowsBoth = matches(bothFooter, last.trimmingCharacters(in: .whitespaces))
        if footerAllowsBoth { lines.removeLast() }
        guard let tail = lines.last else { return nil }
        let suffix = bothSuffix.firstMatch(in: tail, range: NSRange(tail.startIndex..., in: tail)).flatMap { Range($0.range, in: tail) }
        if let suffix { lines[lines.count - 1] = String(tail[..<suffix.lowerBound]) }

        if let list = listed(in: lines) ?? inline(in: lines[lines.count - 1]), isSequential(list.items.map(\.reply)) {
            var options = list.items.map { ChatChoiceOption(label: label(for: $0.body), reply: $0.reply) }
            guard options.allSatisfy({ !$0.label.isEmpty }) else { return nil }
            if (footerAllowsBoth || suffix != nil || matches(bothCue, list.cue)), options.count == 2,
               !options.contains(where: { $0.label.caseInsensitiveCompare("Both") == .orderedSame }) {
                options.append(ChatChoiceOption(label: "Both", reply: "Both"))
            }
            return options
        }

        let question = last.trimmingCharacters(in: CharacterSet(charactersIn: " *_"))
        guard !question.hasPrefix(">"), !question.hasPrefix("`"), ChatCardParser.listItem(last) == nil, !matches(lineItem, last),
              matches(explicitYesNo, question) || (capture(yesNoQuestion, 1, in: question).map { !matches(alternatives, $0) } ?? false) else { return nil }
        return [ChatChoiceOption(label: "Yes", reply: "Yes"), ChatChoiceOption(label: "No", reply: "No")]
    }

    private typealias Item = (reply: String, body: String)

    private static func listed(in lines: [String]) -> (cue: String, items: [Item])? {
        var items: [Item] = []
        for line in lines.reversed() {
            guard let reply = capture(lineItem, 1, in: line), let body = capture(lineItem, 2, in: line) else {
                guard items.count >= 2, isChoiceCue(line) else { return nil }
                items.reverse()
                return (line, items)
            }
            items.append((reply, body))
        }
        return nil
    }

    private static func inline(in line: String) -> (cue: String, items: [Item])? {
        let markers = inlineItem.matches(in: line, range: NSRange(line.startIndex..., in: line))
        guard markers.count >= 2, let first = markers.first, let start = Range(first.range, in: line)?.lowerBound else { return nil }
        let cue = String(line[..<start])
        guard isChoiceCue(cue) else { return nil }
        let items: [Item] = markers.enumerated().compactMap { index, marker in
            guard let reply = Range(marker.range(at: 1), in: line), let body = Range(marker.range, in: line)?.upperBound else { return nil }
            let end = index + 1 < markers.count ? Range(markers[index + 1].range, in: line)?.lowerBound ?? line.endIndex : line.endIndex
            return (String(line[reply]), String(line[body..<end]))
        }
        return (cue, items)
    }

    private static func isSequential(_ replies: [String]) -> Bool {
        replies.count >= 2 && replies.enumerated().allSatisfy { index, reply in
            if replies[0] == "1" { return reply == String(index + 1) }
            return reply.uppercased().utf8.first.map { Int($0) == 65 + index } == true && reply.count == 1
        }
    }

    private static func isChoiceCue(_ line: String) -> Bool {
        let text = line.trimmingCharacters(in: CharacterSet(charactersIn: " *_"))
        return !line.hasPrefix("    ") && !text.hasPrefix(">") && !text.hasPrefix("`") &&
            matches(choiceCue, text) && !matches(stepCue, text)
    }

    private static func label(for body: String) -> String {
        let body = body.trimmingCharacters(in: .whitespaces)
        let leadText = capture(lead, 1, in: body) ?? capture(lead, 2, in: body) ??
            String(body[..<(body.range(of: #"\s+[—–-]\s+|[:.!?]\s"#, options: .regularExpression)?.lowerBound ?? body.endIndex)])
        let plain = (try? AttributedString(markdown: leadText, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))).map { String($0.characters) } ?? leadText
        let title = plain.trimmingCharacters(in: .whitespaces)
        guard title.count > 48 else { return title }
        let prefix = title.prefix(47)
        let shortened = prefix.lastIndex(of: " ").map { prefix[..<$0] } ?? prefix
        return String(shortened.count >= 32 ? shortened : prefix) + "…"
    }

    private static func matches(_ pattern: NSRegularExpression, _ text: String) -> Bool {
        pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func capture(_ pattern: NSRegularExpression, _ group: Int, in text: String) -> String? {
        guard let match = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: group), in: text) else { return nil }
        return String(text[range])
    }
}
