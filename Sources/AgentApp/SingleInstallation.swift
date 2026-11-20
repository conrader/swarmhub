import AppKit
import CoreServices
import Security

enum SingleInstallation {
    static let bundleID = "com.konrad.agentapp"
    static let installedURL = URL(fileURLWithPath: "/Applications/SwarmHub.app", isDirectory: true)
    static let launchCheckFlag = "--verify-install-launch"

    static func isInstalled(_ url: URL) -> Bool {
        url.standardizedFileURL.path == installedURL.path
    }

    static func isNewer(_ installed: AppBuildInfo, than running: AppBuildInfo) -> Bool {
        guard let current = SemanticVersion(running.version), let available = SemanticVersion(installed.version) else { return false }
        if available != current { return available > current }
        guard let currentBuild = running.build.flatMap(SemanticVersion.init),
              let installedBuild = installed.build.flatMap(SemanticVersion.init) else { return false }
        return installedBuild > currentBuild
    }

    /// Handles an older Finder/Dock shortcut before opening its store or starting its updater.
    @MainActor static func redirectOlderCopy(_ running: Bundle = .main) -> Bool {
        guard running.bundleIdentifier == bundleID, !isInstalled(running.bundleURL),
              let installed = Bundle(url: installedURL), installed.bundleIdentifier == bundleID,
              isNewer(.current(bundle: installed), than: .current(bundle: running)),
              verifiesSignature(installedURL) else { return false }
        return ExternalLink.open(installedURL)
    }

    /// The normal launch, including Sparkle's relaunch, is the point at which the replacement has actually started.
    static func cleanUpAfterLaunch(_ running: Bundle = .main) {
        guard running.bundleIdentifier == bundleID, isInstalled(running.bundleURL) else { return }
        let manager = FileManager.default
        let registered = LSCopyApplicationURLsForBundleIdentifier(bundleID as CFString, nil)?.takeRetainedValue() as? [URL] ?? []
        let otherCopies = registered.filter { !isInstalled($0) }
        for url in otherCopies { unregister(url) }
        if otherCopies.contains(where: { !manager.fileExists(atPath: $0.path) }) {
            runLSRegister(["-gc"])
        }

        // Older standalone installers used this dedicated folder for rollback apps.
        guard let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let backups = support.appending(path: "SwarmHub-App-Backups")
        let symlink: Set<URLResourceKey> = [.isSymbolicLinkKey]
        guard (try? backups.resourceValues(forKeys: symlink))?.isSymbolicLink == false,
              let folders = try? manager.contentsOfDirectory(at: backups, includingPropertiesForKeys: Array(symlink)),
              !folders.isEmpty, verifiesSignature(running.bundleURL) else { return }
        for folder in folders where folder.lastPathComponent.hasPrefix("install-") {
            guard (try? folder.resourceValues(forKeys: symlink))?.isSymbolicLink == false else { continue }
            let backup = folder.appending(path: "SwarmHub.app")
            guard (try? backup.resourceValues(forKeys: symlink))?.isSymbolicLink == false,
                  Bundle(url: backup)?.bundleIdentifier == bundleID else { continue }
            unregister(backup)
            try? manager.removeItem(at: backup)
            if (try? manager.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
                try? manager.removeItem(at: folder)
            }
        }
    }

    private static func verifiesSignature(_ url: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return false }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode | kSecCSCheckAllArchitectures)
        return SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess
    }

    private static func unregister(_ url: URL) { runLSRegister(["-u", url.path]) }

    private static func runLSRegister(_ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        if (try? process.run()) != nil { process.waitUntilExit() }
    }
}
