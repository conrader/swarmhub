import AppKit
import SwiftUI

/// The fields of one Herdr server, by how it is reached. The setup window and Settings → Servers and keys share them.
struct HerdrServerFields: View {
    @Binding var draft: HerdrServerDraft
    var submit: () -> Void = {}

    var body: some View {
        switch draft.kind {
        case .local:
            SecureField(SetupCopy.herdrAccessKeyLabel, text: $draft.key, prompt: Text(SetupCopy.herdrLocalKeyPrompt)).onSubmit(submit)
            TextField(SetupCopy.herdrPortLabel, text: $draft.port).onSubmit(submit)
            Text(SetupCopy.herdrLocalCaption).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        case .ssh:
            TextField(SetupCopy.herdrServerLabel, text: $draft.sshHost, prompt: Text(SetupCopy.herdrServerPrompt)).onSubmit(submit)
            TextField(SetupCopy.herdrLoginLabel, text: $draft.sshUser, prompt: Text(SetupCopy.herdrOptional)).onSubmit(submit)
            HStack {
                TextField(SetupCopy.herdrKeyFileLabel, text: $draft.sshKeyPath, prompt: Text(SetupCopy.herdrKeyFilePrompt)).onSubmit(submit)
                Button(SetupCopy.herdrChoose, action: chooseKeyFile)
            }
            SecureField(SetupCopy.herdrAccessKeyLabel, text: $draft.key, prompt: Text(SetupCopy.herdrSSHKeyPrompt)).onSubmit(submit)
            TextField(SetupCopy.herdrPortLabel, text: $draft.port).onSubmit(submit)
            Text(SetupCopy.herdrSSHCaption).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        case .address:
            TextField(SetupCopy.herdrAddressLabel, text: $draft.address, prompt: Text(SetupCopy.herdrAddressPrompt)).onSubmit(submit)
            SecureField(SetupCopy.herdrAccessKeyLabel, text: $draft.key).onSubmit(submit)
            Text(SetupCopy.herdrAddressCaption).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        TextField(SetupCopy.herdrNameLabel, text: $draft.name, prompt: Text(SetupCopy.herdrOptional)).onSubmit(submit)
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
