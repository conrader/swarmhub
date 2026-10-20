import Foundation
import Testing
@testable import SwarmHubCore

/// The four P7b wiring cases for the routine targets: no bundle or document → compiled; decoder fallback →
/// compiled; `update_required` → the compiled update-required view; `kill.view.<type>` → compiled.
struct SDUIViewSourceTests {
    static let views = [SDUIRoutineTarget.resultCardView, SDUIRoutineTarget.editFormView, SDUIRoutineTarget.createFormView]
    let data = SDUIData(["routine.id": .string("job-42"), "routine.name": .string("Morning report")])

    func source(_ documents: [String: Data], killed: Set<String> = []) -> SDUIViewSource {
        SDUIViewSource(documents: documents, policy: SDUIPolicy(), bundleVersion: 12, isViewKilled: { killed.contains($0) })
    }

    var targets: [String: Data] {
        [SDUIRoutineTarget.resultCardView: SDUIRenderFixtures.target("routine-result-card"),
         SDUIRoutineTarget.editFormView: SDUIRenderFixtures.target("routine-edit-form"),
         SDUIRoutineTarget.createFormView: SDUIRenderFixtures.target("routine-create-form")]
    }

    func presentations(_ source: SDUIViewSource) -> [SDUIPresentation] {
        [SDUIRoutineTarget.resultCard(source), SDUIRoutineTarget.editor(source, routineID: "job-42", data: data),
         SDUIRoutineTarget.editor(source, routineID: nil, data: data)]
    }

    func isDocument(_ presentation: SDUIPresentation) -> Bool {
        if case .document = presentation { return true }
        return false
    }

