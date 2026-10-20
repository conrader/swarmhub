import Foundation

/// What a renderer shows for one view: the whole decoded document, or a compiled screen. Never part of a document.
public enum SDUIOutcome: Equatable, Sendable {
    case render(SDUIDocument)
    /// The compiled view the app ships today.
    case fallback(reason: String)
    /// A compiled "update required" screen, for a document marked `critical` that this app cannot decode.
    case updateRequired(reason: String)

    public var verdict: String {
        switch self {
        case .render: return "render"
        case .fallback: return "fallback"
        case .updateRequired: return "update_required"
        }
    }
    public var reason: String? {
        switch self {
        case .render: return nil
        case .fallback(let reason), .updateRequired(let reason): return reason
        }
    }
}

/// Strict decoder for catalogue v1 view documents (SCHEMAS.md §13). Treats every document as untrusted input, even a
/// signed one (CORE-PLAN.md §5.4). Pure: no I/O, no rendering, no dynamic code.
public enum SDUIDecoder {
    /// Decodes the document the app found for `view`.
    ///
    /// `isViewKilled` is the kill-switch hook for `kill.view.<type>` flags (P6a `ConfigStore.isViewKilled`). It is asked
    /// for the requested view before anything is read, and for every component type of a decoded document; a killed
    /// name always selects the compiled fallback, never "update required".
    public static func decode(_ data: Data, view: String, policy: SDUIPolicy = SDUIPolicy(),
                              isViewKilled: (String) -> Bool = { _ in false }) -> SDUIOutcome {
        if isViewKilled(view) { return .fallback(reason: "killed") }
        guard data.count <= policy.limits.maxDocumentBytes else { return .fallback(reason: "too_large") }
        guard let value = try? JCS.parse(data) else { return .fallback(reason: "invalid_json") }
        // Read only from a parsed object: a document that does not parse cannot ask for "update required".
        var critical = false
        if case .object(let top) = value, case .bool(true)? = top["critical"] { critical = true }
        var reader = SDUIReader(policy: policy)
        let document: SDUIDocument
        do {
            document = try reader.document(value, view: view)
        } catch {
            let reason = (error as? SDUIRefusal)?.reason ?? "schema_invalid"
            return critical ? .updateRequired(reason: reason) : .fallback(reason: reason)
        }
        if reader.types.contains(where: isViewKilled) { return .fallback(reason: "killed") }
        return .render(document)
    }
}

struct SDUIRefusal: Error {
    let reason: String
}

func sduiRequire(_ condition: Bool, _ reason: String = "schema_invalid") throws {
    if !condition { throw SDUIRefusal(reason: reason) }
}

/// One pass over one document. The first failing check decides; the order is the Python reference's order.
struct SDUIReader {
    let policy: SDUIPolicy
    var nodes = 0
    var types: Set<String> = []

    init(policy: SDUIPolicy) { self.policy = policy }

    var invalid: SDUIRefusal { SDUIRefusal(reason: "schema_invalid") }

    mutating func document(_ value: JCS.Value, view: String) throws -> SDUIDocument {
        let top = try object(value)
        guard case .string(let schema)? = top["schema"] else { throw invalid }
        try sduiRequire(schema.utf8.elementsEqual(SDUICatalog.schema.utf8), "unsupported_schema")
        let keys = Set(top.keys)
        try sduiRequire(keys.isSubset(of: ["schema", "view", "critical", "root"]) && keys.isSuperset(of: ["view", "root"]))
        var critical: Bool? = nil
        if let value = top["critical"] { critical = try boolean(value) }
        guard case .string(let name)? = top["view"], matches(name, SDUICatalog.namePattern) else { throw invalid }
        try sduiRequire(!SDUICatalog.deniedSurface(name), "denied_route")
        try sduiRequire(name.utf8.elementsEqual(view.utf8), "view_mismatch")
        let root = try node(top["root"], depth: 1, inFlow: false)
        return SDUIDocument(view: name, critical: critical, root: root)
    }

