import Darwin
import Foundation

/// Command-line entry points that run without a window:
///   AgentApp --import-grok "<export folder | index.json | bundle.json>"
///   AgentApp --import-keys <file>      (lines `profile=key`; file must be 0600 and owned by the user)
///   AgentApp --check-bots [--chat "<bot name>" "<text>"]   (see HeadlessCheckBots.swift)
///   AgentApp --render-snapshot <dir> [--bot "<name>"]...         (see HeadlessSnapshot.swift)
///   AgentApp --migrate-store                                      (see HeadlessGroups.swift)
///   AgentApp --probe-attachment <file>   (reads a PDF/RTF/DOC/DOCX like the composer; counts only, no network; see HeadlessProbeAttachment.swift)
///   AgentApp --e2e                       (live self-test in throwaway sessions; see HeadlessE2E.swift)
///   AgentApp --grok-fetch --mode recent|full [--bots <names>] [--store <store.json>] [--report <file>]   (see HeadlessGrok.swift)
///   AgentApp --grok-probe [--live] [--report <file>]   (Grok Bot drift check; see HeadlessGrok.swift)
///   AgentApp --grok-parity <python export folder> [--cache <folder>]   (see HeadlessGrokParity.swift)
@MainActor enum HeadlessCommands {
    /// Returns an exit code when a headless command was requested, otherwise nil.
    static func runIfRequested(arguments: [String] = CommandLine.arguments) -> Int32? {
        if arguments.contains("--check-bots") { return runCheckBots(arguments: arguments) }
        if arguments.contains("--render-snapshot") { return HeadlessSnapshot.run(arguments: arguments) }
        if arguments.contains("--probe-attachment") { return HeadlessProbeAttachment.run(arguments: arguments) }
        if arguments.contains("--migrate-store") { return migrateStore() }
        if arguments.contains("--e2e") { return HeadlessE2E.run(arguments: arguments) }
        if let code = HeadlessGrok.runIfRequested(arguments: arguments) { return code }
        guard let flagIndex = arguments.firstIndex(where: { $0 == "--import-grok" || $0 == "--import-keys" }) else { return nil }
        guard arguments.indices.contains(flagIndex + 1) else { print("Usage: AgentApp --import-grok <folder> | --import-keys <file>"); return 64 }
        let path = (arguments[flagIndex + 1] as NSString).expandingTildeInPath
        if arguments[flagIndex] == "--import-keys" { return importKeys(path: path, keyStore: KeychainHermesKeyStore(), output: { print($0) }) }
        let store = AppStore(autoConfigureHermes: false)
        return importGrok(path: path, store: store, output: { print($0) })
    }

    static func importGrok(path: String, store: AppStore, output: (String) -> Void) -> Int32 {
        guard store.persistenceEnabled else { output("Import failed: \(store.errorMessage ?? "the store cannot be saved.")"); return 1 }
        do {
            let rows = try store.importGrokExport(at: URL(fileURLWithPath: path))
            for row in rows {
                let source = "\(row.sourceShape ?? "-")/\(row.sourceColour ?? "-")"
                output("\(row.name) | \(row.profile ?? "group") | history \(row.historyCount) | avatar \(source) -> \(row.mark.shape)/\(row.mark.colour) | \(row.created ? "added" : "updated")")
            }
            output("Imported \(rows.count) bots into \(store.fileURL.path)")
            return 0
        } catch {
            output("Import failed: \(error.localizedDescription)")
            return error is GrokBundleError ? 2 : 1
        }
    }

    enum KeyFileProblem: Error, Equatable { case missing, notRegularFile, wrongOwner, wrongMode(UInt16) }

    /// The key file must be a regular file (not a symlink) owned by this user with mode exactly 0600.
    static func checkKeyFile(_ path: String) -> KeyFileProblem? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return .missing }
        guard info.st_mode & S_IFMT == S_IFREG else { return .notRegularFile }
        guard info.st_uid == getuid() else { return .wrongOwner }
        let mode = UInt16(info.st_mode & 0o777)
        return mode == 0o600 ? nil : .wrongMode(mode)
    }

    /// Stores each `profile=key` line in the Keychain (`default=` → account `hermes`), then overwrites
    /// and deletes the file. Prints only profile names and OK/failed.
    static func importKeys(path: String, keyStore: any HermesKeyStore, output: (String) -> Void) -> Int32 {
        if let problem = checkKeyFile(path) {
            switch problem {
            case .missing: output("Key file not found.")
            case .notRegularFile: output("Refused: the key file must be a regular file, not a link or folder.")
            case .wrongOwner: output("Refused: the key file must be owned by you.")
            case .wrongMode(let mode): output("Refused: the key file has mode \(String(mode, radix: 8)); it must be 600 (chmod 600 <file>).")
            }
            return 2
        }
        guard let data = FileManager.default.contents(atPath: path), let text = String(data: data, encoding: .utf8) else { output("Key file is not readable UTF-8 text."); return 2 }
        var failures = 0
        for (number, rawLine) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let profile = pair[0].trimmingCharacters(in: .whitespaces)
            let key = pair.count == 2 ? pair[1].trimmingCharacters(in: .whitespaces) : ""
            guard pair.count == 2, HermesKeyPaste.isValidProfileName(profile), !key.isEmpty else {
                output("line \(number + 1): failed (expected profile=key)"); failures += 1; continue
            }
            let account = AppStore.keyAccount(forProfile: profile)
            keyStore.setKey(key, for: account)
            let stored = keyStore.key(for: account) == key
            if !stored { failures += 1 }
            output("\(profile): \(stored ? "OK" : "failed")")
        }
        shred(path: path, length: data.count)
        output(FileManager.default.fileExists(atPath: path) ? "Warning: the key file could not be deleted." : "Key file overwritten and deleted.")
        return failures == 0 ? 0 : 1
    }

    private static func shred(path: String, length: Int) {
        let descriptor = open(path, O_WRONLY | O_NOFOLLOW)
        if descriptor >= 0 {
            let zeros = [UInt8](repeating: 0, count: max(length, 1))
            _ = zeros.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
            fsync(descriptor); close(descriptor)
        }
        unlink(path)
    }
}
