import Foundation

/// uxfix1: `errorMessage` keeps one meaning for every caller, but transient network trouble in it is never the modal
/// alert. The alert reads `modalErrorMessage`; the small bar at the bottom of the window reads `connectionNotice`.
extension AppStore {
    /// What the "Backend Error" alert may show: nil for transient network trouble (`TransientNetwork`).
    var modalErrorMessage: String? { errorMessage.flatMap { TransientNetwork.isTransient(text: $0) ? nil : $0 } }

    /// Transient network trouble that reached `errorMessage` after its retries: one line, never a modal.
    var connectionNotice: String? { errorMessage.flatMap { TransientNetwork.isTransient(text: $0) ? $0 : nil } }

    /// The box answered again (or the network came back): the connection line goes by itself. Other errors stay.
    func clearConnectionNotice() {
        if connectionNotice != nil { errorMessage = nil }
    }
}
