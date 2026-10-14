import AppKit
import Foundation

/// Whether Grok Bot is on this Mac, and what the import sheet can offer (briefs/P10.md P10d 1). Pure apart from the
/// injected lookups: never prompts, never uses the network, and gates on shape, never on version.
struct GrokLocator: Sendable {
    var location: GrokLocation
    /// Launch Services' URL for `GrokProtocol.bundleIdentifier`; nil when no such app is registered.
    var registeredApp: @Sendable () -> URL?

    static func live() -> GrokLocator {
        GrokLocator(location: .live()) {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: GrokProtocol.bundleIdentifier)
        }
    }

    /// Tier 1, the only check that may run at launch: is there any door at all? Reads no Grok data, only whether the
    /// app (registered, else at `/Applications/Grok Bot.app`) or its data folder exists. False = hidden everywhere.
    var isPresent: Bool {
        if registeredApp() != nil { return true }
        let files = FileManager.default
        return files.fileExists(atPath: location.app.path) || files.fileExists(atPath: location.dataFolder.path)
    }

    /// Tier 2, when the sheet opens: what the no-prompt preflight allows.
    static func availability(_ preflight: GrokPreflight, persistenceEnabled: Bool) -> GrokAvailability {
        guard persistenceEnabled else { return .unavailable(.persistenceOff) }
        guard preflight.cache != nil else { return .unavailable(.cache(preflight.cacheError ?? .notFound)) }
        if let reason = preflight.cacheOnlyReason { return .cacheOnly(reason) }
        return .ready
    }
}

/// Tier 2's answer. `cacheOnly` still imports the recent messages kept on this Mac (no prompt, no network).
enum GrokAvailability: Sendable, Equatable {
    case unavailable(GrokUnavailable)
    case cacheOnly(GrokImportRunError)
    case ready

    var canImport: Bool { if case .unavailable = self { false } else { true } }
}

/// Why nothing can be imported right now. Every message is secret-free and says what to do next.
enum GrokUnavailable: Sendable, Equatable {
    case cache(GrokCacheError)
    case persistenceOff

    var message: String {
        switch self {
        case .persistenceOff: GrokImportError.persistenceDisabled.errorDescription ?? ""
        case .cache(.notFound), .cache(.noRoster): "Grok Bot has no bot list on this Mac yet. Open Grok Bot once and sign in."
        case .cache(.unrecognisedShape), .cache(.symlinked):
            "\(AppConstants.name) cannot read this version of Grok Bot's data."
        case .cache(.needsAccountChoice):
            "\(AppConstants.name) imports one Grok account at a time, and Grok Bot's data on this Mac holds several. " +
                "Export one account with the export script and use the export folder instead."
        case .cache(let error): error.errorDescription ?? ""
        }
    }

    /// The folder could not be read: offer an open panel on it (choosing it there gives this app access).
    var offersFolderAccess: Bool { self == .cache(.folderUnreadable) }
    /// Several accounts: point at the export-folder import.
    var offersExportFolder: Bool { if case .cache(.needsAccountChoice) = self { true } else { false } }
}
