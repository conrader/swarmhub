import Combine
import Foundation
import Sparkle
import Testing
@testable import AgentApp

private let installedAppURL = URL(fileURLWithPath: "/Applications/SwarmHub.app")
private var updateInfo: [String: Any] {
    ["CFBundleIdentifier": SingleInstallation.bundleID, "SUFeedURL": "https://github.com/conrader/swarmhub/releases/latest/download/appcast.xml",
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
    info = updateInfo; info["SUFeedURL"] = "http://127.0.0.1:8123/appcast.xml"
    #expect(reason(info) != nil)
    let devURL = URL(fileURLWithPath: "/tmp/SwarmHub Dev.app")
    info["CFBundleIdentifier"] = "com.konrad.agentapp.update-rehearsal"
    #expect(UpdateConfiguration.unavailableReason(bundleURL: devURL, info: info, environment: [:]) == nil)
    #expect(UpdateConfiguration.unavailableReason(bundleURL: devURL, info: updateInfo, environment: [:]) != nil)
    for feed in ["http://example.com/appcast.xml", "http://127.0.0.1/appcast.xml", "http://localhost:8123/appcast.xml", "http://127.0.0.1.example.com:8123/appcast.xml", "https:///appcast.xml", "file:///tmp/appcast.xml", "https://user:password@example.com/feed", "https://example.com/feed#fragment"] {
        info = updateInfo; info["SUFeedURL"] = feed
        #expect(reason(info) != nil)
    }
}

@Test func updatesDoNotRunDuringAutomation() {
    for environment in [["SWARMHUB_DISABLE_UPDATES": "1"], ["AGENTAPP_SNAPSHOT": "/tmp/test.png"],
                        ["AGENTAPP_BENCHMARK": "1"],
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

@MainActor @Test func aQueuedUpdateCheckExpiresAndCanBeRequestedAgain() async throws {
    let updater = AppUpdater(environment: ["SWARMHUB_DISABLE_UPDATES": "1"])
    let readiness = PassthroughSubject<Bool, Never>()
    var started = 0
    updater.queueManualCheck(readiness: readiness.eraseToAnyPublisher(), timeout: .milliseconds(30), isReady: { true }) { started += 1 }
    #expect(updater.manualCheckQueued && UpdateNotice.shared.manualCheckQueued)
    try await waitUntil(timeout: .seconds(3)) { !updater.manualCheckQueued }
    #expect(!UpdateNotice.shared.manualCheckQueued && updater.problem?.contains("stayed busy") == true)
    readiness.send(true)
    #expect(started == 0)

    updater.queueManualCheck(readiness: readiness.eraseToAnyPublisher(), isReady: { true }) { started += 1 }
    readiness.send(true)
    try await waitUntil(timeout: .seconds(3)) { started > 0 }
    #expect(started == 1 && !updater.manualCheckQueued && !UpdateNotice.shared.manualCheckQueued && updater.problem == nil)
}

@MainActor @Test func lastCheckStartsWithTheDateSparklePersisted() throws {
    let directory = temporaryStore().deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: directory) }
    let bundleURL = directory.appending(path: "Fixture.app")
    let contents = bundleURL.appending(path: "Contents")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    let defaults = IsolatedDefaults()
    let info = ["CFBundleIdentifier": defaults.domainName, "CFBundlePackageType": "APPL", "CFBundleVersion": "1"]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appending(path: "Info.plist"))
    let host = try #require(Bundle(url: bundleURL))
    let checked = Date(timeIntervalSince1970: 1_760_000_000)
    defaults.set(checked, forKey: "SULastCheckTime")

    let driver = SPUStandardUserDriver(hostBundle: host, delegate: nil)
    let sparkle = SPUUpdater(hostBundle: host, applicationBundle: host, userDriver: driver, delegate: nil)
    let updater = AppUpdater(environment: ["SWARMHUB_DISABLE_UPDATES": "1"])
    updater.observeSparkleUpdater(sparkle)
    #expect(updater.lastCheck == checked)
}

@Test func canonicalInstallationAndOlderCopiesAreComparedByVersionThenBuild() {
    #expect(SingleInstallation.isInstalled(installedAppURL))
    #expect(SingleInstallation.isInstalled(URL(fileURLWithPath: "/Applications/../Applications/SwarmHub.app")))
    #expect(!SingleInstallation.isInstalled(URL(fileURLWithPath: "/Volumes/SwarmHub/SwarmHub.app")))
    #expect(!SingleInstallation.isInstalled(URL(fileURLWithPath: "/Applications/Old SwarmHub.app")))
    let old = AppBuildInfo(version: "0.6.8", build: "999")
    let current = AppBuildInfo(version: "0.8.5", build: "39")
    #expect(SingleInstallation.isNewer(current, than: old))
    #expect(!SingleInstallation.isNewer(old, than: current))
    #expect(!SingleInstallation.isNewer(current, than: current))
    #expect(SingleInstallation.isNewer(AppBuildInfo(version: "0.8.5", build: "40"), than: current))
}
