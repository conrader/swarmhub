import CryptoKit
import Foundation
import SwarmHubCore

/// P2c (CORE-PLAN.md §3.5): the box updater's bootstrap package, embedded in the app build with its SHA-256 by
/// `scripts/release/baseline.py embed` (`Bootstrap/swarmhub-updater-<version>.tar` and `.tar.sha256`). The expected digest
/// comes only from the app build (the `.sha256` file is sealed by the app's code signature), never from chat, a management
/// turn or the update host. Export checks the bytes against it first and writes nothing on a mismatch.
struct BootstrapPackage: Equatable {
    let packageURL: URL
    /// Lowercase hex SHA-256 the build recorded for the package; what the operator compares on the box.
    let expectedDigest: String
    private let directory: URL
    var fileName: String { packageURL.lastPathComponent }

    enum ExportError: Error, Equatable, LocalizedError {
        case unreadable
        case digestMismatch(expected: String, actual: String)
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .unreadable: "The embedded updater package cannot be read."
            case .digestMismatch(let expected, let actual): "The embedded updater package does not match its SHA-256 (expected \(expected), found \(actual)). Nothing was exported."
            case .writeFailed(let path): "Could not write \(path)."
            }
        }
    }

    /// Only the app's sealed Bootstrap directory is trusted. Bare SwiftPM executables have no verified package.
    /// Check the bytes before offering either export or the expected digest in the UI.
    static func locate(in bundle: Bundle = .main) -> BootstrapPackage? {
        let files = FileManager.default
        guard let folder = AppBundleResources.directory("Bootstrap", in: bundle),
              let names = try? files.contentsOfDirectory(atPath: folder.path) else { return nil }
        let packages = names.filter { $0.hasPrefix("swarmhub-updater-") && $0.hasSuffix(".tar") }
        guard packages.count == 1, let name = packages.first,
              let sidecar = try? AppBundleResources.read(name + ".sha256", in: folder),
              let text = String(data: sidecar, encoding: .ascii),
              let digest = digest(fromLine: text, fileName: name),
              let bytes = try? AppBundleResources.read(name, in: folder),
              Self.digest(of: bytes) == digest else { return nil }
        return BootstrapPackage(packageURL: folder.appending(path: name), expectedDigest: digest, directory: folder)
    }

    /// The digest from a `shasum -a 256` / `sha256sum` line for `fileName`, or nil.
    static func digest(fromLine text: String, fileName: String) -> String? {
        let suffix = "  " + fileName + "\n"
        guard text.hasSuffix(suffix) else { return nil }
        let digest = String(text.dropLast(suffix.count))
        return isDigest(digest) ? digest : nil
    }

    static func isDigest(_ text: String) -> Bool {
        text.count == 64 && text.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    static func digest(of data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// The package's current SHA-256 (what export would write).
    func actualDigest() throws -> String {
        guard let data = try? AppBundleResources.read(fileName, in: directory) else { throw ExportError.unreadable }
        return Self.digest(of: data)
    }

    /// Writes the package and its `.sha256` line into `folder` after checking the bytes against `expectedDigest`, then reads
    /// the written package back and checks it again. Returns the written package's URL.
    func export(to folder: URL) throws -> URL {
        guard let data = try? AppBundleResources.read(fileName, in: directory) else { throw ExportError.unreadable }
        let actual = Self.digest(of: data)
        guard actual == expectedDigest else { throw ExportError.digestMismatch(expected: expectedDigest, actual: actual) }
        let target = folder.appending(path: fileName), sidecar = folder.appending(path: fileName + ".sha256")
        do { try data.write(to: target, options: .atomic) } catch { throw ExportError.writeFailed(target.path) }
        let written = (try? Data(contentsOf: target)).map(Self.digest(of:))
        guard written == expectedDigest else {
            try? FileManager.default.removeItem(at: target)
            throw ExportError.digestMismatch(expected: expectedDigest, actual: written ?? "unreadable")
        }
        do { try Data("\(expectedDigest)  \(fileName)\n".utf8).write(to: sidecar, options: .atomic) } catch { throw ExportError.writeFailed(sidecar.path) }
        return target
    }

    /// The commands the operator runs on the box before extracting anything.
    func checkCommands() -> [String] { ["shasum -a 256 \(fileName)", "sha256sum \(fileName)"] }
}
