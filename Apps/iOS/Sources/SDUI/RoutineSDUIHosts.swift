import SwiftUI
import UIKit
import SwarmHubCore

/// P7c first targets, the same views as the Mac's (P7b): the routine result card and the routine create and edit
/// forms. Each host shows the compiled view it wraps, unchanged, unless the current bundle has a document for the view
/// that decodes and fits (`SDUIRoutineTarget`, shared with the Mac): no bundle, no document, a decoder fallback or a
/// `kill.view.*` flag → `compiled()`; a `critical` document this build cannot read → "update required".
///
/// The iOS build has no compiled routine card or editor yet (routines are Mac-only), so no screen mounts these hosts
/// today and a bundle cannot add a routine surface to iOS. A later compiled routine screen wraps its views here.
struct RoutineResultCardHost<Compiled: View>: View {
    @Environment(\.sduiViewSource) private var source
    /// `SDUIRoutineTarget.cardData`, the same binding paths as the Mac.
    let data: SDUIData
    let actions: SDUIActions
    @ViewBuilder let compiled: () -> Compiled

    var body: some View {
        switch SDUIRoutineTarget.resultCard(source) {
        case .compiled: compiled()
        case .updateRequired: SDUIUpdateRequiredView(inSheet: false)
        case .document(let document): SDUIDocumentView(document: document, data: data, actions: actions)
        }
    }
}

struct RoutineEditorHost<Compiled: View>: View {
    @Environment(\.sduiViewSource) private var source
    /// nil: the create form.
    let routineID: String?
    /// `SDUIRoutineTarget.editorData`.
    let data: SDUIData
    let actions: SDUIActions
    @ViewBuilder let compiled: () -> Compiled

    var body: some View {
        switch SDUIRoutineTarget.editor(source, routineID: routineID, data: data) {
        case .compiled: compiled()
        case .updateRequired: SDUIUpdateRequiredView(inSheet: true)
        case .document(let document):
            ScrollView { SDUIDocumentView(document: document, data: data, actions: actions).padding(20) }
                .transaction { $0.animation = nil }
        }
    }
}

/// The compiled "update required" view (CORE-PLAN.md §5.4).
struct SDUIUpdateRequiredView: View {
    @Environment(\.dismiss) private var dismiss
    let inSheet: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label { Text(verbatim: "Update required") } icon: { Image(systemName: "arrow.down.circle") }.font(.headline)
            Text(verbatim: "This view needs a newer version of SwarmHub. Install the latest version from the App Store to see it.")
                .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if inSheet { HStack { Spacer(); Button { dismiss() } label: { Text(verbatim: "Done") }.buttonStyle(.borderedProminent) } }
        }.padding(inSheet ? 20 : 14).frame(maxWidth: .infinity, alignment: .leading)
            .background(inSheet ? Color.clear : Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// The iOS side of `SDUIAppCommand`: existing iOS code paths only. iOS has no routine paths (Hermes `/api/jobs` is
/// used only by the Mac) and no screen navigation hook, so those commands are not offered and their buttons stay
/// disabled; the router's confirmations and refusals are the shared ones either way.
@MainActor struct SDUIiOSCommands {
    /// Present in a sheet; nil inline.
    let dismiss: (@MainActor () -> Void)?

    func actions(_ policy: SDUIPolicy) -> SDUIActions {
        SDUIActions(router: SDUIActionRouter(urlHosts: policy.urlHosts), isAvailable: { isAvailable($0) },
                    perform: { await perform($0) })
    }

    func isAvailable(_ command: SDUIAppCommand) -> Bool {
        switch command {
        case .dismiss: return dismiss != nil
        case .copyText, .openURL: return true
        case .refresh, .navigate, .routineOpen, .routineRunNow, .routinePause, .routineResume, .routineCreate, .routineSave:
            return false
        }
    }

    func perform(_ command: SDUIAppCommand) async -> String? {
        guard isAvailable(command) else { return nil }
        switch command {
        case .dismiss: dismiss?()
        case .copyText(let text): UIPasteboard.general.string = text
        case .openURL(let url): _ = await UIApplication.shared.open(url)
        case .refresh, .navigate, .routineOpen, .routineRunNow, .routinePause, .routineResume, .routineCreate, .routineSave:
            break
        }
        return nil
    }
}
