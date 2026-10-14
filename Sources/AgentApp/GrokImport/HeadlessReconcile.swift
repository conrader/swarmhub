import AppKit
import CryptoKit
import Foundation
import Security

/// `AgentApp --reconcile [--dry-run] [--bot "<name>"] [--group "<name>"] [--store <path>]`: heals a store hurt by the
/// pre-P16 behaviour. GET only to the box; always works on a temp copy of store.json; the real file is replaced only after
/// a byte-equal backup, a key-path check and an unchanged SHA-256. Output is names and counts, never chat text.
@MainActor enum HeadlessReconcile {
    struct Options: Equatable {
        var dryRun = false; var bots: [String] = []; var groups: [String] = []; var store: URL
    }

    static let usage = "Usage: AgentApp --reconcile [--dry-run] [--bot \"<name>\"]... [--group \"<name>\"]... [--store <path>]"
    static let bundleID = "com.konrad.agentapp"

    static func parse(_ arguments: [String]) -> Options? {
        var options = Options(store: defaultStore)
        var index = arguments.firstIndex(of: "--reconcile").map { $0 + 1 } ?? arguments.endIndex
        while index < arguments.endIndex {
            let flag = arguments[index]
            switch flag {
            case "--dry-run": options.dryRun = true
            case "--bot", "--group", "--store":
                guard arguments.indices.contains(index + 1) else { return nil }
                let value = arguments[index + 1]; index += 1
                if flag == "--bot" { options.bots.append(value) } else if flag == "--group" { options.groups.append(value) }
                else { options.store = URL(fileURLWithPath: (value as NSString).expandingTildeInPath) }
            default: return nil
            }
            index += 1
        }
        return options
    }