    @Test func noBundleOrNoDocumentIsCompiled() {
        for presentation in presentations(.compiledOnly) { #expect(presentation == .compiled(reason: "no_document")) }
        #expect(SDUIViewSource.compiledOnly.bundleVersion == nil)
        #expect(!SDUIViewSource.compiledOnly.hasDocuments)
        // A bundle with only other views changes nothing here.
        let other = source(["settings_pane": SDUIRenderFixtures.target("routine-result-card")])
        for presentation in presentations(other) { #expect(presentation == .compiled(reason: "no_document")) }
    }

    @Test func targetDocumentsRender() {
        for presentation in presentations(source(targets)) { #expect(isDocument(presentation)) }
    }

    @Test func decoderFallbackIsCompiled() {
        let broken = Data(#"{"schema":"swarmhub/ui/1","view":"routine_form","root":{"type":"web_view"}}"#.utf8)
        #expect(source([SDUIRoutineTarget.editFormView: broken]).presentation(for: SDUIRoutineTarget.editFormView)
                == .compiled(reason: "unknown_component"))
        // The decoder's default policy has an empty URL allowlist: a card with open_url is compiled.
        let card = SDUIFixtures.document("documents/routine-card.json")
        #expect(SDUIRoutineTarget.resultCard(source([SDUIRoutineTarget.resultCardView: card])) == .compiled(reason: "url_not_allowed"))
        #expect(source([SDUIRoutineTarget.resultCardView: Data("{".utf8)]).presentation(for: SDUIRoutineTarget.resultCardView)
                == .compiled(reason: "invalid_json"))
    }

    @Test func criticalDocumentThisBuildCannotReadAsksForAnUpdate() {
        let future = Data(#"{"schema":"swarmhub/ui/2","critical":true,"view":"routine_result_card","root":{}}"#.utf8)
        #expect(SDUIRoutineTarget.resultCard(source([SDUIRoutineTarget.resultCardView: future]))
                == .updateRequired(reason: "unsupported_schema"))
        let form = Data(#"{"schema":"swarmhub/ui/1","critical":true,"view":"routine_form","root":{"type":"secret_entry"}}"#.utf8)
        #expect(SDUIRoutineTarget.editor(source([SDUIRoutineTarget.editFormView: form]), routineID: "job-42", data: data)
                == .updateRequired(reason: "denied_route"))
    }

    @Test func killSwitchIsCompiledEvenForCriticalDocuments() {
        for view in Self.views {
            let killed = source(targets, killed: [view])
            #expect(killed.presentation(for: view) == .compiled(reason: "killed"))
        }
        let future = Data(#"{"schema":"swarmhub/ui/2","critical":true,"view":"routine_result_card","root":{}}"#.utf8)
        #expect(SDUIRoutineTarget.resultCard(source([SDUIRoutineTarget.resultCardView: future], killed: ["routine_result_card"]))
                == .compiled(reason: "killed"))
        // A killed component type the document uses also selects the compiled view.
        for presentation in presentations(source(targets, killed: ["card"])) { #expect(presentation == .compiled(reason: "killed")) }
    }

    @Test func documentsThatDoNotFitTheRoutinePathsAreCompiled() {
        let golden = SDUIFixtures.document("documents/routine-form.json")
        // The shared golden has fields (box, enabled, start, attachment) the save path cannot carry.
        #expect(SDUIRoutineTarget.editor(source([SDUIRoutineTarget.editFormView: golden]), routineID: "job-42", data: data)
                == .compiled(reason: "field_unsupported"))
        let edit = targets[SDUIRoutineTarget.editFormView]!
        #expect(SDUIRoutineTarget.editor(source([SDUIRoutineTarget.editFormView: edit]), routineID: "job-7", data: data)
                == .compiled(reason: "routine_mismatch"))
        let swapped = String(decoding: edit, as: UTF8.self).replacingOccurrences(of: "\"routine_form\"", with: "\"routine_create_form\"")
        #expect(SDUIRoutineTarget.editor(source([SDUIRoutineTarget.createFormView: Data(swapped.utf8)]), routineID: nil, data: data)
                == .compiled(reason: "submit_mismatch"))
        let cardWithForm = String(decoding: targets[SDUIRoutineTarget.createFormView]!, as: UTF8.self)
            .replacingOccurrences(of: "\"routine_create_form\"", with: "\"routine_result_card\"")
        #expect(SDUIRoutineTarget.resultCard(source([SDUIRoutineTarget.resultCardView: Data(cardWithForm.utf8)]))
                == .compiled(reason: "form_in_card"))
    }

    // MARK: Read from a real UpdateStore + ConfigStore snapshot

    /// One ustar with regular 0644 files, as ConfigStoreSnapshotTests builds them.
    static func archive(_ files: [(String, Data)]) -> Data {
        var out = Data()
        for (name, body) in files {
            var header = [UInt8](repeating: 0, count: 512)
            func put(_ text: String, _ start: Int) { header.replaceSubrange(start..<start + text.utf8.count, with: text.utf8) }
            func octal(_ number: Int, _ width: Int) -> String {
                let digits = String(number, radix: 8)
                return String(repeating: "0", count: width - 1 - digits.count) + digits + "\0"
            }
            put(name, 0); put(octal(0o644, 8), 100); put(octal(body.count, 12), 124); put("        ", 148)
            header[156] = 48; put("ustar\0", 257); put("00", 263)
            put(octal(header.reduce(0) { $0 + Int($1) }, 7) + " ", 148)
            out += Data(header) + body + Data(repeating: 0, count: (512 - body.count % 512) % 512)
        }
        return out + Data(repeating: 0, count: 1024)
    }

    func store(ui: [(String, Data)]?, killedView: String?) throws -> UpdateStore {
        let store = UpdateFixtures.temporaryStore()
        var flags = Data(#"{"schema":"swarmhub/config-flags/1"}"#.utf8)
        if let killedView { flags = Data(#"{"schema":"swarmhub/config-flags/1","kill.view.\#(killedView)":true}"#.utf8) }
        var blobs = ["flags": Self.archive([("flags.json", flags)])]
        if let ui { blobs["views"] = Self.archive(ui) }
        let entries = blobs.keys.sorted().map { name in
            UpdateRecord.Component(name: name, kind: name == "views" ? "ui" : "config", contentClass: "data", version: "1.0.0",
                                   sha256: updateDigest(blobs[name]!), size: Int64(blobs[name]!.count))
        }
        let manifest = Data("TEST ui snapshot".utf8)
        let record = UpdateRecord(bundleVersion: 12, manifestSHA256: updateDigest(manifest), appliedAt: "2026-10-20T12:00:00Z",
                                  platform: "mac", components: entries)
        try store.commit(UpdateSnapshot(record: record, keys: Data(), index: Data(), manifest: manifest, blobs: blobs))
        return store
    }

    func installed(_ store: UpdateStore) -> SDUIViewSource {
        SDUIViewSource(updates: store, config: ConfigStore(updates: store, log: { _ in }), policy: SDUIPolicy())
    }

    @Test func installedBundleIsReadKilledAndAllOrNothing() throws {
        let files = [("routine_form.json", targets[SDUIRoutineTarget.editFormView]!),
                     ("routine_create_form.json", targets[SDUIRoutineTarget.createFormView]!),
                     ("routine_result_card.json", targets[SDUIRoutineTarget.resultCardView]!),
                     ("nested/routine_form.json", Data("not read".utf8))]
        let live = installed(try store(ui: files, killedView: nil))
        #expect(live.bundleVersion == 12)
        for presentation in presentations(live) { #expect(isDocument(presentation)) }
        let killed = installed(try store(ui: files, killedView: SDUIRoutineTarget.editFormView))
        #expect(SDUIRoutineTarget.editor(killed, routineID: "job-42", data: data) == .compiled(reason: "killed"))
        #expect(isDocument(SDUIRoutineTarget.resultCard(killed)))
        // No ui component, or an empty store: compiled, exactly as before P7b.
        for presentation in presentations(installed(try store(ui: nil, killedView: nil))) {
            #expect(presentation == .compiled(reason: "no_document"))
        }
        for presentation in presentations(installed(UpdateFixtures.temporaryStore())) {
            #expect(presentation == .compiled(reason: "no_document"))
        }
        // A ui archive holding a non-JSON file is code, not data: every view is compiled.
        let code = installed(try store(ui: files + [("helper.js", Data("x".utf8))], killedView: nil))
        #expect(!code.hasDocuments)
        // A config snapshot of another bundle cannot vouch for the kill flags.
        let otherConfig = ConfigStore(log: { _ in })
        let mismatched = SDUIViewSource(updates: try store(ui: files, killedView: nil), config: otherConfig, policy: SDUIPolicy())
        #expect(!mismatched.hasDocuments)
    }
}
