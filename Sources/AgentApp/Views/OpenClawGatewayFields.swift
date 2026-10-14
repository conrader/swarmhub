import SwiftUI

/// P25: what the Gateway sheet (Settings) and the setup window's OpenClaw step edit, pure. The key stays here only
/// until it is written once (Save in Settings, Test in the setup window).
struct OpenClawDraft: Equatable, Sendable {
    var name = "OpenClaw"
    var url = OpenClawCopy.tunnelURL
    var key = ""
    var deviceName = OpenClawGateway.defaultDeviceName
    var allowPrivatePlaintext = false
    var keepsKey = false

    init() {}
    init(_ gateway: OpenClawGateway) {
        name = gateway.name; url = gateway.url; deviceName = gateway.deviceName
        allowPrivatePlaintext = gateway.allowPrivatePlaintext; keepsKey = gateway.keepsToken
    }

    /// `GatewayURLRules.validate`'s refusal, shown inline; nil when the address can be used.
    var problem: String? {
        if case .failure(let problem) = GatewayURLRules.validate(url, allowPrivatePlaintext: allowPrivatePlaintext) { return problem.errorDescription }
        return nil
    }

    /// The entry to save (normalised address, trimmed names), keeping `existing`'s id; nil while the address is refused.
    func gateway(updating existing: OpenClawGateway?) -> OpenClawGateway? {
        guard case .success(let normalized) = GatewayURLRules.validate(url, allowPrivatePlaintext: allowPrivatePlaintext) else { return nil }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var gateway = existing ?? OpenClawGateway(name: trimmedName, url: normalized.absoluteString)
        gateway.name = trimmedName.isEmpty ? "OpenClaw" : trimmedName; gateway.url = normalized.absoluteString
        let device = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        gateway.deviceName = device.isEmpty ? OpenClawGateway.defaultDeviceName : device
        gateway.allowPrivatePlaintext = allowPrivatePlaintext; gateway.keepsToken = keepsKey
        return gateway
    }

    /// The key as typed, or nil when blank (Tailscale or proxy identity; on Edit, keep the stored one).
    var typedKey: String? { key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : key }
}

/// The labels each caller passes in: Settings keeps its technical words, the setup window uses `SetupCopy`.
struct OpenClawFieldLabels {
    let address: String, key: String, keyPrompt: String, plaintext: String, deviceName: String, keepKey: String
    /// Non-nil folds Device name and Keep-the-key under this title.
    var more: String?
}

/// Address, key, the plain-ws toggle, device name and keep-the-key: the fields both Gateway screens share.
struct OpenClawGatewayFields: View {
    @Binding var draft: OpenClawDraft
    let labels: OpenClawFieldLabels
    var submit: () -> Void = {}
    @State private var showMore = false

    var body: some View {
        TextField(labels.address, text: $draft.url, prompt: Text(OpenClawCopy.tunnelURL)).onSubmit(submit)
        SecureField(labels.key, text: $draft.key, prompt: Text(labels.keyPrompt)).onSubmit(submit)
        Toggle(labels.plaintext, isOn: $draft.allowPrivatePlaintext)
        if let more = labels.more {
            DisclosureGroup(more, isExpanded: $showMore) { identityFields }
        } else { identityFields }
    }

    @ViewBuilder private var identityFields: some View {
        TextField(labels.deviceName, text: $draft.deviceName)
        Toggle(labels.keepKey, isOn: $draft.keepsKey)
    }
}

/// The three help lines (the key, the tunnel, approving this Mac), each command verbatim in monospace with Copy.
struct OpenClawHelpLines: View {
    /// Three labels, in order: the key command, the tunnel, the approve commands.
    let labels: [String]
    static let commands = [OpenClawCopy.tokenCommand, OpenClawCopy.tunnelCommand, "\(OpenClawCopy.listCommand)  then  \(OpenClawCopy.approveCommand)"]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(zip(labels, Self.commands).enumerated()), id: \.offset) { _, line in
                VStack(alignment: .leading, spacing: 2) {
                    Text(line.0).font(.caption).foregroundStyle(.secondary)
                    HStack { Text(line.1).font(.caption.monospaced()).textSelection(.enabled); CopyButton(text: line.1) }
                }
            }
        }
    }
}