    mutating func node(_ value: JCS.Value?, depth: Int, inFlow: Bool) throws -> SDUINode {
        let m = try object(value)
        try sduiRequire(depth <= policy.limits.maxDepth, "too_deep")
        nodes += 1
        try sduiRequire(nodes <= policy.limits.maxNodes, "too_many_nodes")
        guard case .string(let typeName)? = m["type"] else { throw invalid }
        try sduiRequire(!SDUICatalog.deniedSurface(typeName), "denied_route")
        guard let type = SDUIComponentType(rawValue: typeName) else { throw SDUIRefusal(reason: "unknown_component") }
        let (required, optional) = type.members
        let keys = Set(m.keys)
        try sduiRequire(keys.isSubset(of: SDUICatalog.commonMembers.union(required).union(optional))
                        && keys.isSuperset(of: required))
        types.insert(type.rawValue)
        var id: String? = nil
        if let value = m["id"] { id = try name(value) }
        var visibleIf: SDUIPredicate? = nil
        if let value = m["visible_if"] { visibleIf = try predicate(value) }
        let component: SDUIComponent
        switch type {
        case .text:
            let text = try self.text(m["text"])
            let style = try choice(m["style"], SDUITextStyle.self)
            let role = try choice(m["role"], SDUITextRole.self)
            if style == .markdown, case .literal(let literal) = text { try markup(literal) }
            component = .text(text, style: style, role: role)
        case .badge:
            let text = try self.text(m["text"])
            component = .badge(text, tone: try choice(m["tone"], SDUITone.self))
        case .keyValue:
            var pairs: [SDUIKeyValueItem] = []
            for item in try items(m["items"], nonempty: true) {
                let pair = try object(item)
                try sduiRequire(Set(pair.keys) == ["key", "value"])
                let key = try text(pair["key"])
                pairs.append(SDUIKeyValueItem(key: key, value: try text(pair["value"])))
            }
            component = .keyValue(pairs)
        case .list:
            let children = try self.children(m["children"], depth: depth, nonempty: true, inFlow: inFlow)
            component = .list(children, style: try choice(m["style"], SDUIListStyle.self))
        case .card:
            let title = try optionalText(m["title"])
            let subtitle = try optionalText(m["subtitle"])
            let children = try self.children(m["children"], depth: depth, nonempty: false, inFlow: inFlow)
            component = .card(title: title, subtitle: subtitle, children: children)
        case .form:
            let title = try optionalText(m["title"])
            var fields: [SDUIField] = []
            var seen: Set<String> = []
            for field in try items(m["fields"], nonempty: true) { fields.append(try self.field(field, seen: &seen)) }
            let submit = try object(m["submit"])
            try sduiRequire(Set(submit.keys) == ["label", "action"])
            let label = try text(submit["label"])
            let action = try self.action(submit["action"], submit: true, inFlow: inFlow)
            component = .form(title: title, fields: fields, submit: SDUISubmit(label: label, action: action))
        case .button:
            let label = try text(m["label"])
            let action = try self.action(m["action"], submit: false, inFlow: inFlow)
            component = .button(label: label, action: action, style: try choice(m["style"], SDUIButtonStyle.self))
        case .flow:
            try sduiRequire(!inFlow)
            var steps: [SDUIFlowStep] = []
            var seen: Set<String> = []
            for item in try items(m["steps"], nonempty: true) {
                let step = try object(item)
                try sduiRequire(Set(step.keys) == ["id", "title", "children"])
                guard case .string(let stepID)? = step["id"], matches(stepID, SDUICatalog.namePattern),
                      seen.insert(stepID).inserted else { throw invalid }
                let title = try text(step["title"])
                let children = try self.children(step["children"], depth: depth, nonempty: false, inFlow: true)
                steps.append(SDUIFlowStep(id: stepID, title: title, children: children))
            }
            component = .flow(steps: steps)
        case .progress:
            var total: Int64? = nil
            if let value = m["total"] { total = try integer(value, 1, SDUICatalog.maxTotal) }
            var amount: SDUIProgressValue? = nil
            if let value = m["value"] {
                if case .object = value {
                    amount = .binding(try bindingObject(value))
                } else {
                    amount = .fixed(try integer(value, 0, total ?? 100))
                }
            }
            component = .progress(total: total, value: amount, label: try optionalText(m["label"]))
        case .diffPreview:
            let text = try self.text(m["text"])
            let title = try optionalText(m["title"])
            var maxLines: Int64? = nil
            if let value = m["max_lines"] { maxLines = try integer(value, 1, SDUICatalog.maxLines) }
            component = .diffPreview(text, title: title, maxLines: maxLines)
        }
        return SDUINode(id: id, visibleIf: visibleIf, component: component)
    }

    /// An array of at most `maxChildren` items, checked before any item is read.
    func items(_ value: JCS.Value?, nonempty: Bool) throws -> [JCS.Value] {
        guard case .array(let items)? = value, !nonempty || !items.isEmpty else { throw invalid }
        try sduiRequire(items.count <= policy.limits.maxChildren, "too_many_children")
        return items
    }

    mutating func children(_ value: JCS.Value?, depth: Int, nonempty: Bool, inFlow: Bool) throws -> [SDUINode] {
        var result: [SDUINode] = []
        for child in try items(value, nonempty: nonempty) {
            result.append(try node(child, depth: depth + 1, inFlow: inFlow))
        }
        return result
    }

    func object(_ value: JCS.Value?) throws -> [String: JCS.Value] {
        guard case .object(let members)? = value else { throw invalid }
        return members
    }

    func boolean(_ value: JCS.Value?) throws -> Bool {
        guard case .bool(let flag)? = value else { throw invalid }
        return flag
    }

    func integer(_ value: JCS.Value?, _ low: Int64, _ high: Int64) throws -> Int64 {
        guard case .integer(let number)? = value, number >= low, number <= high else { throw invalid }
        return number
    }

    func name(_ value: JCS.Value?) throws -> String {
        guard case .string(let text)? = value, matches(text, SDUICatalog.namePattern) else { throw invalid }
        return text
    }

    /// Absent → nil; otherwise one of the enum's raw values.
    func choice<T: RawRepresentable>(_ value: JCS.Value?, _ type: T.Type) throws -> T? where T.RawValue == String {
        guard let value else { return nil }
        guard case .string(let text) = value, let result = T(rawValue: text) else { throw invalid }
        return result
    }
}
