import Foundation

/// A decoded document resolved against local data (P7b): bindings read, `visible_if` applied, defaults filled in,
/// actions bound to their arguments. Platform-neutral, so the Mac (P7b) and iOS (P7c) renderers draw the same tree
/// and `SDUIRenderText.describe` gives both the same golden text. Hidden nodes and fields are left out.
public struct SDUIRenderNode: Equatable, Sendable {
    /// Position in the document ("0", "0.2", "0.6.1"): stable across re-renders, used as view identity.
    public let key: String
    /// The document's `id`, if any.
    public let id: String?
    public let element: SDUIElement
}

public struct SDUIPair: Equatable, Sendable {
    public let key: String
    public let value: String
}

public struct SDUIRenderOption: Equatable, Sendable {
    public let value: String
    public let label: String
}

public struct SDUIRenderField: Equatable, Sendable {
    public let id: String
    public let kind: SDUIFieldKind
    public let label: String
    public let required: Bool
    public let placeholder: String?
    public let options: [SDUIRenderOption]
    /// In characters of the entered text.
    public let maxLength: Int64?
    /// `file_pick` type identifiers (`public.plain-text`).
    public let types: [String]
}

public struct SDUIRenderForm: Equatable, Sendable {
    public let id: String
    public let title: String?
    /// Visible fields only, in document order.
    public let fields: [SDUIRenderField]
    /// Every field's value the form starts from (hidden fields too), from the field's `value` binding.
    public let initial: [String: SDUIFieldValue]
    public let submitLabel: String
    public let submit: SDUIResolvedAction
}

public struct SDUIRenderStep: Equatable, Sendable {
    public let id: String
    public let title: String
    public let children: [SDUIRenderNode]
}

/// An action with its argument read: the copy text, the URL, the screen name or the routine id.
public struct SDUIResolvedAction: Equatable, Sendable {
    public let command: SDUICommand
    public let argument: String?
    /// `open_url` always; any other command when the document asked for `confirm: true`.
    public let requiresConfirmation: Bool
}

public enum SDUIElement: Equatable, Sendable {
    case text(String, style: SDUITextStyle, role: SDUITextRole)
    case badge(String, tone: SDUITone)
    case keyValue([SDUIPair])
    case list([SDUIRenderNode], style: SDUIListStyle)
    case card(title: String?, subtitle: String?, children: [SDUIRenderNode])
    case form(SDUIRenderForm)
    case button(label: String, action: SDUIResolvedAction, style: SDUIButtonStyle)
    case flow(id: String, steps: [SDUIRenderStep])
    /// `value` nil: indeterminate (a binding that is absent or not an integer). Bound values are clamped to 0…total.
    case progress(total: Int64, value: Int64?, label: String?)
    /// The first `max_lines` lines (default 2000) of `lineCount`.
    case diffPreview(title: String?, lines: [String], lineCount: Int)
}

public enum SDUIRenderer {
    public static let defaultTotal: Int64 = 100

    /// The render tree for `document`, or nil when the root itself is hidden. `forms` holds each form's current
    /// values by form id; a form without an entry uses its initial values.
    public static func tree(_ document: SDUIDocument, data: SDUIData,
                            forms: [String: [String: SDUIFieldValue]] = [:]) -> SDUIRenderNode? {
        node(document.root, key: "0", data: data, forms: forms)
    }

    /// Each field's starting value: the bound value read for the field's kind, else empty text (`false` for a toggle).
    /// A choice starts empty unless the bound value is one of its options.
    public static func initialValues(_ fields: [SDUIField], data: SDUIData) -> [String: SDUIFieldValue] {
        var values: [String: SDUIFieldValue] = [:]
        for field in fields {
            let bound = field.value.flatMap { data[$0] }
            switch field.kind {
            case .toggle:
                if case .bool(let flag)? = bound { values[field.id] = .flag(flag) } else { values[field.id] = .flag(false) }
            case .choice:
                let text = bound?.text ?? ""
                let known = field.options?.contains { $0.value.utf8.elementsEqual(text.utf8) } ?? false
                values[field.id] = .text(known ? text : "")
            case .filePick:
                values[field.id] = .text("")
            case .text, .multiline, .date, .schedule:
                values[field.id] = .text(bound?.text ?? "")
            }
        }
        return values
    }

