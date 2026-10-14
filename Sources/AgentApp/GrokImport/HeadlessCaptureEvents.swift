import Foundation
import Security

/// `AgentApp --capture-events` (P27 D9): one live turn in a throwaway `swarmhub-selftest-` session of a copy of Jarvis
/// (the `--e2e` plumbing: the real store is read only, keys are read silently, nothing is saved), asking for one
/// harmless read-only tool call. Prints each SSE event name the stream carried with its JSON key paths — never a value.
@MainActor enum HeadlessCaptureEvents {
    static let request = "[\(AppConstants.name) self-test — use one read-only tool, change nothing] Call your skills_list tool once (no other tool), then reply with exactly: E2E-TOOLS"

    static func run(arguments: [String]) -> Int32 {
        SecKeychainSetUserInteractionAllowed(false)
        let realURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appending(path: "AgentApp/store.json")
        let saved: StoreFile
        do { saved = try StoreFile.decode(Data(contentsOf: realURL)) } catch { print("Capture failed: cannot read \(realURL.path): \(error.localizedDescription)"); return 1 }
        guard let jarvis = HeadlessE2E.find("Jarvis", in: saved.bots) else { print("Capture failed: no Hermes bot named Jarvis in the store"); return 1 }
        let directory = FileManager.default.temporaryDirectory.appending(path: "\(HeadlessE2E.namespace)\(UUID().uuidString.lowercased())", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(storeURL: directory.appending(path: "store.json"), autoConfigureHermes: false)
        let bot = HeadlessE2E.copy(jarvis, name: "\(jarvis.name) \(HeadlessE2E.namespace)events-\(directory.lastPathComponent.suffix(8))")
        store.bots = [bot]; store.groups = []; store.sessionNamespace = HeadlessE2E.namespace
        HeadlessE2E.select(bot, in: store)
        return HeadlessRunLoop.wait {
            HermesStreamTap.shared.start(); defer { HermesStreamTap.shared.stop() }
            let turn = await HeadlessE2E.turn(store: store, text: request, conversation: bot, timing: .init())
            print("Capture: session \(turn.session ?? "-") | reply \(turn.error == nil && turn.reply.contains("E2E-TOOLS") ? "ok" : "not as asked (\(turn.error ?? "other text"))")")
            let assistant = bot.messages.last { $0.role == .assistant && $0.presentation == .text }
            print("Capture: \(assistant?.activity?.steps.count ?? 0) activity steps recorded")
            for (event, keys) in HermesStreamTap.shared.captured { print("event \(event): \(keys.joined(separator: ", "))") }
            return HermesStreamTap.shared.captured.isEmpty ? 1 : 0
        }
    }
}
