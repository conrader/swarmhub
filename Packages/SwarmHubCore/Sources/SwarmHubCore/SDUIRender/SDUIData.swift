import Foundation

/// A value from local data the app already holds (P7b, CORE-PLAN.md §5.1). Documents bind to these by path;
/// nothing is evaluated.
public enum SDUIDataValue: Equatable, Sendable {
    case string(String), integer(Int64), bool(Bool)

    /// How a bound value reads as text: strings as they are, integers in decimal, booleans `true` / `false`.
    public var text: String {
        switch self {
        case .string(let text): return text
        case .integer(let number): return String(number)
        case .bool(let flag): return flag ? "true" : "false"
        }
    }
}

/// A form field's current value. `text` for `text`, `multiline`, `choice` (the option value), `date` (ISO 8601),
/// `schedule` (the schedule text) and `file_pick` (the picked file's name only); `flag` for `toggle`.
public enum SDUIFieldValue: Equatable, Sendable {
    case text(String), flag(Bool)

    public var text: String {
        switch self {
        case .text(let text): return text
        case .flag(let flag): return flag ? "true" : "false"
        }
    }
    var data: SDUIDataValue {
        switch self {
        case .text(let text): return .string(text)
        case .flag(let flag): return .bool(flag)
        }
    }
}

/// The local data one view is rendered against: binding path → value. The app fills it from its own models
/// (a routine, a run result); a document reads only paths present here and never writes them. Paths with a
/// segment on the binding denylist are dropped on the way in, so even an app mistake cannot expose them.
public struct SDUIData: Equatable, Sendable {
    public let values: [String: SDUIDataValue]

    public init(_ values: [String: SDUIDataValue] = [:]) {
        self.values = values.filter { entry in
            !entry.key.split(separator: ".", omittingEmptySubsequences: false)
                .contains { SDUICatalog.deniedSegment(String($0)) }
        }
    }

    public subscript(_ binding: SDUIBinding) -> SDUIDataValue? { values[binding.path] }

    /// A literal as written, or the bound value as text; an absent binding reads as empty text.
    public func text(_ text: SDUIText) -> String {
        switch text {
        case .literal(let literal): return literal
        case .binding(let binding): return self[binding]?.text ?? ""
        }
    }

    public func optionalText(_ text: SDUIText?) -> String? { text.map(self.text) }

    /// `exists`: present and, for a string, not empty. `missing` is its negation. `equals`: present with the
    /// literal's type and value (strings compared byte for byte, never by canonical equivalence).
    public func holds(_ predicate: SDUIPredicate) -> Bool {
        switch predicate {
        case .exists(let binding): return present(binding)
        case .missing(let binding): return !present(binding)
        case .equals(let binding, let literal):
            switch (self[binding], literal) {
            case (.string(let value)?, .string(let expected)): return value.utf8.elementsEqual(expected.utf8)
            case (.integer(let value)?, .integer(let expected)): return value == expected
            case (.bool(let value)?, .bool(let expected)): return value == expected
            default: return false
            }
        }
    }

    public func shows(_ predicate: SDUIPredicate?) -> Bool { predicate.map(holds) ?? true }

    private func present(_ binding: SDUIBinding) -> Bool {
        guard let value = self[binding] else { return false }
        if case .string(let text) = value { return !text.isEmpty }
        return true
    }

    /// This data with one form's current values under `form.<field id>`, replacing any other `form.*` entries.
    public func with(form fields: [String: SDUIFieldValue]) -> SDUIData {
        var merged = values.filter { !$0.key.hasPrefix("form.") }
        for (id, value) in fields { merged["form." + id] = value.data }
        return SDUIData(merged)
    }
}
