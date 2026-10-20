import Foundation

/// Text output of the render tree. `describe` is the deterministic golden form shared with iOS (P7c) and the Python
/// statement `scripts/release/ui_render.py`; `inline` is what the native renderers draw for a markdown text.
public enum SDUIRenderText {
    /// One line per element, two spaces of indent per level, strings quoted and escaped, a final newline.
    public static func describe(_ root: SDUIRenderNode?) -> String {
        var lines: [String] = []
        if let root { describe(root, depth: 0, into: &lines) } else { lines.append("(hidden)") }
        return lines.joined(separator: "\n") + "\n"
    }

    static func describe(_ node: SDUIRenderNode, depth: Int, into lines: inout [String]) {
        let pad = String(repeating: "  ", count: depth)
        let id = node.id.map { " id=" + $0 } ?? ""
        func line(_ text: String, _ level: Int = 0) { lines.append(pad + String(repeating: "  ", count: level) + text) }
        func children(_ nodes: [SDUIRenderNode], _ level: Int = 1) {
            for child in nodes { describe(child, depth: depth + level, into: &lines) }
        }
        switch node.element {
        case .text(let text, let style, let role):
            line("text\(id) style=\(style.rawValue) role=\(role.rawValue) \(quote(text))")
        case .badge(let text, let tone):
            line("badge\(id) tone=\(tone.rawValue) \(quote(text))")
        case .keyValue(let pairs):
            line("key_value\(id)")
            for pair in pairs { line("\(quote(pair.key)) = \(quote(pair.value))", 1) }
        case .list(let nodes, let style):
            line("list\(id) style=\(style.rawValue)")
            children(nodes)
        case .card(let title, let subtitle, let nodes):
            line("card\(id)" + (title.map { " title=" + quote($0) } ?? "") + (subtitle.map { " subtitle=" + quote($0) } ?? ""))
            children(nodes)
        case .form(let form):
            line("form\(id)" + (form.title.map { " title=" + quote($0) } ?? ""))
            for field in form.fields {
                var text = "field \(field.kind.rawValue) id=\(field.id) label=\(quote(field.label))"
                if field.required { text += " required" }
                if let placeholder = field.placeholder { text += " placeholder=" + quote(placeholder) }
                if let maxLength = field.maxLength { text += " max_length=" + String(maxLength) }
                if !field.types.isEmpty { text += " types=" + field.types.joined(separator: ",") }
                text += " value=" + quote(form.initial[field.id]?.text ?? "")
                line(text, 1)
                for option in field.options { line("option \(option.value) \(quote(option.label))", 2) }
            }
            line("submit \(quote(form.submitLabel)) \(action(form.submit))", 1)
        case .button(let label, let resolved, let style):
            line("button\(id) style=\(style.rawValue) \(quote(label)) \(action(resolved))")
        case .flow(_, let steps):
            line("flow\(id)")
            for step in steps {
                line("step id=\(step.id) title=\(quote(step.title))", 1)
                children(step.children, 2)
            }
        case .progress(let total, let value, let label):
            line("progress\(id) total=\(total) value=\(value.map { String($0) } ?? "none")" + (label.map { " label=" + quote($0) } ?? ""))
        case .diffPreview(let title, let shown, let count):
            line("diff_preview\(id)" + (title.map { " title=" + quote($0) } ?? "") + " lines=\(shown.count)/\(count)")
            for text in shown { line(quote(text), 1) }
        }
    }

    static func action(_ action: SDUIResolvedAction) -> String {
        var text = "-> " + action.command.rawValue
        if let name = action.command.argument, let value = action.argument { text += " \(name)=\(quote(value))" }
        if action.requiresConfirmation { text += " confirm" }
        return text
    }

    /// `"`-quoted; backslash, quote, LF, tab and CR escaped, other scalars below U+0020 as `\u00xx`, the rest as is.
    public static func quote(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default:
                if scalar.value < 0x20 {
                    let hex = String(scalar.value, radix: 16)
                    out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    /// A `markdown` text as inline styling only (bold, italic, code): whitespace kept, block syntax left as text, and
    /// every link and image attribute removed, whatever produced it (SCHEMAS.md §13: link interpretation off). Text
    /// that does not parse is shown as plain text.
    public static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(allowsExtendedAttributes: false,
                                                              interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        guard var styled = try? AttributedString(markdown: text, options: options) else { return AttributedString(text) }
        unlinked(&styled)
        return styled
    }

    /// Plain text never carries attributes; markdown loses every `link` and `imageURL`.
    public static func unlinked(_ text: inout AttributedString) {
        let linked = text.runs.filter { $0.link != nil || $0.imageURL != nil }.map(\.range)
        for range in linked {
            text[range].link = nil
            text[range].imageURL = nil
        }
    }

    public static func hasLinks(_ text: AttributedString) -> Bool {
        text.runs.contains { $0.link != nil || $0.imageURL != nil }
    }
}