    static var defaultStore: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appending(path: "AgentApp/store.json")
    }

    /// Another process of the app (not this one) is running.
    static func appIsRunning() -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    }

    static func run(arguments: [String]) -> Int32 {
        guard let options = parse(arguments) else { print(usage); return 64 }
        // Keychain UI off (as --check-bots): a key this build cannot read silently is reported, never prompted for.
        SecKeychainSetUserInteractionAllowed(false)
        return HeadlessRunLoop.wait { await reconcile(options, keyStore: KeychainHermesKeyStore(), session: HermesURLSession.shared, appIsRunning: appIsRunning, output: { print($0); fflush(stdout) }) }
    }

    static func reconcile(_ options: Options, keyStore: any HermesKeyStore, session: URLSession, defaults: UserDefaults = .standard, appIsRunning: () -> Bool,
                          beforeSwap: () -> Void = {}, output: (String) -> Void) async -> Int32 {
        // Writing next to a running app could lose either side's changes; a dry run only reads a copy.
        if !options.dryRun && appIsRunning() { output("Refused: \(AppConstants.name) is running. Quit it first."); return 75 }
        guard let original = try? Data(contentsOf: options.store) else { output("Reconcile failed: cannot read \(options.store.path)"); return 1 }
        let startHash = sha256(original)
        let work = FileManager.default.temporaryDirectory.appending(path: "reconcile-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: work) }
        let copy = work.appending(path: "store.json")
        do { try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true); try original.write(to: copy) }
        catch { output("Reconcile failed: cannot make a temp copy"); return 1 }
        let store = AppStore(storeURL: copy, autoConfigureHermes: false, keyStore: keyStore, defaults: defaults, hermesSession: session)
        guard store.persistenceEnabled else { output("Reconcile failed: the store could not be loaded"); return 1 }
        store.reconcileTiming.floor = .zero; store.reconcileTiming.openFloor = .zero
        let filtered = !options.bots.isEmpty || !options.groups.isEmpty
        func named(_ names: [String], _ value: String) -> Bool { names.contains { $0.caseInsensitiveCompare(value) == .orderedSame } }
        let bots = store.bots.filter { $0.backend == .hermes && !$0.isReadOnlyArchive && (!filtered || named(options.bots, $0.name)) }
        let groups = store.groups.filter { !filtered || named(options.groups, $0.name) }
        var changed = 0, failed = 0
        for (kind, conversation, name) in bots.map({ ("Bot", $0 as any Conversation, $0.name) }) + groups.map({ ("Group", $0 as any Conversation, $0.name) }) {
            let report = await store.reconcile(conversation, reason: .headless, full: true)
            if report.changed { changed += 1 }
            if !report.problems.isEmpty || report.read < report.total { failed += 1 }
            output(line(kind: kind, name: name, report: report))
        }
        if options.dryRun { output("Dry run: nothing written (\(changed) would change, \(failed) failed)"); return failed == 0 ? 0 : 1 }
        guard changed > 0 else { output("Reconcile: 0 changed, \(failed) failed, no backup"); return failed == 0 ? 0 : 1 }
        store.save()
        guard let healed = try? Data(contentsOf: copy) else { output("Reconcile failed: the healed copy is unreadable; nothing written"); return 1 }
        let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
        let backup = options.store.deletingLastPathComponent().appending(path: "store.json.backup-reconcile-\(stamp)")
        do { try original.write(to: backup, options: .withoutOverwriting) } catch { output("Reconcile failed: the backup could not be written; nothing written"); return 1 }
        guard (try? Data(contentsOf: backup)) == original else { output("Reconcile failed: the backup differs; nothing written"); return 1 }
        if let problem = verify(old: original, new: healed) { output("Reconcile failed: \(problem); nothing written, backup \(backup.lastPathComponent)"); return 1 }
        beforeSwap()
        guard let current = try? Data(contentsOf: options.store), sha256(current) == startHash else {
            output("Reconcile failed: store.json changed while it was reconciled; nothing written, backup \(backup.lastPathComponent)"); return 1
        }
        do { try healed.write(to: options.store, options: .atomic) } catch { output("Reconcile failed: store.json could not be replaced"); return 1 }
        output("Reconcile: \(changed) changed, \(failed) failed, backup \(backup.lastPathComponent)")
        return failed == 0 ? 0 : 1
    }

    /// "Group Konrad, DMT, Achilles | DMT: paired 4, extended 0, added 0 | … | read 2/2 sessions".
    static func line(kind: String, name: String, report: ReconcileReport) -> String {
        var parts = ["\(kind) \(name)"]
        for (segment, counts) in report.segments {
            var text = "\(segment): paired \(counts.paired), extended \(counts.extended)"
            if counts.extendedChars > 0 { text += " (+\(counts.extendedChars) chars)" }
            text += ", added \(counts.added)"
            for (label, value) in [("filled", counts.filled), ("settled", counts.settled), ("not sent", counts.notSent), ("conflicts", counts.conflicts),
                                   ("box shorter", counts.serverPrefix), ("ambiguous", counts.ambiguous), ("older ignored", counts.ignoredOld), ("capped", counts.capped)] where value > 0 {
                text += ", \(label) \(value)"
            }
            parts.append(text)
        }
        parts += report.problems
        parts.append("read \(report.read)/\(report.total) sessions")
        return parts.joined(separator: " | ")
    }

    /// nil when no key path of the old file is dropped, no message disappeared and every message still starts with its
    /// old text; otherwise the first problem (names only).
    nonisolated static func verify(old: Data, new: Data) -> String? {
        guard let before = try? JSONSerialization.jsonObject(with: old), let after = try? JSONSerialization.jsonObject(with: new) else { return "the store is not JSON" }
        var oldPaths: Set<String> = [], newPaths: Set<String> = []
        var oldMessages: [String: String] = [:], newMessages: [String: String] = [:]
        collect(before, path: "", into: &oldPaths, messages: &oldMessages)
        collect(after, path: "", into: &newPaths, messages: &newMessages)
        if let missing = oldPaths.subtracting(newPaths).sorted().first { return "key \(missing) would be dropped" }
        for (id, text) in oldMessages {
            guard let healed = newMessages[id] else { return "message \(id) would disappear" }
            guard healed.hasPrefix(text) else { return "message \(id) would lose text" }
        }
        return nil
    }

    nonisolated private static func collect(_ value: Any, path: String, into paths: inout Set<String>, messages: inout [String: String]) {
        if let object = value as? [String: Any] {
            if let id = object["id"] as? String, object["role"] != nil, let content = object["content"] as? String { messages[id] = content }
            for (key, child) in object { let next = "\(path)/\(key)"; paths.insert(next); collect(child, path: next, into: &paths, messages: &messages) }
        } else if let array = value as? [Any] {
            for (index, child) in array.enumerated() {
                let key = (child as? [String: Any])?["id"] as? String ?? "\(index)"
                let next = "\(path)[\(key)]"; paths.insert(next); collect(child, path: next, into: &paths, messages: &messages)
            }
        }
    }

    nonisolated static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
