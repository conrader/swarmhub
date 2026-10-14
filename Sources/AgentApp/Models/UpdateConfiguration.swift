import Foundation

/// Bare executables, test runs and capture tools must never start Sparkle's scheduler or show update UI.
enum UpdateConfiguration {
    static func unavailableReason(bundleURL: URL, info: [String: Any], environment: [String: String], arguments: [String] = []) -> String? {
        if environment["SWARMHUB_DISABLE_UPDATES"] == "1" || environment["XCTestConfigurationFilePath"] != nil ||
            arguments.contains("--ui-smoke") || arguments.contains("--setup-preview") || environment.keys.contains(where: { $0.hasPrefix("AGENTAPP_") &&
                ($0.contains("SNAPSHOT") || $0.contains("SMOKE") || $0.contains("BENCHMARK") || $0.contains("INTEGRATION")) }) {
            return "Automatic updates are disabled for this run."
        }
        guard bundleURL.pathExtension == "app" else {
            return "Run the installed application to enable automatic updates."
        }
        guard let feed = info["SUFeedURL"] as? String,
              let url = URLComponents(string: feed), url.scheme == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.fragment == nil else {
            return "This build does not have a valid update feed."
        }
        guard let key = info["SUPublicEDKey"] as? String, Data(base64Encoded: key)?.count == 32 else {
            return "Automatic updates are not configured in this build."
        }
        return nil
    }
}
