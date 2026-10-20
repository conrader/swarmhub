import Foundation

/// SDUI catalogue v1 (`swarmhub/ui/1`, SCHEMAS.md §13; CORE-PLAN.md §5). View documents are data read by compiled
/// code: a closed set of components, typed predicates and a closed enum of existing local commands. There are no
/// expressions, loops or scripts, and nothing can describe or reach `operation_review`, `secret_entry` or any other
/// approval or secret surface. The Python statement of the same rules is `scripts/release/ui_reference.py`.
public enum SDUICatalog {
    public static let schema = "swarmhub/ui/1"

    // Patterns match the whole string (`matches`), as in SCHEMAS.md §3.
    static let namePattern = "[a-z][a-z0-9_]{0,63}"
    static let bindingPattern = "[a-z][a-z0-9_]{0,31}(\\.[a-z][a-z0-9_]{0,31}){0,5}"
    static let optionPattern = "[A-Za-z0-9._-]{1,64}"
    static let fileTypePattern = "[a-z0-9]+(\\.[a-z0-9-]+)+"
    static let urlPattern = "https://[a-z0-9-]+(\\.[a-z0-9-]+)+(/[A-Za-z0-9._~%/-]*)?(\\?[A-Za-z0-9._~%&=-]*)?"
    static let maxURLBytes = 2048
    static let maxTotal: Int64 = 1_000_000
    static let maxLines: Int64 = 2000
    static let maxFileTypes = 16
    static let markupForbidden = "[]<"

    static let commonMembers: Set<String> = ["type", "id", "visible_if"]
    static let fieldMembers: Set<String> = ["id", "kind", "label", "required", "placeholder", "options", "max_length",
                                            "types", "value", "visible_if"]
    static let bindingRoots: Set<String> = ["app", "box", "form", "profile", "record", "result", "routine"]

    /// A view, component type, command, screen or field kind naming an approval or secret surface is `denied_route`:
    /// lowercased (ASCII) with `.`, `_` and `-` removed, it contains one of these.
    static let surfaceFragments: [String] = ["operationreview", "secretentry", "approv", "secret", "keychain",
        "credential", "enroll", "password", "passphrase", "token", "apikey", "privatekey", "signingkey", "hmac", "nonce"]
    /// A binding segment or form field id is `denied_binding` when, with `_` removed, it contains one of these, or one
    /// of its `_`-separated words is in `bindingWords`.
    static let bindingFragments: [String] = ["approv", "secret", "token", "password", "passphrase", "credential",
        "keychain", "apikey", "privatekey", "signingkey", "hmac", "nonce", "signature", "authent", "authoriz", "cookie",
        "session"]
    static let bindingWords: Set<String> = ["auth", "key", "keys", "pin", "pins", "device", "devices", "gate", "gates",
                                            "otp"]

    static func deniedSurface(_ name: String) -> Bool {
        let compact = name.utf8.compactMap { byte -> UInt8? in
            if byte == 0x2E || byte == 0x5F || byte == 0x2D { return nil }
            return (0x41...0x5A).contains(byte) ? byte + 32 : byte
        }
        return surfaceFragments.contains { containsBytes(compact, Array($0.utf8)) }
    }

    static func deniedSegment(_ segment: String) -> Bool {
        let compact = segment.utf8.filter { $0 != 0x5F }
        return bindingFragments.contains { containsBytes(compact, Array($0.utf8)) }
            || segment.split(separator: "_", omittingEmptySubsequences: false).contains { bindingWords.contains(String($0)) }
    }

    /// Byte search, so the result never depends on grapheme or canonical-equivalence rules.
    static func containsBytes(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return needle.isEmpty }
        for start in 0...(haystack.count - needle.count) where haystack[start..<(start + needle.count)].elementsEqual(needle) {
            return true
        }
        return false
    }
}

