import SwiftUI

/// Permission (Full mode only): the only place the macOS dialog can start. Explains the Keychain item, the dialog and
/// the answer to give before Continue; then waits for macOS; then gives one action per outcome. Wording follows
/// docs/P10-spike-findings.md: the dialog names the app's display name and asks for the Mac login password.
struct GrokPermissionStep: View {
    @ObservedObject var coordinator: GrokImportCoordinator

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                switch coordinator.step {
                case .awaitingMacOS:
                    waiting
                case .paused(.tokenExpired):
                    expired
                case .failed(let error):
                    outcome(error)
                default:
                    explanation
                }
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private static let name = AppConstants.name

    /// Three numbered steps on one card; the rest is footnotes.
    private var explanation: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 14) {
                GrokNumberedStep(number: 1, title: "Press Continue.",
                                 detail: "macOS shows its own window: “\(Self.name) wants to use your confidential information stored in " +
                                     "“Grok Bot Safe Storage” in your keychain.” It may ask for your Mac login password.")
                GrokNumberedStep(number: 2, title: "Choose Allow, not Always Allow.",
                                 detail: "Allow covers this one import. Deny reads nothing; the recent messages kept on this Mac " +
                                     "can still be imported.")
                GrokNumberedStep(number: 3, title: "\(Self.name) imports, then forgets.",
                                 detail: "It unlocks Grok Bot's sign-in in memory, lists your own history from api2.cursor.sh, and " +
                                     "forgets the sign-in when this window closes.")
            }.grokCard(padding: 14)
            if coordinator.keychainBusy {
                GrokNotice(text: "macOS is still waiting for an answer to an earlier Keychain request. Answer or close that window first.",
                           symbol: "exclamationmark.triangle", tone: .caution)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Chose Always Allow before? Undo it in Keychain Access: open “Grok Bot Safe Storage”, then Access Control, and " +
                     "remove \(Self.name).")
                if coordinator.signInMayBeStale {
                    Text("If the import says your sign-in expired, open Grok Bot once and choose Check again.")
                }
            }.font(.caption).foregroundStyle(.secondary)
        }
    }

    private var waiting: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Waiting for macOS… \(coordinator.waitingSeconds) s", systemImage: "lock.shield").font(.headline)
            Text("Its window may be behind this one. Choose Allow, not Always Allow.").font(.callout)
            Text("Cancel stops waiting here; the macOS window stays until you answer or close it, and its answer is then ignored.")
                .font(.caption).foregroundStyle(.secondary)
        }.grokCard(padding: 14)
    }

    private var expired: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Grok Bot's sign-in has expired.", systemImage: "clock.badge.exclamationmark").font(.headline)
            Text("Open Grok Bot once (it renews the sign-in), then choose Check again. Nothing is asked again: the unlock key " +
                 "stays in memory for up to ten minutes.").font(.callout)
            HStack {
                Button("Open Grok Bot") { GrokImportActions.openGrokBot() }
                Button("Forget sign-in") { Task { await coordinator.forgetSignIn() } }.disabled(!coordinator.holdsSignIn)
            }
            if !coordinator.holdsSignIn {
                Text("The sign-in was forgotten: Check again will make macOS ask once more.").font(.caption).foregroundStyle(.secondary)
            }
        }.grokCard(padding: 14)
    }

    @ViewBuilder private func outcome(_ error: GrokImportRunError) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(error.errorDescription ?? "Grok Bot's sign-in could not be used.", systemImage: "exclamationmark.triangle")
                .font(.headline)
            Text(advice(error)).font(.callout)
            if error == .keychainItemMissing || error == .signedOut { Button("Open Grok Bot") { GrokImportActions.openGrokBot() } }
        }.grokCard(padding: 14)
    }

    private func advice(_ error: GrokImportRunError) -> String {
        switch error {
        case .keychain(.denied):
            "Nothing was read. Try again to see the macOS window once more, or import the recent messages kept on this Mac."
        case .keychain(.keychainLocked):
            "Unlock the login keychain (Keychain Access, or log out and in again), then Try again."
        case .keychainItemMissing, .signedOut:
            "Sign in to Grok Bot first, then open this window again; or import the recent messages kept on this Mac."
        case .keychainReadInFlight:
            "Answer or close the earlier macOS window, then Try again."
        default:
            "Recent messages from this Mac can still be imported."
        }
    }
}
