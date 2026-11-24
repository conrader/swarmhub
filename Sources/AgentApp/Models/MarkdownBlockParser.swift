import Foundation

enum MarkdownBlock: Equatable {
    case paragraph(String)
    case heading(level: Int, text: String)
    indirect case quote([MarkdownBlock])
    case rule
    case list([MarkdownListItem])
    case table(header: [String], rows: [[String]])
}

struct MarkdownListItem: Equatable {
    let number: String?
    let depth: Int
    var text: String
}

/// Parses the prose left after ChatCardParser extracts cards, fences and images.
/// Inline Markdown stays in the strings for SwiftUI's attributed text.
enum MarkdownBlockParser {
    static func parse(_ text: String) -> [MarkdownBlock] {
        parse(text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(Line.init), quoteDepth: 0)
    }

    private static func parse(_ lines: [Line], quoteDepth: Int) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [Substring] = []
        var index = 0

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph.removeAll(keepingCapacity: true)
        }

        while index < lines.count {
            let line = lines[index]
            let block: MarkdownBlock
            if line.content.isEmpty {
                flushParagraph()
                index += 1
                continue
            } else if let heading = line.heading {
                block = heading
                index += 1
            } else if line.isRule {
                block = .rule
                index += 1
            } else if line.content.first == ">" {
                var quoted: [Line] = []
                while index < lines.count, let inner = lines[index].quoteContent {
                    // Collapse excess levels so pasted quote markers cannot produce an unbounded view tree.
                    let line = Line(inner)
                    if quoteDepth == 7, line.content.first == ">" {
                        quoted.append(Line(line.content.drop { $0 == ">" || isIndent($0) }))
                    } else {
                        quoted.append(line)
                    }
                    index += 1
                }
                block = .quote(parse(quoted, quoteDepth: quoteDepth + 1))
            } else if let item = line.listMarker {
                block = .list(readList(lines, index: &index, first: item))
            } else if let header = tableHeader(in: lines, at: index) {
                index += 2
                var rows: [[String]] = []
                while index < lines.count, let cells = tableCells(in: lines[index]), cells.count == header.count {
                    rows.append(cells)
                    index += 1
                }
                block = .table(header: header, rows: rows)
            } else {
                paragraph.append(line.raw)
                index += 1
                continue
            }
            flushParagraph()
            blocks.append(block)
        }
        flushParagraph()
        return blocks
    }

    private static func readList(_ lines: [Line], index: inout Int, first: ListMarker) -> [MarkdownListItem] {
        var items: [MarkdownListItem] = []
        let baseIndent = lines[index].indent
        var indents = [baseIndent]
        let ordered = first.number != nil

        while index < lines.count {
            let line = lines[index]
            guard !line.isRule, let marker = line.listMarker, line.indent >= baseIndent,
                  line.indent > baseIndent || (marker.number != nil) == ordered else { break }
            while let indent = indents.last, indent > line.indent { indents.removeLast() }
            if indents.last != line.indent { indents.append(line.indent) }

            var itemLines = [marker.text]
            index += 1
            while index < lines.count {
                let next = lines[index]
                guard next.indent > line.indent, !next.content.isEmpty, !next.isRule,
                      next.listMarker == nil, next.heading == nil, next.quoteContent == nil,
                      tableHeader(in: lines, at: index) == nil else { break }
                itemLines.append(next.content)
                index += 1
            }
            items.append(MarkdownListItem(number: marker.number, depth: indents.count - 1, text: itemLines.joined(separator: "\n")))
        }
        return items
    }

    private static func tableHeader(in lines: [Line], at index: Int) -> [String]? {
        guard index + 1 < lines.count, let header = tableCells(in: lines[index]),
              let separator = tableCells(in: lines[index + 1]), separator.count == header.count,
              separator.allSatisfy(isTableSeparator) else { return nil }
        return header
    }

    private static func isTableSeparator(_ cell: String) -> Bool {
        let afterStart = cell.first == ":" ? cell.dropFirst() : cell[...]
        let dashes = afterStart.last == ":" ? afterStart.dropLast() : afterStart
        return dashes.count >= 3 && dashes.allSatisfy { $0 == "-" }
    }

    private static func tableCells(in line: Line) -> [String]? {
        guard line.content.first == "|" else { return nil }
        let row = trimTrailing(line.content, while: isIndent)
        guard row.last == "|" else { return nil }
        var cells: [String] = []
        var start = row.index(after: row.startIndex)
        var escaped = false
        for index in row.indices.dropFirst() {
            let character = row[index]
            if character == "|", !escaped {
                let cell = row[start..<index].replacingOccurrences(of: "\\|", with: "|")
                cells.append(cell.trimmingCharacters(in: .whitespaces))
                start = row.index(after: index)
            }
            escaped = character == "\\" && !escaped
        }
        return !cells.isEmpty && start == row.endIndex ? cells : nil
    }

    private static func isIndent(_ character: Character) -> Bool {
        character == " " || character == "\t"
    }

    private static func trimTrailing(_ text: Substring, while predicate: (Character) -> Bool) -> Substring {
        guard let last = text.lastIndex(where: { !predicate($0) }) else { return text[..<text.startIndex] }
        return text[...last]
    }

    private struct ListMarker {
        let number: String?
        let text: Substring
    }

    private struct Line {
        let raw: Substring
        let content: Substring
        let indent: Int

        init(_ raw: Substring) {
            self.raw = raw
            let prefix = raw.prefix(while: isIndent)
            content = raw[prefix.endIndex...]
            indent = prefix.reduce(0) { column, character in
                character == "\t" ? column + 4 - column % 4 : column + 1
            }
        }

        var heading: MarkdownBlock? {
            guard content.first == "#" else { return nil }
            let hashes = content.prefix { $0 == "#" }
            let level = hashes.count
            let rest = content[hashes.endIndex...]
            guard level <= 6, let first = rest.first, isIndent(first) else { return nil }
            let trimmed = trimTrailing(rest, while: isIndent)
            let beforeCloser = trimTrailing(trimmed) { $0 == "#" }
            let body = beforeCloser.last.map(isIndent) == true ? trimTrailing(beforeCloser, while: isIndent) : trimmed
            return .heading(level: level, text: String(body.drop(while: isIndent)))
        }

        var quoteContent: Substring? {
            guard content.first == ">" else { return nil }
            let body = content.dropFirst()
            return body.first == " " ? body.dropFirst() : body
        }

        var isRule: Bool {
            guard let mark = content.first, "-*_".contains(mark) else { return false }
            var count = 0
            for character in content {
                if character == mark {
                    count += 1
                } else if !isIndent(character) {
                    return false
                }
            }
            return count >= 3
        }

        var listMarker: ListMarker? {
            guard let first = content.first else { return nil }
            let number: String?
            let rest: Substring
            if "-*+".contains(first) {
                number = nil
                rest = content.dropFirst()
            } else {
                guard first.isASCII, first.isNumber else { return nil }
                let digits = content.prefix { $0.isASCII && $0.isNumber }
                let suffix = content[digits.endIndex...]
                guard suffix.first == "." else { return nil }
                number = String(digits)
                rest = suffix.dropFirst()
            }
            guard let space = rest.first, isIndent(space) else { return nil }
            let body = rest.drop(while: isIndent)
            return body.isEmpty ? nil : ListMarker(number: number, text: body)
        }
    }
}
