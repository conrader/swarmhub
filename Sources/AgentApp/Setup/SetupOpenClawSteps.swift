import SwiftUI

/// S2: which software runs the agents (P25 D2). Hermes goes to the address step, OpenClaw to its connect screen.
struct SetupSoftwareStep: View {
    @Binding var flow: SetupFlow
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(SetupCopy.softwareTitle).font(.title2.bold())
            SetupCard(title: SetupCopy.hermesCardTitle, lines: [SetupCopy.hermesCardDetail], badge: nil) { flow.apply(.pick(.hermes)) }
            SetupCard(title: SetupCopy.openClawCardTitle, lines: [SetupCopy.openClawCardDetail], badge: nil) { flow.apply(.pick(.openClaw)) }
        }
    }
}

/// S3-OC: the OpenClaw address and key (P25 D3). The fields and help lines are the Settings sheet's own
/// (`OpenClawGatewayFields`, `OpenClawHelpLines`); Test saves the Gateway it connects through (D4).
struct SetupOpenClawStep: View {
    @Binding var flow: SetupFlow
    let testing: Bool
    let test: () -> Void

    static let labels = OpenClawFieldLabels(address: SetupCopy.openClawAddressLabel, key: SetupCopy.keyLabel, keyPrompt: SetupCopy.openClawKeyPrompt,
                                            plaintext: SetupCopy.openClawPlainToggle, deviceName: SetupCopy.openClawDeviceName,
                                            keepKey: SetupCopy.openClawKeepKey, more: SetupCopy.openClawMore)

    var body: some View {
        Form {
            Section {
                OpenClawGatewayFields(draft: $flow.openClaw, labels: Self.labels, submit: { if flow.openClaw.problem == nil, !testing { test() } })
                if let problem = flow.openClaw.problem { Text(problem).font(.caption).foregroundStyle(.orange) }
                Text(SetupCopy.openClawKeyCaption).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } header: { Text(SetupCopy.openClawTitle) }
            if flow.awaitsPairing, !testing {
                Section {
                    Text(SetupCopy.openClawPairing).foregroundStyle(.orange)
                    let command = GatewayState.approveCommand(flow.pairingRequestId)
                    HStack { Text(command).font(.callout.monospaced()).textSelection(.enabled); CopyButton(text: command) }
                }
            } else if let failure = flow.openClawFailure, !testing {
                Text(failure).foregroundStyle(.orange).textSelection(.enabled)
            }
            Section { OpenClawHelpLines(labels: [SetupCopy.openClawHelpKey, SetupCopy.openClawHelpTunnel, SetupCopy.openClawHelpApprove]) }
        }.formStyle(.grouped).scrollContentBackground(.hidden).padding(-20)
    }
}