    static func node(_ node: SDUINode, key: String, data: SDUIData,
                     forms: [String: [String: SDUIFieldValue]]) -> SDUIRenderNode? {
        guard data.shows(node.visibleIf) else { return nil }
        func children(_ nodes: [SDUINode], _ prefix: String) -> [SDUIRenderNode] {
            nodes.enumerated().compactMap { self.node($0.element, key: prefix + "." + String($0.offset), data: data, forms: forms) }
        }
        let element: SDUIElement
        switch node.component {
        case .text(let text, let style, let role):
            element = .text(data.text(text), style: style ?? .plain, role: role ?? .body)
        case .badge(let text, let tone):
            element = .badge(data.text(text), tone: tone ?? .neutral)
        case .keyValue(let items):
            element = .keyValue(items.map { SDUIPair(key: data.text($0.key), value: data.text($0.value)) })
        case .list(let nodes, let style):
            element = .list(children(nodes, key), style: style ?? .plain)
        case .card(let title, let subtitle, let nodes):
            element = .card(title: data.optionalText(title), subtitle: data.optionalText(subtitle), children: children(nodes, key))
        case .form(let title, let fields, let submit):
            let formID = node.id ?? ""
            let initial = initialValues(fields, data: data)
            let current = initial.merging(forms[formID] ?? [:]) { _, new in new }
            let scoped = data.with(form: current)
            let visible = fields.filter { scoped.shows($0.visibleIf) }.map { field in
                SDUIRenderField(id: field.id, kind: field.kind, label: scoped.text(field.label), required: field.required ?? false,
                                placeholder: field.placeholder,
                                options: (field.options ?? []).map { SDUIRenderOption(value: $0.value, label: scoped.text($0.label)) },
                                maxLength: field.maxLength, types: field.types ?? [])
            }
            element = .form(SDUIRenderForm(id: formID, title: data.optionalText(title), fields: visible, initial: initial,
                                           submitLabel: scoped.text(submit.label), submit: resolve(submit.action, data: scoped)))
        case .button(let label, let action, let style):
            element = .button(label: data.text(label), action: resolve(action, data: data), style: style ?? .secondary)
        case .flow(let steps):
            element = .flow(id: node.id ?? "", steps: steps.enumerated().map { index, step in
                SDUIRenderStep(id: step.id, title: data.text(step.title), children: children(step.children, key + "." + String(index)))
            })
        case .progress(let declared, let amount, let label):
            let total = declared ?? defaultTotal
            var value: Int64? = nil
            switch amount {
            case .fixed(let number)?: value = number
            case .binding(let binding)?:
                if case .integer(let number)? = data[binding] { value = min(max(number, 0), total) }
            case nil: value = nil
            }
            element = .progress(total: total, value: value, label: data.optionalText(label))
        case .diffPreview(let text, let title, let maxLines):
            let lines = lineSplit(data.text(text))
            let shown = Int(maxLines ?? SDUICatalog.maxLines)
            element = .diffPreview(title: data.optionalText(title), lines: Array(lines.prefix(shown)), lineCount: lines.count)
        }
        return SDUIRenderNode(key: key, id: node.id, element: element)
    }

    /// Split at LF scalars only (a CRLF pair is one Swift `Character`, so `String.split` would not see it).
    static func lineSplit(_ text: String) -> [String] {
        text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }
    }

    static func resolve(_ action: SDUIAction, data: SDUIData) -> SDUIResolvedAction {
        let argument: String?
        switch action.argument {
        case .text(let text)?: argument = data.text(text)
        case .url(let url)?: argument = url
        case .screen(let screen)?: argument = screen.rawValue
        case .routine(let binding)?: argument = data[binding]?.text ?? ""
        case nil: argument = nil
        }
        return SDUIResolvedAction(command: action.command, argument: argument, requiresConfirmation: action.requiresConfirmation)
    }
}
