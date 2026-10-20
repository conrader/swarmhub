import Foundation
@testable import SwarmHubCore

/// Shared SDUI fixtures (Tests/Fixtures/release-bundles/ui/, written by scripts/release/make_ui_vectors.py).
enum SDUIFixtures {
    // Also read by scripts/test_swift_ui_vectors.py.
    static let vectorFixture = "Tests/Fixtures/release-bundles/ui/vectors.json"
    static let fuzzFixture = "Tests/Fixtures/release-bundles/ui/fuzz.json"
    static var directory: URL {
        UpdateVerifierTests.repository.appendingPathComponent(vectorFixture).deletingLastPathComponent()
    }

    struct Catalog: Decodable {
        let reasons: [String]
        let cases: [Vector]
    }
    struct Vector: Decodable {
        let id: String
        let inputs: Inputs
        let expect: Expect
    }
    struct Inputs: Decodable {
        let document: String, view: String
        let killed: [String]
        let urlHosts: [String]
        let limits: [String: Int]
        enum CodingKeys: String, CodingKey {
            case document, view, killed, limits
            case urlHosts = "url_hosts"
        }
    }
    struct Expect: Decodable, Equatable {
        let verdict: String
        let reason: String?
    }
    struct Fuzz: Decodable {
        let seed: UInt64
        let iterations: Int
        let expected: [String]
    }

    static func catalog() throws -> Catalog {
        try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: UpdateVerifierTests.repository
            .appendingPathComponent(vectorFixture)))
    }
    static func fuzz() throws -> Fuzz {
        try JSONDecoder().decode(Fuzz.self, from: Data(contentsOf: UpdateVerifierTests.repository
            .appendingPathComponent(fuzzFixture)))
    }
    static func document(_ path: String) -> Data {
        (try? Data(contentsOf: directory.appendingPathComponent(path))) ?? Data()
    }

    static func policy(_ inputs: Inputs) -> SDUIPolicy {
        var limits = SDUILimits()
        limits.maxDocumentBytes = inputs.limits["max_document_bytes"] ?? -1
        limits.maxDepth = inputs.limits["max_depth"] ?? -1
        limits.maxNodes = inputs.limits["max_nodes"] ?? -1
        limits.maxChildren = inputs.limits["max_children"] ?? -1
        limits.maxStringBytes = inputs.limits["max_string_bytes"] ?? -1
        return SDUIPolicy(limits: limits, urlHosts: Set(inputs.urlHosts))
    }

    static func decode(_ data: Data, _ inputs: Inputs) -> SDUIOutcome {
        let killed = Set(inputs.killed)
        return SDUIDecoder.decode(data, view: inputs.view, policy: policy(inputs), isViewKilled: { killed.contains($0) })
    }

    static func label(_ outcome: SDUIOutcome) -> String {
        outcome.reason.map { outcome.verdict + "/" + $0 } ?? outcome.verdict
    }

    /// The decoded document written back as JSON. Equal canonical bytes with the input prove the decode kept every
    /// member, so a `render` outcome is never a partial document.
    static func canonical(_ document: SDUIDocument) -> Data? {
        var members: [String: JCS.Value] = ["schema": .string(SDUICatalog.schema), "view": .string(document.view),
                                            "root": node(document.root)]
        if let critical = document.critical { members["critical"] = .bool(critical) }
        return try? JCS.canonical(.object(members))
    }

    static func node(_ node: SDUINode) -> JCS.Value {
        var m: [String: JCS.Value] = ["type": .string(node.component.type.rawValue)]
        m["id"] = node.id.map { .string($0) }
        m["visible_if"] = node.visibleIf.map(predicate)
        switch node.component {
        case .text(let text, let style, let role):
            m["text"] = value(text)
            m["style"] = style.map { .string($0.rawValue) }
            m["role"] = role.map { .string($0.rawValue) }
        case .badge(let text, let tone):
            m["text"] = value(text)
            m["tone"] = tone.map { .string($0.rawValue) }
        case .keyValue(let items):
            m["items"] = .array(items.map { .object(["key": value($0.key), "value": value($0.value)]) })
        case .list(let children, let style):
            m["children"] = .array(children.map(self.node))
            m["style"] = style.map { .string($0.rawValue) }
        case .card(let title, let subtitle, let children):
            m["title"] = title.map(value)
            m["subtitle"] = subtitle.map(value)
            m["children"] = .array(children.map(self.node))
        case .form(let title, let fields, let submit):
            m["title"] = title.map(value)
            m["fields"] = .array(fields.map(field))
            m["submit"] = .object(["label": value(submit.label), "action": action(submit.action)])
        case .button(let label, let action, let style):
            m["label"] = value(label)
            m["action"] = self.action(action)
            m["style"] = style.map { .string($0.rawValue) }
        case .flow(let steps):
            m["steps"] = .array(steps.map {
                .object(["id": .string($0.id), "title": value($0.title), "children": .array($0.children.map(self.node))])
            })
        case .progress(let total, let amount, let label):
            m["total"] = total.map { .integer($0) }
            switch amount {
            case .fixed(let number)?: m["value"] = .integer(number)
            case .binding(let binding)?: m["value"] = bind(binding)
            case nil: break
            }
            m["label"] = label.map(value)
        case .diffPreview(let text, let title, let maxLines):
            m["text"] = value(text)
            m["title"] = title.map(value)
            m["max_lines"] = maxLines.map { .integer($0) }
        }
        return .object(m)
    }

    static func bind(_ binding: SDUIBinding) -> JCS.Value { .object(["bind": .string(binding.path)]) }

    static func value(_ text: SDUIText) -> JCS.Value {
        switch text {
        case .literal(let literal): return .string(literal)
        case .binding(let binding): return bind(binding)
        }
    }

    static func predicate(_ predicate: SDUIPredicate) -> JCS.Value {
        switch predicate {
        case .exists(let binding): return .object(["exists": bind(binding)])
        case .missing(let binding): return .object(["missing": bind(binding)])
        case .equals(let binding, let literal):
            let operand: JCS.Value
            switch literal {
            case .string(let text): operand = .string(text)
            case .integer(let number): operand = .integer(number)
            case .bool(let flag): operand = .bool(flag)
            }
            return .object(["equals": .object(["bind": .string(binding.path), "value": operand])])
        }
    }

    static func action(_ action: SDUIAction) -> JCS.Value {
        var m: [String: JCS.Value] = ["command": .string(action.command.rawValue)]
        m["confirm"] = action.confirm.map { .bool($0) }
        switch action.argument {
        case .text(let text)?: m["text"] = value(text)
        case .url(let url)?: m["url"] = .string(url)
        case .screen(let screen)?: m["screen"] = .string(screen.rawValue)
        case .routine(let binding)?: m["routine"] = bind(binding)
        case nil: break
        }
        return .object(m)
    }

    static func field(_ field: SDUIField) -> JCS.Value {
        var m: [String: JCS.Value] = ["id": .string(field.id), "kind": .string(field.kind.rawValue), "label": value(field.label)]
        m["required"] = field.required.map { .bool($0) }
        m["placeholder"] = field.placeholder.map { .string($0) }
        if let options = field.options {
            m["options"] = .array(options.map { option -> JCS.Value in
                .object(["value": .string(option.value), "label": value(option.label)])
            })
        }
        m["max_length"] = field.maxLength.map { .integer($0) }
        m["types"] = field.types.map { .array($0.map { .string($0) }) }
        m["value"] = field.value.map(bind)
        m["visible_if"] = field.visibleIf.map(predicate)
        return .object(m)
    }
}
