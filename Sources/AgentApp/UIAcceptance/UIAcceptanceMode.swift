import Foundation
import Darwin

/// Kept in release too: an acceptance request must never fall through to normal startup.
enum UIAcceptanceMode {
    static let variable = "SWARMHUB_UI_ACCEPTANCE"
    static let requested = ProcessInfo.processInfo.environment[variable] != nil
    static let banner = "ACCEPTANCE MODE - nothing is sent"

    static func validate(environment: [String: String]) throws -> Bool {
        guard let flag = environment[variable] else { return false }
        guard flag == "1" else { throw UIAcceptanceError.unsafeConfiguration }
        // No connection overrides, alternate mode, key paths or opaque acceptance options.
        for (name, value) in environment where !value.isEmpty && name != variable {
            let key = name.uppercased()
            if key.contains("HERMES") || key.contains("COMPOSIO") || key.contains("OPENCLAW")
                || key.contains("KEYCHAIN") || key.hasPrefix("SWARMHUB_UI_ACCEPTANCE_")
                || key == "SWARMHUB_QA_MODE" {
                throw UIAcceptanceError.unsafeConfiguration
            }
        }
        return true
    }

    static func refuse(_ reason: String) -> Never {
        FileHandle.standardError.write(Data("UI acceptance launch refused: \(reason)\n".utf8))
        exit(78)
    }
}

enum UIAcceptanceError: LocalizedError {
    case unsafeConfiguration, unsafeDependency, invalidOperation
    var errorDescription: String? {
        switch self {
        case .unsafeConfiguration:
            "Set only SWARMHUB_UI_ACCEPTANCE=1; remove Hermes, connector, Keychain and other QA configuration."
        case .unsafeDependency:
            "Acceptance requires the in-process backend, in-memory keys and a fresh temporary store; real services are forbidden."
        case .invalidOperation:
            "The acceptance operation changed or is unavailable. Nothing was sent."
        }
    }
}

#if DEBUG
/// Blocks every URL, including loopback; there is no acceptance network exception.
final class UIAcceptanceRequestGuard: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: UIAcceptanceError.unsafeDependency) }
    override func stopLoading() {}
}

@MainActor enum UIAcceptanceIsolation {
    private(set) static var directory: URL?

    static func activate() throws -> URL {
        guard try UIAcceptanceMode.validate(environment: ProcessInfo.processInfo.environment) else {
            throw UIAcceptanceError.unsafeConfiguration
        }
        var template = Array((NSTemporaryDirectory() + "swarmhub-ui-acceptance-XXXXXXXX").utf8CString)
        let path = template.withUnsafeMutableBufferPointer { buffer -> String? in
            guard let base = buffer.baseAddress, mkdtemp(base) != nil else { return nil }
            return String(cString: base)
        }
        guard let path else { throw UIAcceptanceError.unsafeDependency }
        let root = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath()
        directory = root
        URLProtocol.registerClass(UIAcceptanceRequestGuard.self)
        return root
    }

    static func validate(backend: any AgentBackend, keys: any HermesKeyStore,
                         autoConfigure: Bool, storeURL: URL?, root: URL?, isolatedDefaults: Bool,
                         hermesURL: String?, connectors: [String]) throws {
        guard backend is UIAcceptanceChatBackend, keys is MemoryKeyStore, !autoConfigure,
              isolatedDefaults, hermesURL == nil, connectors.isEmpty, let storeURL, let root,
              storeURL.isFileURL, root.isFileURL,
              storeURL.resolvingSymlinksInPath().standardizedFileURL.deletingLastPathComponent().path
                == root.resolvingSymlinksInPath().standardizedFileURL.path else {
            throw UIAcceptanceError.unsafeDependency
        }
    }
}
#endif
