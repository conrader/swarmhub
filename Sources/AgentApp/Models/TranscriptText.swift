import Foundation

/// A message-local UTF-16 coordinate space, shared by TextKit and the clipboard. Only
/// rendered text contributes offsets. Layout, Markdown syntax and control labels do not.
struct TranscriptText {
    struct Run {
        let value: AttributedString
        let offset: Int
    }
    indirect enum Prose {
        case paragraph(Run), heading(Int, Run), quote([Prose]), rule
        case list([(depth: Int, marker: Run, text: Run)])
        case table([[Run]])
    }
    struct Block {
        let card: ChatBlock
        var prose: [Prose] = []
        var run: Run?
    }

    private(set) var string = ""
    private var length = 0
    private(set) var parts: [[Block]] = []

    init() {}

    init(reply: String, segments: [ReplySegment]?) {
        for segment in segments ?? [.text(reply)] {
            guard case let .text(source) = segment else { parts.append([]); continue }
            addPart(ChatCardParser.parseVisibleReply(source))
        }
    }

    init(user: String) {
        addPart(ChatCardParser.parse(user, includingTildeFences: true, interpretCards: false))
    }

    private mutating func addPart(_ cards: [ChatBlock]) {
        var blocks: [Block] = []
        for card in cards {
            var block = Block(card: card)
            switch card {
            case .markdown(let text): block.prose = prose(text)
            case .code(_, let code): block.run = append(AttributedString(code.trimmingCharacters(in: .newlines)))
            case .choices(let prompt, _), .multiChoices(let prompt, _):
                if !prompt.isEmpty { block.run = append(AttributedString(prompt)) }
            case .image, .draft: break // Media and draft editors manage their own focus and copy actions.
            }
            blocks.append(block)
        }
        parts.append(blocks)
    }

    mutating func prose(_ source: String) -> [Prose] {
        format(MarkdownBlockParser.parse(source))
    }

    private mutating func format(_ blocks: [MarkdownBlock]) -> [Prose] {
        blocks.map { block in
            switch block {
            case .paragraph(let text): return .paragraph(append(Self.inline(text)))
            case .heading(let level, let text): return .heading(level, append(Self.inline(text)))
            case .quote(let children): return .quote(format(children))
            case .rule: return .rule
            case .list(let items):
                return .list(items.enumerated().map { index, item in
                    let marker = item.number.map { $0 + "." } ?? (item.depth == 0 ? "•" : "◦")
                    let bullet = append(AttributedString(marker), separator: index == 0 ? "\n\n" : "\n")
                    return (item.depth, bullet, append(Self.inline(item.text), separator: " "))
                })
            case .table(let header, let rows):
                return .table(([header] + rows).enumerated().map { row, cells in
                    cells.enumerated().map { col, cell in
                        append(Self.inline(cell), separator: col > 0 ? "\t" : row > 0 ? "\n" : "\n\n")
                    }
                })
            }
        }
    }

    static func inline(_ source: String) -> AttributedString {
        (try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(source)
    }

    @discardableResult private mutating func append(_ value: AttributedString, separator: String = "\n\n") -> Run {
        if length > 0 { string += separator; length += separator.utf16.count }
        let run = Run(value: value, offset: length)
        let plain = String(value.characters)
        string += plain
        length += plain.utf16.count
        return run
    }
}
