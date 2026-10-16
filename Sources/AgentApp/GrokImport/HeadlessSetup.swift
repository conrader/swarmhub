import AppKit
import SwiftUI

/// `AgentApp --render-setup <dir>` (P21 item 16, P25): renders every setup step (OpenClaw's included), the simple Settings page, the empty state,
/// an agent's settings, the right panel (folded and open, P21b), P27's activity and skills banner, and P35's
/// box shots to PNG. Everything comes from a synthetic in-memory store, key store and
/// settings suite, and Test results are built in memory: no network, no Keychain, nothing of the real app is read or
/// written. Refuses a directory inside the repository, like `--render-snapshot`. `--only p38` / `--only p38b` / `--only p38c` / `--only p38d` / `--only p38e` / `--only p39` / `--only p40` / `--only p41` / `--only p42` / `--only p43` / `--only p44` / `--only p45` / `--only p46` / `--only team` renders just that part's shots.
@MainActor enum HeadlessSetup {
    static let size = NSSize(width: 580, height: 480)
    static let settingsSize = NSSize(width: 760, height: 560)

    static func run(arguments: [String]) -> Int32 {
        guard let flag = arguments.firstIndex(of: "--render-setup"), arguments.indices.contains(flag + 1) else {
            print("Usage: AgentApp --render-setup <dir> [--only p38|p38b|p38c|p38d|p38e|p39|p40|p41|p42|p43|p44|p45|p46|p47|team]"); return 64
        }
        let directory = URL(fileURLWithPath: (arguments[flag + 1] as NSString).expandingTildeInPath, isDirectory: true)
        // P38: `--only p38` / `--only p38b` / `--only p38c` / `--only p38d` / `--only p38e` renders just that part's shots.
        let only = arguments.firstIndex(of: "--only").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        if let only, !["p38", "p38b", "p38c", "p38d", "p38e", "p39", "p40", "p41", "p42", "p43", "p44", "p45", "p46", "p47", "team"].contains(only) { print("Unknown --only \(only); known: p38, p38b, p38c, p38d, p38e, p39, p40, p41, p42, p43, p44, p45, p46, p47, team"); return 64 }
        return HeadlessRunLoop.wait { await render(to: directory, only: only, output: { print($0); fflush(stdout) }) }
    }

    /// One synthetic connection: three agents found on a box, one of them already added.
    static func sampleResult(baseURL: URL) -> SetupCheckResult {
        let probes = [HermesProfileProbe(id: "default", status: .available(.init(id: "default", name: "Hermes", model: "hermes-agent"))),
                      HermesProfileProbe(id: "research", status: .available(.init(id: "research", name: "Research", model: "research"))),
                      HermesProfileProbe(id: "writer", status: .available(.init(id: "writer", name: "Writer", model: "writer"))),
                      HermesProfileProbe(id: "finance", status: .prefixIgnored)]
        return SetupCheckResult(outcome: .connected(place: baseURL.host ?? "", count: 3), baseURL: baseURL, probes: probes,
                                extraKeys: ["research": "synthetic-1", "writer": "synthetic-2", "finance": "synthetic-3"])
    }

