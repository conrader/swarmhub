import AppKit
import SwiftUI

/// The fields of one Herdr server, by how it is reached. The setup window and Settings → Servers and keys share them.
struct HerdrServerFields: View {
    /// Settings shows every field. The setup wizard shows what a person has to type (`main`) and folds the rest away
    /// (`details`): the access key that is read without typing, the port and the server's name in the app.
    enum Part { case all, main, details }
    @Binding var draft: HerdrServerDraft
    var part = Part.all
    var submit: () -> Void = {}

    /// Each field stands on its own, with what it is for above it and what to know about it beneath.
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch draft.kind {
            case .local:
                if part != .main {
                    StandaloneField(title: SetupCopy.herdrAccessKeyLabel, text: $draft.key, prompt: SetupCopy.herdrLocalKeyPrompt, secure: true, note: SetupCopy.herdrLocalCaption, submit: submit)
                    StandaloneField(title: SetupCopy.herdrPortLabel, text: $draft.port, submit: submit).frame(width: 140)
                }
            case .ssh:
                if part != .details {
                    StandaloneField(title: SetupCopy.herdrServerLabel, text: $draft.sshDestination, prompt: SetupCopy.herdrServerPrompt,
                                    note: part == .main && !draft.sshDestination.isEmpty ? draft.problem : nil, submit: submit)
                }
                if part != .main {
                    HStack(alignment: .bottom, spacing: 8) {
                        StandaloneField(title: SetupCopy.herdrKeyFileLabel, text: $draft.sshKeyPath, prompt: SetupCopy.herdrKeyFilePrompt, submit: submit)
                        Button(SetupCopy.herdrChoose, action: chooseKeyFile).controlSize(.large)
                    }
                    StandaloneField(title: SetupCopy.herdrAccessKeyLabel, text: $draft.key, prompt: SetupCopy.herdrSSHKeyPrompt, secure: true,
                                    note: SetupCopy.herdrSSHKeyCaption, submit: submit)
                    StandaloneField(title: SetupCopy.herdrPortLabel, text: $draft.port, submit: submit).frame(width: 140)
                }
            case .address:
                if part != .details {
                    StandaloneField(title: SetupCopy.herdrAddressLabel, text: $draft.address, prompt: SetupCopy.herdrAddressPrompt, submit: submit)
                    StandaloneField(title: SetupCopy.herdrAccessKeyLabel, text: $draft.key, secure: true, note: SetupCopy.herdrAddressCaption, submit: submit)
                }
            }
            if part != .main { StandaloneField(title: SetupCopy.herdrNameLabel, text: $draft.name, prompt: SetupCopy.herdrOptional, submit: submit) }
        }
    }

    /// Only the file's path is taken; the key itself is never opened or copied.
    private func chooseKeyFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false; panel.showsHiddenFiles = true
        // The person's own ~/.ssh, whatever folder a development launch calls home.
        panel.directoryURL = URL(fileURLWithPath: HerdrTunnel.realHome).appending(path: ".ssh")
        if panel.runModal() == .OK, let path = panel.url?.path { draft.sshKeyPath = path }
    }
}