public enum SDUIComponentType: String, CaseIterable, Sendable {
    case text, badge, keyValue = "key_value", list, card, form, button, flow, progress, diffPreview = "diff_preview"

    /// Required and optional members besides `type`, `id` and `visible_if`.
    var members: (required: Set<String>, optional: Set<String>) {
        switch self {
        case .text: return (["text"], ["style", "role"])
        case .badge: return (["text"], ["tone"])
        case .keyValue: return (["items"], [])
        case .list: return (["children"], ["style"])
        case .card: return (["children"], ["title", "subtitle"])
        case .form: return (["id", "fields", "submit"], ["title"])
        case .button: return (["label", "action"], ["style"])
        case .flow: return (["id", "steps"], [])
        case .progress: return ([], ["total", "value", "label"])
        case .diffPreview: return (["text"], ["title", "max_lines"])
        }
    }
}

public enum SDUITextStyle: String, CaseIterable, Sendable {
    case plain, markdown
}

public enum SDUITextRole: String, CaseIterable, Sendable {
    case body, title, headline, caption, footnote, monospace
}

public enum SDUITone: String, CaseIterable, Sendable {
    case neutral, info, success, warning, danger
}

public enum SDUIListStyle: String, CaseIterable, Sendable {
    case plain, bulleted, numbered
}

public enum SDUIButtonStyle: String, CaseIterable, Sendable {
    case primary, secondary, destructive
}

public enum SDUIFieldKind: String, CaseIterable, Sendable {
    case text, multiline, choice, toggle, date, schedule, filePick = "file_pick"
}

/// The closed enum of local app commands a document may bind to a button or form submit. A new command needs an
/// app build (CORE-PLAN.md §5.2). None of them decides, approves, enrolls or reads a secret.
public enum SDUICommand: String, CaseIterable, Sendable {
    case dismiss, refresh, flowNext = "flow_next", flowBack = "flow_back", copyText = "copy_text", openURL = "open_url"
    case navigate, routineOpen = "routine.open", routineRunNow = "routine.run_now", routinePause = "routine.pause"
    case routineResume = "routine.resume", routineCreate = "routine.create", routineSave = "routine.save"

    /// The one required argument member, if any.
    var argument: String? {
        switch self {
        case .copyText: return "text"
        case .openURL: return "url"
        case .navigate: return "screen"
        case .routineOpen, .routineRunNow, .routinePause, .routineResume, .routineSave: return "routine"
        case .dismiss, .refresh, .flowNext, .flowBack, .routineCreate: return nil
        }
    }
    /// Valid only as a form's `submit` action, and nowhere else.
    var isFormSubmit: Bool { self == .routineCreate || self == .routineSave }
    /// Valid only inside a `flow` step.
    var isFlowStep: Bool { self == .flowNext || self == .flowBack }
}

/// Screens `navigate` may open. Approval, review and secret screens are compiled and unreachable from documents.
public enum SDUIScreen: String, CaseIterable, Sendable {
    case routines, chat, boxes, skills, settings, updates
}

public struct SDUILimits: Equatable, Sendable {
    public var maxDocumentBytes = 65_536
    public var maxDepth = 12
    public var maxNodes = 256
    public var maxChildren = 64
    public var maxStringBytes = 4096
    public init() {}
}

public struct SDUIPolicy: Sendable {
    public var limits: SDUILimits
    /// Hosts `open_url` may open, matched exactly (https, no port, no userinfo). Empty by default, so every URL action
    /// is refused until the app passes its compiled allowlist.
    public var urlHosts: Set<String>

    public init(limits: SDUILimits = SDUILimits(), urlHosts: Set<String> = []) {
        self.limits = limits
        self.urlHosts = urlHosts
    }
}

// MARK: Decoded documents. Every value is checked; nothing is kept that the decoder did not understand.

public struct SDUIBinding: Equatable, Sendable {
    /// A dotted path into local data the app already holds (`routine.name`); never evaluated as an expression.
    public let path: String
    public var segments: [String] { path.split(separator: ".").map(String.init) }
}

