import Darwin
import Foundation

/// Command-line entry points that run without a window:
///   AgentApp --import-grok "<export folder | index.json | bundle.json>"
///   AgentApp --render-snapshot <dir> [--bot "<name>"]...         (see HeadlessSnapshot.swift)
///   AgentApp --migrate-store                                      (see HeadlessGroups.swift)
///   AgentApp --probe-attachment <file>   (reads a PDF/RTF/DOC/DOCX like the composer; counts only, no network; see HeadlessProbeAttachment.swift)
///   AgentApp --grok-fetch --mode recent|full [--bots <names>] [--store <store.json>] [--report <file>]   (see HeadlessGrok.swift)
///   AgentApp --grok-probe [--live] [--report <file>]   (Grok Bot drift check; see HeadlessGrok.swift)
///   AgentApp --grok-parity <python export folder> [--cache <folder>]   (see HeadlessGrokParity.swift)
///   AgentApp --render-setup <dir>     (every setup step and the simple Settings page from a synthetic store; see HeadlessSetup.swift)
/// Launch arguments of the normal app (window shown): `--ui-smoke <report.json>` and `--setup-preview` (SetupPreview.swift).
@MainActor enum HeadlessCommands {
    /// Every flag the app recognises; the dispatcher below and the launch arguments read this list.
    static let flags = ["--render-snapshot", "--probe-attachment", "--migrate-store", "--grok-fetch", "--grok-probe",
                        "--grok-parity", "--import-grok", "--ui-smoke", "--setup-preview", "--render-setup"]
    /// The flags that run without a window and exit.
    static let headless = flags.filter { $0 != "--ui-smoke" && $0 != "--setup-preview" }

    /// Returns an exit code when a headless command was requested, otherwise nil.
    static func runIfRequested(arguments: [String] = CommandLine.arguments) -> Int32? {
        guard arguments.contains(where: headless.contains) else { return nil }
        if arguments.contains("--render-setup") { return HeadlessSetup.run(arguments: arguments) }
        if arguments.contains("--render-snapshot") { return HeadlessSnapshot.run(arguments: arguments) }
        if arguments.contains("--probe-attachment") { return HeadlessProbeAttachment.run(arguments: arguments) }
        if arguments.contains("--migrate-store") { return migrateStore() }
        if let code = HeadlessGrok.runIfRequested(arguments: arguments) { return code }
        guard let flagIndex = arguments.firstIndex(of: "--import-grok") else { return nil }
        guard arguments.indices.contains(flagIndex + 1) else { print("Usage: AgentApp --import-grok <folder>"); return 64 }
        let path = (arguments[flagIndex + 1] as NSString).expandingTildeInPath
        let store = AppStore(autoStart: false)
        return importGrok(path: path, store: store, output: { print($0) })
    }

    static func importGrok(path: String, store: AppStore, output: (String) -> Void) -> Int32 {
        guard store.persistenceEnabled else { output("Import failed: \(store.errorMessage ?? "the store cannot be saved.")"); return 1 }
        do {
            let rows = try store.importGrokExport(at: URL(fileURLWithPath: path))
            for row in rows {
                let source = "\(row.sourceShape ?? "-")/\(row.sourceColour ?? "-")"
                output("\(row.name) | \(row.isGroup ? "group" : "bot") | history \(row.historyCount) | avatar \(source) -> \(row.mark.shape)/\(row.mark.colour) | \(row.created ? "added" : "updated")")
            }
            output("Imported \(rows.count) bots into \(store.fileURL.path)")
            return 0
        } catch {
            output("Import failed: \(error.localizedDescription)")
            return error is GrokBundleError ? 2 : 1
        }
    }
}
