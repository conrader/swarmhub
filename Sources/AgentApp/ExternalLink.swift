import AppKit

/// The app's only way to open something outside itself: a page in the browser, a file in Finder, another app. In a test
/// run nothing is opened; the call is reported to the test bundle's sentinel as production access, so a test that would
/// put a browser tab on the screen fails instead. `probe` is the guard test's marker: its deliberate call is only logged.
@MainActor enum ExternalLink {
    /// System Settings → Privacy & Security → Microphone (dictation, P55's live voice microphone error).
    static let microphoneSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!

    @discardableResult static func open(_ url: URL, probe: String? = nil) -> Bool {
        if TestRunGuard.refuses("open \(url.absoluteString)", probe: probe) { return false }
        return NSWorkspace.shared.open(url)
    }

    static func openApplication(at url: URL, probe: String? = nil) {
        if TestRunGuard.refuses("open app \(url.path)", probe: probe) { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
