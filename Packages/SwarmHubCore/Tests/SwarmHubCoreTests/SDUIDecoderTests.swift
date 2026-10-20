import Foundation
import Testing
@testable import SwarmHubCore

struct SDUIDecoderTests {
    /// Script, web and dynamic-loading entry points that must never appear in SwarmHubCore (CORE-PLAN.md §5.3).
    /// Also checked on Linux by scripts/test_swift_ui_vectors.py.
    static let forbidden = ["JavaScriptCore", "JSContext", "JSValue", "JSVirtualMachine", "WebKit", "WKWebView",
                            "dlopen", "dlsym", "NSClassFromString", "NSSelectorFromString", "objc_getClass",
                            "objc_lookUpClass", "objc_msgSend", "NSInvocation", "NSExpression", "NSPredicate",
                            "CFBundleLoadExecutable", "loadAndReturnError", "Bundle(path:", "Bundle(url:", "#selector",
                            "value(forKey", "@_dynamicReplacement"]

    @Test func everyGoldenDocument() throws {
        let catalog = try SDUIFixtures.catalog()
        #expect(catalog.cases.count >= 60)
        for vector in catalog.cases {
            let data = SDUIFixtures.document(vector.inputs.document)
            #expect(!data.isEmpty, "\(vector.id)")
            let outcome = SDUIFixtures.decode(data, vector.inputs)
            #expect(SDUIFixtures.Expect(verdict: outcome.verdict, reason: outcome.reason) == vector.expect, "\(vector.id)")
            if let reason = outcome.reason { #expect(catalog.reasons.contains(reason), "\(vector.id)") }
            if case .render(let document) = outcome {
                #expect(SDUIFixtures.canonical(document) == (try? JCS.canonical(JCS.parse(data))), "\(vector.id)")
            }
        }
    }

    func golden(_ id: String) throws -> SDUIFixtures.Vector {
        let cases = try SDUIFixtures.catalog().cases
        return try #require(cases.first(where: { $0.id == id }))
    }

    func actions(_ node: SDUINode) -> [SDUIAction] {
        switch node.component {
        case .button(_, let action, _): return [action]
        case .form(_, _, let submit): return [submit.action]
        case .list(let children, _), .card(_, _, let children): return children.flatMap(actions)
        case .flow(let steps): return steps.flatMap { $0.children.flatMap(actions) }
        default: return []
        }
    }

    @Test func urlActionsAlwaysRequireConfirmation() throws {
        for id in ["routine-card", "url-confirm-false"] {
            let vector = try golden(id)
            guard case .render(let document) = SDUIFixtures.decode(SDUIFixtures.document(vector.inputs.document),
                                                                    vector.inputs) else {
                Issue.record("\(id) did not render")
                continue
            }
            let urls = actions(document.root).filter { $0.command == .openURL }
            #expect(urls.count == 1, "\(id)")
            for action in urls {
                #expect(action.requiresConfirmation)
                #expect(action.url?.host() == "docs.swarmhub.test")
            }
        }
        let help = try golden("url-confirm-false")
        guard case .render(let document) = SDUIFixtures.decode(SDUIFixtures.document(help.inputs.document), help.inputs) else {
            Issue.record("url-confirm-false did not render")
            return
        }
        #expect(actions(document.root).first?.confirm == false)
    }

    @Test func defaultPolicyRefusesEveryURL() throws {
        let card = try golden("routine-card")
        let data = SDUIFixtures.document(card.inputs.document)
        #expect(SDUIDecoder.decode(data, view: card.inputs.view) == .fallback(reason: "url_not_allowed"))
    }

    @Test func killSwitchHookSelectsTheCompiledFallback() throws {
        let card = try golden("routine-card")
        let data = SDUIFixtures.document(card.inputs.document)
        let policy = SDUIFixtures.policy(card.inputs)
        var asked: [String] = []
        let rendered = SDUIDecoder.decode(data, view: "routine_result_card", policy: policy,
                                          isViewKilled: { asked.append($0); return false })
        guard case .render = rendered else {
            Issue.record("routine card did not render: \(rendered)")
            return
        }
        #expect(asked.first == "routine_result_card")
        #expect(Set(asked.dropFirst()) == (["card", "badge", "text", "key_value", "progress", "diff_preview", "list", "button"] as Set<String>))
        let badgeKilled = SDUIDecoder.decode(data, view: "routine_result_card", policy: policy,
                                             isViewKilled: { $0 == "badge" })
        #expect(badgeKilled == .fallback(reason: "killed"))
        // The requested view is checked before anything is read.
        let viewKilled = SDUIDecoder.decode(Data("not json".utf8), view: "routine_result_card", policy: policy,
                                            isViewKilled: { $0 == "routine_result_card" })
        #expect(viewKilled == .fallback(reason: "killed"))
    }

    @Test func criticalOnlyComesFromAParsedObject() {
        let policy = SDUIPolicy(urlHosts: ["docs.swarmhub.test"])
        let broken = Data(#"{"schema":"swarmhub/ui/9","critical":true,"view":"v","root":{"type":"text","text":"x"}}"#.utf8)
        #expect(SDUIDecoder.decode(broken, view: "v", policy: policy) == .updateRequired(reason: "unsupported_schema"))
        let truncated = broken.dropLast()
        #expect(SDUIDecoder.decode(Data(truncated), view: "v", policy: policy) == .fallback(reason: "invalid_json"))
        let numeric = Data(#"{"schema":"swarmhub/ui/9","critical":1,"view":"v","root":{}}"#.utf8)
        #expect(SDUIDecoder.decode(numeric, view: "v", policy: policy) == .fallback(reason: "unsupported_schema"))
    }

    @Test func catalogueCannotNameApprovalOrSecretSurfaces() {
        let names = SDUIComponentType.allCases.map(\.rawValue) + SDUICommand.allCases.map(\.rawValue)
            + SDUIScreen.allCases.map(\.rawValue) + SDUIFieldKind.allCases.map(\.rawValue)
        for name in names { #expect(!SDUICatalog.deniedSurface(name), "\(name)") }
        for name in ["operation_review", "secret_entry", "Operation-Review", "approvals", "approve", "device.enroll",
                     "keychain", "api_token", "password"] {
            #expect(SDUICatalog.deniedSurface(name), "\(name)")
        }
        for segment in ["api_key", "approval_state", "session_cookie", "pin", "device_id"] {
            #expect(SDUICatalog.deniedSegment(segment), "\(segment)")
        }
        for segment in ["name", "keyboard_layout", "summary", "steps_done"] {
            #expect(!SDUICatalog.deniedSegment(segment), "\(segment)")
        }
    }

    @Test func targetHasNoScriptOrDynamicLoadingSymbols() throws {
        let package = UpdateVerifierTests.repository.appendingPathComponent("Packages/SwarmHubCore")
        let sources = package.appendingPathComponent("Sources")
        let files = (FileManager.default.enumerator(atPath: sources.path)?.compactMap { $0 as? String } ?? [])
            .filter { $0.hasSuffix(".swift") }.map { sources.appendingPathComponent($0) }
        #expect(files.contains { $0.lastPathComponent == "SDUIDecoder.swift" })
        for file in files + [package.appendingPathComponent("Package.swift")] {
            let text = try String(contentsOf: file, encoding: .utf8)
            for symbol in Self.forbidden { #expect(!text.contains(symbol), "\(file.lastPathComponent): \(symbol)") }
        }
    }
}