/// Strings are rendered as text, never markup (markdown subset only for `text` with style `markdown`).
public enum SDUIText: Equatable, Sendable {
    case literal(String)
    case binding(SDUIBinding)
}

public enum SDUILiteral: Equatable, Sendable {
    case string(String), integer(Int64), bool(Bool)
}

/// Closed, typed predicates on local data (CORE-PLAN.md §5.3). No expression strings.
public enum SDUIPredicate: Equatable, Sendable {
    case exists(SDUIBinding)
    case missing(SDUIBinding)
    case equals(SDUIBinding, SDUILiteral)
}

public struct SDUIAction: Equatable, Sendable {
    public enum Argument: Equatable, Sendable {
        case text(SDUIText)
        /// Already checked against the allowlist given to the decoder.
        case url(String)
        case screen(SDUIScreen)
        case routine(SDUIBinding)
    }
    public let command: SDUICommand
    public let argument: Argument?
    /// As written in the document. Renderers honour `requiresConfirmation`, which a document cannot turn off.
    public let confirm: Bool?

    public var requiresConfirmation: Bool { command == .openURL || confirm == true }
    public var url: URL? {
        guard case .url(let text)? = argument else { return nil }
        return URL(string: text)
    }
}

public struct SDUIKeyValueItem: Equatable, Sendable {
    public let key: SDUIText
    public let value: SDUIText
}

public struct SDUIOption: Equatable, Sendable {
    public let value: String
    public let label: SDUIText
}

public struct SDUIField: Equatable, Sendable {
    public let id: String
    public let kind: SDUIFieldKind
    public let label: SDUIText
    public let required: Bool?
    public let placeholder: String?
    public let options: [SDUIOption]?
    public let maxLength: Int64?
    public let types: [String]?
    public let value: SDUIBinding?
    public let visibleIf: SDUIPredicate?
}

public struct SDUISubmit: Equatable, Sendable {
    public let label: SDUIText
    public let action: SDUIAction
}

public struct SDUIFlowStep: Equatable, Sendable {
    public let id: String
    public let title: SDUIText
    public let children: [SDUINode]
}

public enum SDUIProgressValue: Equatable, Sendable {
    case fixed(Int64)
    case binding(SDUIBinding)
}

public enum SDUIComponent: Equatable, Sendable {
    case text(SDUIText, style: SDUITextStyle?, role: SDUITextRole?)
    case badge(SDUIText, tone: SDUITone?)
    case keyValue([SDUIKeyValueItem])
    case list([SDUINode], style: SDUIListStyle?)
    case card(title: SDUIText?, subtitle: SDUIText?, children: [SDUINode])
    /// The form id is the node's `id`, which forms require.
    case form(title: SDUIText?, fields: [SDUIField], submit: SDUISubmit)
    case button(label: SDUIText, action: SDUIAction, style: SDUIButtonStyle?)
    /// The flow id is the node's `id`, which flows require.
    case flow(steps: [SDUIFlowStep])
    case progress(total: Int64?, value: SDUIProgressValue?, label: SDUIText?)
    case diffPreview(SDUIText, title: SDUIText?, maxLines: Int64?)

    public var type: SDUIComponentType {
        switch self {
        case .text: .text
        case .badge: .badge
        case .keyValue: .keyValue
        case .list: .list
        case .card: .card
        case .form: .form
        case .button: .button
        case .flow: .flow
        case .progress: .progress
        case .diffPreview: .diffPreview
        }
    }
}

public struct SDUINode: Equatable, Sendable {
    public let id: String?
    public let visibleIf: SDUIPredicate?
    public let component: SDUIComponent
}

public struct SDUIDocument: Equatable, Sendable {
    public let view: String
    public let critical: Bool?
    public let root: SDUINode
    public var isCritical: Bool { critical == true }
}
