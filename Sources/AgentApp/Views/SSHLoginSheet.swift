import SwiftUI

struct SSHLoginSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AppStore
    let server: HerdrServer
    let fixedUser: Bool
    let connected: (HerdrServer) -> Void
    @State private var user: String
    @State private var password = ""
    @State private var error: String?
    @State private var attempt: Task<Void, Never>?
    @FocusState private var focus: Field?
    private enum Field { case user, password }

    init(server: HerdrServer, keepSavedLogin: Bool = false, connected: @escaping (HerdrServer) -> Void) {
        fixedUser = keepSavedLogin
        self.server = server
        self.connected = connected
        _user = State(initialValue: server.sshUser)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sign in to \(server.sshHost)").font(.title2.bold())
            if fixedUser { LabeledContent("Username", value: user.isEmpty ? "From SSH configuration" : user) }
            else { TextField("Username", text: $user).focused($focus, equals: .user) }
            SecureField("Password", text: $password).focused($focus, equals: .password)
            Text("SwarmHub remembers this password until you quit the app.").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.callout).foregroundStyle(.secondary) }
            HStack {
                Spacer()
                Button("Cancel") { attempt?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Button(attempt == nil ? "Sign In" : "Signing In…", action: signIn)
                    .keyboardShortcut(.defaultAction)
                    .disabled(attempt != nil || (!fixedUser && login.isEmpty) || !HerdrTunnel.isSafe(user: login) || password.isEmpty)
            }
        }
        .textFieldStyle(.roundedBorder).controlSize(.large).padding(24).frame(width: 380)
        .onAppear { focus = !fixedUser && user.isEmpty ? .user : .password }
        .onDisappear { attempt?.cancel(); password = "" }
    }

    private var login: String { user.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func signIn() {
        var target = server
        target.sshUser = login
        error = nil
        attempt = Task {
            do {
                try await store.herdrTunnels.signIn(to: target, password: password)
                guard !Task.isCancelled else { return }
                password = ""
                dismiss()
                connected(target)
            } catch {
                guard !Task.isCancelled else { return }
                self.error = HerdrTunnel.offersPassword(error) ? "The server declined that login. Check your username and password." : error.localizedDescription
                password = ""
                focus = .password
            }
            attempt = nil
        }
    }
}