    static func render(to directory: URL, only: String? = nil, output: (String) -> Void) async -> Int32 {
        if let repo = HeadlessSnapshot.enclosingRepository(of: directory) { output("Refused: \(directory.path) is inside the repository \(repo.path)."); return 2 }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch { output("Cannot create \(directory.path): \(error.localizedDescription)"); return 1 }
        let store = SetupPreview.makeStore()
        store.isSetupPreview = false
        let updater = AppUpdater(environment: ["SWARMHUB_DISABLE_UPDATES": "1"])
        let box = BoxAddress.url("my-box.example.com")!
        var filled = SetupFlow(prefill: .init(startAtAddress: true)); filled.input = .init(address: "my-box.example.com", key: "synthetic", extra: "research=synthetic-1")
        var shots: [(String, SetupFlow)] = [("s1-welcome", SetupFlow()), ("s3-empty", SetupFlow(prefill: .init(startAtAddress: true))), ("s3-filled", filled)]
        var hosting = SetupFlow(); hosting.apply(.newHosted); shots.append(("s-host", hosting))
        // P25: S2 and S3-OC, all pure: Test results are built in memory (a fake request id), nothing connects.
        var software = SetupFlow(); software.apply(.connectExisting); shots.append(("s2-software", software))
        var openClaw = software; openClaw.apply(.pick(.openClaw)); shots.append(("s3oc-empty", openClaw))
        var invalid = openClaw; invalid.openClaw.url = "ws://claw.example.com:18789"; shots.append(("s3oc-invalid-url", invalid))
        var pairing = openClaw; pairing.openClaw.key = "synthetic"
        pairing.apply(.openClawTest(.pairingRequired(requestId: "req-synthetic-1"), gatewayID: nil)); shots.append(("s3oc-pairing-required", pairing))
        var refused = openClaw; refused.apply(.openClawTest(.failed(GatewayFailure.tokenRejected.line), gatewayID: nil)); shots.append(("s3oc-error-key-rejected", refused))
        let errors: [(String, SetupCheckResult.Outcome)] = [("bad-address", .badAddress), ("not-encrypted", .notEncrypted(port: 8642)), ("unreachable", .unreachable),
                                                            ("key-rejected", .keyRejected), ("main-only", .mainOnly("Finance")), ("bad-line", .badLine)]
        for (name, outcome) in errors {
            var flow = filled; flow.apply(.test(.init(outcome: outcome, baseURL: box))); shots.append(("s3-error-\(name)", flow))
        }
        store.bots.append(Bot(name: "Hermes", backend: .hermes, hermesProfile: "default"))
        var choose = filled; choose.apply(.test(sampleResult(baseURL: box))); choose.preselect(alreadyAdded: store.addedProfileIDs); shots.append(("s4-choose", choose))
        let claw = OpenClawGateway(name: "OpenClaw", url: OpenClawCopy.tunnelURL)
        store.openClawGateways = [claw]
        store.bots.append({ let bot = Bot(name: "Alpha", backend: .openClaw); bot.openClaw = .init(gatewayID: claw.id, agentID: "agent-alpha"); return bot }())
        var clawChoose = openClaw
        clawChoose.apply(.openClawTest(.connected([.init(id: "agent-alpha", identityName: "Alpha"), .init(id: "agent-beta", name: "Beta"), .init(id: "ops")]), gatewayID: claw.id))
        clawChoose.preselect(alreadyAdded: store.openClawAgentIDs(boundTo: claw.id)); shots.append(("s4-choose-openclaw", clawChoose))

        var failures = 0
        func write(_ name: String, _ data: Data?) {
            let file = directory.appending(path: "\(name).png")
            if let data, (try? data.write(to: file)) != nil { output("\(file.path) \(data.count) bytes") } else { failures += 1; output("Failed: \(name)") }
        }
        if only == "p38" {
            await HeadlessP38Shots.render(write: write) { view, shotStore, size in await png(view, store: shotStore, updater: updater, size: size) }
            output("Rendered p38 shots to \(directory.path); \(failures) failed")
            return failures == 0 ? 0 : 1
        }
        if only == "p38b" {
            await HeadlessP38BShots.render(write: write) { view, shotStore, size in await png(view, store: shotStore, updater: updater, size: size) }
            output("Rendered P38 B to \(directory.path); \(failures) failed")
            return failures == 0 ? 0 : 1
        }
        if only == "p38c" {
            await HeadlessP38CShots.render(write: write) { view, shotStore, size in await png(view, store: shotStore, updater: updater, size: size) }
            output("Rendered p38c shots to \(directory.path); \(failures) failed")
            return failures == 0 ? 0 : 1
        }
        if only == "team" {
            await HeadlessTeamShots.render(write: write) { view, shotStore, size in await png(view, store: shotStore, updater: updater, size: size) }
            output("Rendered team coordination to \(directory.path); \(failures) failed")
            return failures == 0 ? 0 : 1
        }
        if only == "p38d" {
            await HeadlessP38DShots.render(write: write) { view, shotStore, size in await png(view, store: shotStore, updater: updater, size: size) }
            output("Rendered P38 D to \(directory.path); \(failures) failed")
            return failures == 0 ? 0 : 1
        }
        if only == "p39" {
            await HeadlessP39Shots.render(write: write) { view, shotStore, size in await png(view, store: shotStore, updater: updater, size: size) }
            output("Rendered P39 to \(directory.path); \(failures) failed")
            return failures == 0 ? 0 : 1
        }
        if only == "p40" {
            await HeadlessP40Shots.render(write: write) { view, shotStore, size in await png(view, store: shotStore, updater: updater, size: size) }
            output("Rendered P40 to \(directory.path); \(failures) failed")
            return failures == 0 ? 0 : 1
        }
        if only == "p41" {
            await HeadlessP41Shots.render(write: write) { view, shotStore, size in await png(view, store: shotStore, updater: updater, size: size) }
            output("Rendered P41 to \(directory.path); \(failures) failed")
            return failures == 0 ? 0 : 1
        }
        if only == "p42" {
            await HeadlessP42Shots.render(write: write) { view, shotStore, size in await png(view, store: shotStore, updater: updater, size: size) }
            output("Rendered P42 to \(directory.path); \(failures) failed")
            return failures == 0 ? 0 : 1
        }
        if only == "p43" {
            await HeadlessP43Shots.render(write: write) { view, shotStore, size in await png(view, store: shotStore, updater: updater, size: size) }
            output("Rendered P43 to \(directory.path); \(failures) failed")
            return failures == 0 ? 0 : 1
        }
        if only == "p44" {
            await HeadlessP44Shots.render(write: write) { view, shotStore, size in await png(view, store: shotStore, updater: updater, size: size) }
            output("Rendered P44 to \(directory.path); \(failures) failed")
            return failures == 0 ? 0 : 1
        }
        if only == "p45" {
            await HeadlessP45Shots.render(write: write) { view, shotStore, size in await png(view, store: shotStore, updater: updater, size: size) }
            output("Rendered P45 to \(directory.path); \(failures) failed")
            return failures == 0 ? 0 : 1
        }
        if only == "p46" {
            await HeadlessP46Shots.render(write: write) { view, shotStore, size in await png(view, store: shotStore, updater: updater, size: size) }
            output("Rendered P46 to \(directory.path); \(failures) failed")
            return failures == 0 ? 0 : 1
        }
        if only == "p47" {
            await HeadlessP47Shots.render(write: write) { view, shotStore, size, scheme in await png(view, store: shotStore, updater: updater, size: size, scheme: scheme) }
            output("Rendered P47 to \(directory.path); \(failures) failed")
            return failures == 0 ? 0 : 1
        }
        if only == "p38e" {
            await HeadlessP38EShots.render(write: write) { view, shotStore, size in await png(view, store: shotStore, updater: updater, size: size) }
            output("Rendered P38 E to \(directory.path); \(failures) failed")
            return failures == 0 ? 0 : 1
        }
        for (name, flow) in shots { write(name, await png(SetupView(preset: flow), store: store, updater: updater, size: size)) }
        do {
            try store.commitSetup(choose.result!, key: "synthetic", chosen: choose.chosen, confirmMove: false)
            var done = choose; done.apply(.add(count: choose.chosen.count, first: store.selectedBot?.name))
            write("s5-done", await png(SetupView(preset: done), store: store, updater: updater, size: size))
        } catch { failures += 1; output("Failed: s5-done (\(error))") }
        write("settings-simple", await png(SettingsSimplePane(openAdvanced: {}), store: store, updater: updater, size: settingsSize))
        let empty = SetupPreview.makeStore(); empty.isSetupPreview = false
        write("empty-state", await png(SetupEmptyState().frame(width: 700, height: 560).background(AppColor.chat), store: empty, updater: updater, size: settingsSize))
        if let agent = store.bots.first(where: { $0.backend == .hermes }) {
            write("editor-folded", await png(BotEditorView(bot: agent), store: store, updater: updater, size: NSSize(width: 560, height: 720)))
            write("editor-advanced", await png(BotEditorView(bot: agent, startExpanded: true), store: store, updater: updater, size: NSSize(width: 560, height: 720)))
        }
        await HeadlessInspector.render(store: store, write: write) { view, size in await png(view.background(AppColor.panel), store: store, updater: updater, size: size) }
        await HeadlessActivityShots.render(write: write) { view, shotStore, size in await png(view, store: shotStore, updater: updater, size: size) }
        await HeadlessP32Shots.render(write: write) { view, shotStore, size in await png(view, store: shotStore, updater: updater, size: size) }
        await HeadlessCodingShots.render(write: write) { view, shotStore, size in await png(view, store: shotStore, updater: updater, size: size) }
        await HeadlessAccountsShots.render(write: write) { view, shotStore, size in await png(view, store: shotStore, updater: updater, size: size) }
        await HeadlessP34Shots.render(write: write) { view, shotStore, size in await png(view, store: shotStore, updater: updater, size: size) }
        await HeadlessP35Shots.render(write: write) { view, shotStore, size in await png(view, store: shotStore, updater: updater, size: size) }
        await HeadlessP36Shots.render(write: write) { view, shotStore, size in await png(view, store: shotStore, updater: updater, size: size) }
        await HeadlessP37Shots.render(write: write) { view, shotStore, size in await png(view, store: shotStore, updater: updater, size: size) }
        await HeadlessP31DEShots.render(write: write) { view, shotStore, size in await png(view, store: shotStore, updater: updater, size: size) }
        await HeadlessP38Shots.render(write: write) { view, shotStore, size in await png(view, store: shotStore, updater: updater, size: size) }
        await HeadlessP38BShots.render(write: write) { view, shotStore, size in await png(view, store: shotStore, updater: updater, size: size) }
        await HeadlessP38CShots.render(write: write) { view, shotStore, size in await png(view, store: shotStore, updater: updater, size: size) }
        await HeadlessP38DShots.render(write: write) { view, shotStore, size in await png(view, store: shotStore, updater: updater, size: size) }
        await HeadlessP38EShots.render(write: write) { view, shotStore, size in await png(view, store: shotStore, updater: updater, size: size) }
        await HeadlessP39Shots.render(write: write) { view, shotStore, size in await png(view, store: shotStore, updater: updater, size: size) }
        await HeadlessP40Shots.render(write: write) { view, shotStore, size in await png(view, store: shotStore, updater: updater, size: size) }
        await HeadlessP41Shots.render(write: write) { view, shotStore, size in await png(view, store: shotStore, updater: updater, size: size) }
        await HeadlessP43Shots.render(write: write) { view, shotStore, size in await png(view, store: shotStore, updater: updater, size: size) }
        await HeadlessP44Shots.render(write: write) { view, shotStore, size in await png(view, store: shotStore, updater: updater, size: size) }
        await HeadlessP45Shots.render(write: write) { view, shotStore, size in await png(view, store: shotStore, updater: updater, size: size) }
        await HeadlessP46Shots.render(write: write) { view, shotStore, size in await png(view, store: shotStore, updater: updater, size: size) }
        await HeadlessP47Shots.render(write: write) { view, shotStore, size, scheme in await png(view, store: shotStore, updater: updater, size: size, scheme: scheme) }
        output("Rendered setup to \(directory.path); \(failures) failed")
        return failures == 0 ? 0 : 1
    }

    static func png<V: View>(_ view: V, store: AppStore, updater: AppUpdater, size: NSSize, scheme: ColorScheme = .dark) async -> Data? {
        await SnapshotRenderer.png(view.environmentObject(store).environmentObject(updater).defaultAppStorage(store.defaults), size: size, scheme: scheme)
    }
}
