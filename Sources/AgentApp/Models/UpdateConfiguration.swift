import Foundation

/// Bare executables, test runs and capture tools must never start Sparkle's scheduler or show update UI.
enum UpdateConfiguration {
    /// A test run, a capture or a benchmark: nothing may look for updates by itself, neither for the app nor on a server.
    static func isAutomated(environment: [String: String], arguments: [String] = []) -> Bool {
        environment["SWARMHUB_DISABLE_UPDATES"] == "1" || environment["XCTestConfigurationFilePath"] != nil ||
            arguments.contains(SingleInstallation.launchCheckFlag) || arguments.contains("--agent-qa-window") || arguments.contains("--ui-smoke") || arguments.contains("--setup-preview") || environment.keys.contains(where: { $0.hasPrefix("AGENTAPP_") &&
                ($0.contains("SNAPSHOT") || $0.contains("SMOKE") || $0.contains("BENCHMARK")) })
    }

    static func unavailableReason(bundleURL: URL, info: [String: Any], environment: [String: String], arguments: [String] = []) -> String? {
        if isAutomated(environment: environment, arguments: arguments) {
            return "Automatic updates are disabled for this run."
        }
        let id = info["CFBundleIdentifier"] as? String
        let rehearsal = id == "com.konrad.agentapp.update-rehearsal" || id?.hasPrefix("com.konrad.agentapp.update-menu-test.") == true
        guard (id == SingleInstallation.bundleID && SingleInstallation.isInstalled(bundleURL)) ||
                (rehearsal && bundleURL.pathExtension == "app") else {
            return "Run the installed application to enable automatic updates."
        }
        // https, or plain http on this Mac's own loopback address: a rehearsal's local feed (`Tests/Scripts/update-rehearsal.sh`).
        // Release packaging refuses the second (`scripts/configure-updates.py`), and archives are signature-checked either way.
        guard let feed = info["SUFeedURL"] as? String,
              let url = URLComponents(string: feed), let host = url.host, !host.isEmpty,
              rehearsal ? (url.scheme == "http" && host == "127.0.0.1" && url.port != nil) : url.scheme == "https",
              url.user == nil, url.password == nil, url.fragment == nil else {
            return "This build does not have a valid update feed."
        }
        guard let key = info["SUPublicEDKey"] as? String, Data(base64Encoded: key)?.count == 32 else {
            return "Automatic updates are not configured in this build."
        }
        return nil
    }

    /// Why a check ended without an answer, for the line under the app's version; nil for the endings that are not
    /// problems (nothing newer was found, or the person closed the window). The codes are Sparkle's `SUError`.
    static func problem(from error: Error) -> String? {
        let failure = error as NSError
        let quiet = [1001 /* no update */, 4007 /* installation cancelled */, 4008 /* authorization cancelled */]
        if failure.domain == "SUSparkleErrorDomain", quiet.contains(failure.code) { return nil }
        return failure.localizedDescription
    }
}
