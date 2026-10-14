import SwiftUI

/// P12: Add/Edit an OpenClaw Gateway. The token is written to the Keychain once, on Save, never per keystroke; a blank
/// token field means Tailscale or proxy identity (on Edit it keeps the stored token). The fields and help lines are
/// shared with the setup window (`OpenClawGatewayFields`, P25).
struct OpenClawGatewaySheet: View {
    let existing: OpenClawGateway?
    let save: (OpenClawGateway, String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft = OpenClawDraft()

    static let helpLabels = ["The token, on the Gateway host:",
                             "A remote host: tunnel, then use \(OpenClawCopy.tunnelURL) (pairs with no approval step):",
                             "Otherwise approve this Mac on the Gateway host:"]

    private var labels: OpenClawFieldLabels {
        OpenClawFieldLabels(address: "Address", key: "Gateway token or password",
                            keyPrompt: existing == nil ? "Blank for Tailscale or proxy identity" : "Blank keeps the saved token",
                            plaintext: "Allow plain ws:// on my private network", deviceName: "Device name", keepKey: "Keep the Gateway token after pairing")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(existing == nil ? "Add OpenClaw Gateway" : "Edit \(existing?.name ?? "Gateway")").font(.headline)
            Form {
                TextField("Name", text: $draft.name)
                OpenClawGatewayFields(draft: $draft, labels: labels)
            }
            if let problem = draft.problem { Text(problem).font(.caption).foregroundStyle(.orange) }
            OpenClawHelpLines(labels: Self.helpLabels)
            Text(OpenClawCopy.privacy + " " + OpenClawCopy.warning).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { commit() }.keyboardShortcut(.defaultAction).disabled(draft.problem != nil || draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20).frame(width: 520)
        .onAppear { if let existing { draft = OpenClawDraft(existing) } }
    }

    private func commit() {
        guard let gateway = draft.gateway(updating: existing) else { return }
        save(gateway, draft.typedKey)
        draft.key = ""
        dismiss()
    }
}
