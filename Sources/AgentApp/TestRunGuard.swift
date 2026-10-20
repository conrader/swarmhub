import Foundation

/// What the test bundle's sentinel (`AgentAppTestRunSentinel`) answers: each call fails the running test.
@objc protocol TestRunSentinel {
    /// A request to a host other than 127.0.0.1, localhost or ::1 reached the guard. `probe` is the guard test's marker.
    static func outsideRequest(_ url: String, probe: String?)
    /// A call to the real Keychain, to production state (store.json, the standard defaults), or an open of a page, file or
    /// app (`ExternalLink`), in a test run. `probe` is the guard test's marker.
    static func productionAccess(_ what: String, probe: String?)
}

/// P28: a test run never touches the network beyond loopback, the real Keychain or the app's own store and settings.
/// Every URLSession the app builds goes through `guarded(_:)`, which in a test run puts `OutsideRequestGuard` in front of
/// the system HTTP stack; the live Keychain calls ask `refuses(_:)` first. Both report to the test bundle's sentinel,
/// looked up by its Objective-C name so the app carries no test code. Outside a test run nothing changes.
enum TestRunGuard {
    static let isTestRun: Bool = {
        let environment = ProcessInfo.processInfo.environment
        let running = environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil || environment["XCTestSessionIdentifier"] != nil
            || NSClassFromString("XCTestCase") != nil || ["xctest", "swiftpm-testing-helper"].contains(ProcessInfo.processInfo.processName)
        // `URLSession.shared` and any session built without `guarded(_:)` see registered classes too.
        if running { URLProtocol.registerClass(OutsideRequestGuard.self) }
        return running
    }()

    /// Header the guard test sets, so its deliberate request is logged instead of failing the run.
    static let probeHeader = "X-Test-Guard-Probe"

    private static var sentinel: TestRunSentinel.Type? { NSClassFromString("AgentAppTestRunSentinel") as? TestRunSentinel.Type }

    /// `configuration` with the outside-request guard first in a test run.
    static func guarded(_ configuration: URLSessionConfiguration) -> URLSessionConfiguration {
        #if DEBUG
        if UIAcceptanceMode.requested {
            configuration.protocolClasses = [UIAcceptanceRequestGuard.self]
            configuration.urlCredentialStorage = nil
            configuration.connectionProxyDictionary = [:]
            configuration.httpCookieStorage = nil; configuration.urlCache = nil
        }
        if QAMode.enabled {
            configuration.protocolClasses = [QARequestGuard.self] + (configuration.protocolClasses ?? [])
            configuration.connectionProxyDictionary = [:]
            configuration.httpCookieStorage = nil; configuration.urlCache = nil
        }
        #endif
        if isTestRun { configuration.protocolClasses = [OutsideRequestGuard.self] + (configuration.protocolClasses ?? []) }
        return configuration
    }

    /// Stands in for `URLSession.shared` (update check, setup check, template links, computer probe).
    static let sharedSession: URLSession = {
        #if DEBUG
        if QAMode.enabled || UIAcceptanceMode.requested { return URLSession(configuration: guarded(.ephemeral)) }
        #endif
        return isTestRun ? URLSession(configuration: guarded(.default)) : .shared
    }()

    static func isLoopback(_ host: String?) -> Bool {
        guard let host = host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")) else { return true }
        return ["127.0.0.1", "localhost", "::1"].contains(host)
    }

    /// True when `request` may go out; in a test run a non-loopback request is reported and refused.
    static func allows(_ request: URLRequest) -> Bool {
        #if DEBUG
        if UIAcceptanceMode.requested { return false }
        if QAMode.enabled { return QAMode.boundary.allows(request) }
        #endif
        guard isTestRun, !isLoopback(request.url?.host()) else { return true }
        reportOutsideRequest(request); return false
    }

    static func reportOutsideRequest(_ request: URLRequest) {
        let url = request.url?.absoluteString ?? "<no url>", probe = request.value(forHTTPHeaderField: probeHeader)
        if let sentinel { sentinel.outsideRequest(url, probe: probe) } else { FileHandle.standardError.write(Data("OUTSIDE REQUEST BLOCKED (no sentinel): \(url)\n".utf8)) }
    }

    /// P32 11: settings for a refused or test-mode caller. The suite is an absolute path in the temporary folder, so it
    /// never becomes a plist in ~/Library/Preferences (a plain suite name would, and cfprefsd keeps writing it back).
    static func scratchDefaults(_ label: String) -> UserDefaults {
        let folder = FileManager.default.temporaryDirectory.appending(path: "AgentAppTests-scratch-defaults")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return UserDefaults(suiteName: folder.appending(path: "AgentAppTests-\(label)").path)!
    }

    /// True in a test run: the call to production state is reported and must not be made.
    static func refuses(_ what: @autoclosure () -> String, probe: String? = nil) -> Bool {
        #if DEBUG
        if QAMode.enabled || UIAcceptanceMode.requested { return true }
        #endif
        guard isTestRun else { return false }
        if let sentinel { sentinel.productionAccess(what(), probe: probe) } else { FileHandle.standardError.write(Data("PRODUCTION ACCESS REFUSED (no sentinel): \(what())\n".utf8)) }
        return true
    }
}

/// Fails every non-loopback request in a test run without sending it (`URLError.notConnectedToInternet`).
final class OutsideRequestGuard: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { TestRunGuard.isTestRun && !TestRunGuard.isLoopback(request.url?.host()) }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        TestRunGuard.reportOutsideRequest(request)
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet, userInfo: [NSURLErrorFailingURLErrorKey: request.url as Any]))
    }
    override func stopLoading() {}
}
