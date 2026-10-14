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

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Grok Bot keeps its sign-in locked with a Keychain item called “Grok Bot Safe Storage”.")
            Text("When you press Continue, macOS shows its own window: “\(Self.name) wants to use your confidential information " +
                 "stored in “Grok Bot Safe Storage” in your keychain.” It may ask for your Mac login password.")
            Text("Choose **Allow**, not Always Allow.").font(.headline)
            Text("\(Self.name) then unlocks the sign-in in memory, lists your own history from api2.cursor.sh, and forgets the " +
                 "sign-in when this window closes.")
            Text("If you choose Deny, nothing is read; you can import the recent messages kept on this Mac instead.")
            Text("Chose Always Allow before? Undo it in Keychain Access: open “Grok Bot Safe Storage”, then Access Control, and " +
                 "remove \(Self.name).").font(.caption).foregroundStyle(.secondary)
            if coordinator.signInMayBeStale {
                Label("If the import says your sign-in expired, open Grok Bot once and choose Check again.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if coordinator.keychainBusy {
                Text("macOS is still waiting for an answer to an earlier Keychain request. Answer or close that window first.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }.font(.callout)
    }

    private var waiting: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Waiting for macOS… \(coordinator.elapsedSeconds) s").font(.headline)
            Text("Its window may be behind this one. Choose Allow, not Always Allow.").font(.callout)
            Text("Cancel stops waiting here; the macOS window stays until you answer or close it, and its answer is then ignored.")
                .font(.caption).foregroundStyle(.secondary)
        }
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
        }
    }

    @ViewBuilder private func outcome(_ error: GrokImportRunError) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(error.errorDescription ?? "Grok Bot's sign-in could not be used.", systemImage: "exclamationmark.triangle")
                .font(.headline)
            Text(advice(error)).font(.callout)
            if error == .keychainItemMissing || error == .signedOut { Button("Open Grok Bot") { GrokImportActions.openGrokBot() } }
        }
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
