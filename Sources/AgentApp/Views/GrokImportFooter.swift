import SwiftUI

/// The buttons for each step.
struct GrokImportFooter: View {
    @ObservedObject var coordinator: GrokImportCoordinator
    let close: () -> Void
    let useExportFolder: () -> Void

    var body: some View {
        HStack {
            if showsBack { Button("Back") { coordinator.back() } }
            Spacer()
            switch coordinator.step {
            case .idle, .scanning:
                Button("Cancel") { close() }.keyboardShortcut(.cancelAction)
            case .found:
                Button("Cancel") { close() }.keyboardShortcut(.cancelAction)
                Button(primaryTitle) { Task { await coordinator.proceed() } }.buttonStyle(.appleProminent)
                    .keyboardShortcut(.defaultAction).disabled(!coordinator.canProceed)
            case .permission:
                Button("Cancel") { close() }.keyboardShortcut(.cancelAction)
                Button("Continue") { coordinator.continueToMacOS() }.buttonStyle(.appleProminent).keyboardShortcut(.defaultAction).disabled(coordinator.keychainBusy)
            case .awaitingMacOS, .running:
                Button("Cancel") { coordinator.cancel() }.keyboardShortcut(.cancelAction)
            case .paused(let pause):
                Button("Cancel") { coordinator.cancel() }.keyboardShortcut(.cancelAction)
                Button(pause == .tokenExpired ? "Check again" : pause == .signInInvalid ? "Continue" : "Retry remaining") {
                    pause == .tokenExpired ? coordinator.checkAgain() : coordinator.retryRemaining()
                }.buttonStyle(.appleProminent).keyboardShortcut(.defaultAction).disabled(coordinator.keychainBusy && pause == .signInInvalid)
            case .failed(let error):
                if error.recentStillAvailable { Button("Recent messages only") { coordinator.recentOnly() } }
                if error.isSignInStep {
                    Button("Try again") { coordinator.continueToMacOS() }.disabled(coordinator.keychainBusy)
                }
                Button("Close") { close() }.buttonStyle(.appleProminent).keyboardShortcut(.cancelAction)
            case .cancelled:
                if coordinator.canImportWhatWasFetched { Button("Import what was fetched") { coordinator.importWhatWasFetched() } }
                Button("Done") { close() }.buttonStyle(.appleProminent).keyboardShortcut(.defaultAction)
            case .finished:
                if !coordinator.unfinishedIDs.isEmpty {
                    Button("Retry remaining (\(coordinator.unfinishedIDs.count))") { Task { await coordinator.retryUnfinished() } }
                }
                Button("Done") { close() }.buttonStyle(.appleProminent).keyboardShortcut(.defaultAction)
            }
        }
    }

    private var showsBack: Bool {
        switch coordinator.step {
        case .permission: true
        case .failed(let error): !error.isSignInStep
        default: false
        }
    }

    private var primaryTitle: String {
        let count = coordinator.selected.count
        return coordinator.mode == .full ? "Continue" : "Import \(count) \(count == 1 ? "chat" : "chats")"
    }
}
