import Foundation
import Testing
@testable import AgentApp

private let installedAppURL = URL(fileURLWithPath: "/Applications/SwarmHub.app")
private var updateInfo: [String: Any] {
    ["SUFeedURL": "https://github.com/conrader/swarmhub/releases/latest/download/appcast.xml",
     "SUPublicEDKey": Data(repeating: 7, count: 32).base64EncodedString()]
}

@Test func updatesRequireAnInstalledBundleAndAValidSigningConfiguration() {
    func reason(_ info: [String: Any]) -> String? {
        UpdateConfiguration.unavailableReason(bundleURL: installedAppURL, info: info, environment: [:])
    }
    #expect(reason(updateInfo) == nil)
    #expect(UpdateConfiguration.unavailableReason(bundleURL: URL(fileURLWithPath: "/tmp/.build/debug"), info: updateInfo, environment: [:]) != nil)
    var info = updateInfo
    info.removeValue(forKey: "SUPublicEDKey")
    #expect(reason(info) != nil)
    for key in ["", "not-base64", Data(repeating: 1, count: 31).base64EncodedString(), Data(repeating: 1, count: 64).base64EncodedString()] {
        info["SUPublicEDKey"] = key
        #expect(reason(info) != nil)
    }
    for feed in ["http://example.com/appcast.xml", "https:///appcast.xml", "file:///tmp/appcast.xml", "https://user:password@example.com/feed", "https://example.com/feed#fragment"] {
        info = updateInfo; info["SUFeedURL"] = feed
        #expect(reason(info) != nil)
    }
}

@Test func updatesDoNotRunDuringAutomation() {
    for environment in [["SWARMHUB_DISABLE_UPDATES": "1"], ["AGENTAPP_SNAPSHOT": "/tmp/test.png"],
                        ["AGENTAPP_HERMES_INTEGRATION": "1"], ["AGENTAPP_BENCHMARK": "1"],
                        ["XCTestConfigurationFilePath": "/tmp/tests.xctestconfiguration"]] {
        #expect(UpdateConfiguration.unavailableReason(bundleURL: installedAppURL, info: updateInfo, environment: environment) != nil)
    }
    #expect(UpdateConfiguration.unavailableReason(bundleURL: installedAppURL, info: updateInfo, environment: [:], arguments: ["AgentApp", "--ui-smoke", "/tmp/report.json"]) != nil)
    #expect(UpdateConfiguration.unavailableReason(bundleURL: installedAppURL, info: updateInfo, environment: ["AGENTAPP_APPEARANCE": "Dark"]) == nil)
}

@MainActor @Test func disabledUpdaterDoesNotOfferChecksOrChangePreferences() {
    let updater = AppUpdater(environment: ["SWARMHUB_DISABLE_UPDATES": "1"])
    #expect(updater.unavailableReason != nil && !updater.canCheckForUpdates)
    updater.checkForUpdates()
    updater.setAutomaticallyChecksForUpdates(true)
    updater.setAutomaticallyDownloadsUpdates(true)
    #expect(!updater.automaticallyChecksForUpdates && !updater.automaticallyDownloadsUpdates)
}
