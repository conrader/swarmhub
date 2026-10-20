import Foundation

/// What the app shows for one view (P7b). Never part of a document.
public enum SDUIPresentation: Equatable, Sendable {
    /// The compiled view the app ships today: no bundle, no document, a decoder fallback, a kill switch, or a
    /// document that does not fit the target.
    case compiled(reason: String)
    /// The compiled "update required" view: a `critical` document this build cannot decode.
    case updateRequired(reason: String)
    case document(SDUIDocument)
}

/// The view documents of the current verified bundle, with the kill switch and the compiled URL allowlist. Reads
/// only what is already on disk and never fetches, so with no bundle (or an unreachable host) every view is
/// compiled, exactly as before P7b.
///
/// Bundle layout: a `ui` component (class `data`) carries one document per view as `<view>.json` at the archive
/// root; other files are ignored. A view found in two components is compiled. Like `ConfigStore`, a snapshot is
/// all-or-nothing: an unreadable store, a stored component that no longer matches its record or fails the archive
/// rules, or a config snapshot from another bundle (its kill flags would not apply) makes every view compiled.
public struct SDUIViewSource: Sendable {
    public let policy: SDUIPolicy
    /// The bundle the documents come from; nil when there are none.
    public let bundleVersion: Int64?
    let documents: [String: Data]
    let isViewKilled: @Sendable (String) -> Bool

    /// No documents: every view is compiled. The app's default.
    public static let compiledOnly = SDUIViewSource(documents: [:], policy: SDUIPolicy())

    public init(documents: [String: Data], policy: SDUIPolicy, bundleVersion: Int64? = nil,
                isViewKilled: @escaping @Sendable (String) -> Bool = { _ in false }) {
        self.documents = documents
        self.policy = policy
        self.bundleVersion = documents.isEmpty ? nil : bundleVersion
        self.isViewKilled = isViewKilled
    }

    /// Pin the current bundle once and read its `ui` components against that record. `config` must be the snapshot
    /// of the same bundle; its `kill.view.<type>` flags apply to every view and component type.
    public init(updates: UpdateStore, config: ConfigStore, policy: SDUIPolicy) {
        var found: [String: [Data]] = [:]
        var version: Int64? = nil
        do {
            if let bundle = try updates.pinnedBundle() {
                guard bundle.record.bundleVersion == config.bundleVersion else { throw ArchiveRules.Invalid(reason: "config_mismatch") }
                version = bundle.record.bundleVersion
                for component in bundle.record.components where component.kind == "ui" && component.contentClass == "data" {
                    guard let archive = bundle.component(component.name) else { throw ArchiveRules.Invalid(reason: "unreadable") }
                    let inspection = try ArchiveRules.check(archive, kind: "ui")
                    guard !inspection.needsCode else { throw ArchiveRules.Invalid(reason: "not_data") }
                    for (path, data) in try ArchiveRules.files(archive, kind: "ui")
                    where !path.contains("/") && path.hasSuffix(".json") && path.count > 5 {
                        found[String(path.dropLast(5)), default: []].append(data)
                    }
                }
            }
        } catch {
            found = [:]
            version = nil
        }
        self.init(documents: found.compactMapValues { $0.count == 1 ? $0[0] : nil }, policy: policy,
                  bundleVersion: version, isViewKilled: { config.isViewKilled($0) })
    }

    public var hasDocuments: Bool { !documents.isEmpty }

    /// Kill switch first (nothing is read), then the document, then the decoder's verdict (SCHEMAS.md §13).
    public func presentation(for view: String) -> SDUIPresentation {
        if isViewKilled(view) { return .compiled(reason: "killed") }
        guard let data = documents[view] else { return .compiled(reason: "no_document") }
        switch SDUIDecoder.decode(data, view: view, policy: policy, isViewKilled: isViewKilled) {
        case .render(let document): return .document(document)
        case .fallback(let reason): return .compiled(reason: reason)
        case .updateRequired(let reason): return .updateRequired(reason: reason)
        }
    }
}

/// The first P7b targets: routine result cards and the routine create and edit forms. A document for these views is
/// shown only when it fits what the existing app code can do with it; otherwise the compiled view is shown.
public enum SDUIRoutineTarget {
    public static let resultCardView = "routine_result_card"
    /// Edit an existing routine; its form submits `routine.save` bound to that routine's id.
    public static let editFormView = "routine_form"
    /// Create a routine; its form submits `routine.create`.
    public static let createFormView = "routine_create_form"
    /// The fields the existing create and save paths take, and the kinds that can carry each.
    public static let fieldKinds: [String: Set<SDUIFieldKind>] = ["name": [.text], "schedule": [.schedule, .text],
                                                                  "prompt": [.multiline, .text]]
    /// Limits of the compiled editor (`api_server.py` `_MAX_NAME_LENGTH`, `_MAX_PROMPT_LENGTH`).
    public static let maxName = 200
    public static let maxPrompt = 5000

    public static func resultCard(_ source: SDUIViewSource) -> SDUIPresentation {
        let presentation = source.presentation(for: resultCardView)
        if case .document(let document) = presentation, !forms(document.root).isEmpty { return .compiled(reason: "form_in_card") }
        return presentation
    }

    /// `routineID` nil: the create form.
    public static func editor(_ source: SDUIViewSource, routineID: String?, data: SDUIData) -> SDUIPresentation {
        let presentation = source.presentation(for: routineID == nil ? createFormView : editFormView)
        if case .document(let document) = presentation, let problem = formProblem(document, routineID: routineID, data: data) {
            return .compiled(reason: problem)
        }
        return presentation
    }

    /// nil when the document has exactly one form, every field is one the routine paths take (name and schedule
    /// required), and the submit is `routine.create` for a new routine or `routine.save` bound to this routine.
    public static func formProblem(_ document: SDUIDocument, routineID: String?, data: SDUIData) -> String? {
        let found = forms(document.root)
        guard found.count == 1, case .form(_, let fields, let submit) = found[0].component else { return "form_count" }
        for field in fields {
            guard fieldKinds[field.id]?.contains(field.kind) == true else { return "field_unsupported" }
        }
        guard fields.contains(where: { $0.id == "name" }), fields.contains(where: { $0.id == "schedule" }) else {
            return "field_missing"
        }
        switch (routineID, submit.action.command) {
        case (nil, .routineCreate):
            return nil
        case (let id?, .routineSave):
            guard case .routine(let binding)? = submit.action.argument, let bound = data[binding],
                  bound.text.utf8.elementsEqual(id.utf8) else { return "routine_mismatch" }
            return nil
        default:
            return "submit_mismatch"
        }
    }

    /// Name and schedule trimmed, the prompt as entered; nil when the compiled editor would not save it either.
    public static func draft(_ values: [String: SDUIFieldValue]) -> SDUIRoutineDraft? {
        let name = (values["name"]?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let schedule = (values["schedule"]?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = values["prompt"]?.text
        guard !name.isEmpty, name.count <= maxName, !schedule.isEmpty, (prompt?.count ?? 0) <= maxPrompt else { return nil }
        return SDUIRoutineDraft(name: name, schedule: schedule, prompt: prompt)
    }

    static func forms(_ node: SDUINode) -> [SDUINode] {
        switch node.component {
        case .form: return [node]
        case .list(let children, _), .card(_, _, let children): return children.flatMap(forms)
        case .flow(let steps): return steps.flatMap { $0.children.flatMap(forms) }
        default: return []
        }
    }
}
