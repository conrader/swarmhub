import SwiftUI

/// S1 while Herdr is the only software offered: where Herdr runs. This Mac is first and is the default; a server is
/// reached over SSH (the app opens the connection) or by an address someone already forwarded; a ready-made server is
/// only announced (`ManagedHosting.isAvailable` is false: nothing can be ordered, sent or charged).
struct SetupHerdrWelcomeStep: View {
    let pick: (HerdrServer.Kind) -> Void
    let samples: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(SetupCopy.welcomeTitle).font(.title2.bold())
            Text(SetupCopy.herdrIntro).foregroundStyle(.secondary).padding(.bottom, 2)
            SetupCard(title: SetupCopy.herdrLocalTitle, lines: [SetupCopy.herdrLocalDetail], badge: nil) { pick(.local) }
            SetupCard(title: SetupCopy.herdrSSHTitle, lines: [SetupCopy.herdrSSHDetail], badge: nil) { pick(.ssh) }
            SetupCard(title: SetupCopy.herdrAddressTitle, lines: [SetupCopy.herdrAddressDetail], badge: nil) { pick(.address) }
            SetupCard(title: SetupCopy.herdrReadyMadeTitle, lines: [SetupCopy.herdrReadyMadeDetail], badge: ManagedHosting.badge) {}
                .disabled(!ManagedHosting.isAvailable).opacity(ManagedHosting.isAvailable ? 1 : 0.55)
            Button(SetupCopy.sampleLink, action: samples).buttonStyle(.link)
        }
    }
}

/// The Herdr screen: the fields for the way chosen on Welcome, and what Test said. On this Mac with no Herdr running
/// it says so and shows how to start one; the app does not install or start Herdr itself yet.
struct SetupHerdrStep: View {
    @Binding var flow: SetupFlow
    let testing: Bool
    let test: () -> Void

    /// The start script of the Herdr workspace checkout; shown verbatim.
    static let startCommand = "sh HerdrWorkspace/dev/start-local.sh"

    private var header: String {
        switch flow.herdr.kind { case .local: SetupCopy.herdrLocalHeader; case .ssh: SetupCopy.herdrSSHHeader; case .address: SetupCopy.herdrAddressHeader }
    }

    var body: some View {
        Form {
            Section {
                HerdrServerFields(draft: $flow.herdr, submit: { if flow.herdr.problem == nil, !testing { test() } })
            } header: { Text(header) }
            if testing {
                Section { HStack(spacing: 8) { ProgressView().controlSize(.small); Text(SetupCopy.testing).foregroundStyle(.secondary) } }
            } else if let port = flow.herdrNothingHere {
                Section {
                    Text(SetupCopy.herdrNothingHere(port: port)).foregroundStyle(.orange)
                    Text(SetupCopy.herdrStartHelp).font(.callout).fixedSize(horizontal: false, vertical: true)
                    HStack { Text(Self.startCommand).font(.callout.monospaced()).textSelection(.enabled); CopyButton(text: Self.startCommand) }
                    Text(SetupCopy.herdrStartLater).font(.caption).foregroundStyle(.secondary)
                }
            } else if let failure = flow.herdrFailure {
                Section { Text(failure).foregroundStyle(.orange).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            }
        }.formStyle(.grouped).scrollContentBackground(.hidden).padding(-20)
    }
}
