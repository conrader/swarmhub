import SwiftUI

/// P12: Add/Edit an OpenClaw Gateway. The token is written to the Keychain once, on Save, never per keystroke; a blank
/// token field means Tailscale or proxy identity (on Edit it keeps the stored token).
struct OpenClawGatewaySheet: View {
    let existing: OpenClawGateway?
    let save: (OpenClawGateway, String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = "OpenClaw"
    @State private var url = OpenClawCopy.tunnelURL
    @State private var token = ""
    @State private var deviceName = OpenClawGateway.defaultDeviceName
    @State private var allowPrivatePlaintext = false
    @State private var keepsToken = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(existing == nil ? "Add OpenClaw Gateway" : "Edit \(existing?.name ?? "Gateway")").font(.headline)
            Form {
                TextField("Name", text: $name)
                TextField("Address", text: $url, prompt: Text(OpenClawCopy.tunnelURL))
                SecureField("Gateway token or password", text: $token, prompt: Text(existing == nil ? "Blank for Tailscale or proxy identity" : "Blank keeps the saved token"))
                TextField("Device name", text: $deviceName)
                Toggle("Allow plain ws:// on my private network", isOn: $allowPrivatePlaintext)
                Toggle("Keep the Gateway token after pairing", isOn: $keepsToken)
            }
            if let problem { Text(problem).font(.caption).foregroundStyle(.orange) }
            help
            Text(OpenClawCopy.privacy + " " + OpenClawCopy.warning).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { commit() }.keyboardShortcut(.defaultAction).disabled(problem != nil || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20).frame(width: 520)
        .onAppear(perform: load)
    }

    private var help: some View {
        VStack(alignment: .leading, spacing: 4) {
            helpLine("The token, on the Gateway host:", OpenClawCopy.tokenCommand)
            helpLine("A remote host: tunnel, then use \(OpenClawCopy.tunnelURL) (pairs with no approval step):", OpenClawCopy.tunnelCommand)
            helpLine("Otherwise approve this Mac on the Gateway host:", "\(OpenClawCopy.listCommand)  then  \(OpenClawCopy.approveCommand)")
        }
    }

    private func helpLine(_ label: String, _ command: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            HStack { Text(command).font(.caption.monospaced()).textSelection(.enabled); CopyButton(text: command) }
        }
    }

    private var problem: String? {
        if case .failure(let problem) = GatewayURLRules.validate(url, allowPrivatePlaintext: allowPrivatePlaintext) { return problem.errorDescription }
        return nil
    }

    private func load() {
        guard let existing else { return }
        name = existing.name; url = existing.url; deviceName = existing.deviceName
        allowPrivatePlaintext = existing.allowPrivatePlaintext; keepsToken = existing.keepsToken
    }

    private func commit() {
        guard case .success(let normalized) = GatewayURLRules.validate(url, allowPrivatePlaintext: allowPrivatePlaintext) else { return }
        var gateway = existing ?? OpenClawGateway(name: name, url: normalized.absoluteString)
        gateway.name = name.trimmingCharacters(in: .whitespacesAndNewlines); gateway.url = normalized.absoluteString
        let device = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        gateway.deviceName = device.isEmpty ? OpenClawGateway.defaultDeviceName : device
        gateway.allowPrivatePlaintext = allowPrivatePlaintext; gateway.keepsToken = keepsToken
        save(gateway, token.isEmpty ? nil : token)
        token = ""
        dismiss()
    }
}
