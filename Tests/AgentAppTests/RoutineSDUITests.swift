import AppKit
import CryptoKit
import Foundation
import ImageIO
import SwiftUI
import SwarmHubCore
import Testing
@testable import AgentApp

// P7b: the Mac routine targets. The renderer's tree, goldens and router are SwarmHubCore tests; these cover the app
// wiring: compiled views unchanged unless a fitting document exists, and submits reach only the existing routine paths.

private let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private func target(_ name: String) -> Data {
    (try? Data(contentsOf: repoRoot.appending(path: "Tests/Fixtures/release-bundles/ui-render/targets/\(name).json"))) ?? Data()
}

private let targets: [String: Data] = [
    SDUIRoutineTarget.resultCardView: target("routine-result-card"),
    SDUIRoutineTarget.editFormView: target("routine-edit-form"),
    SDUIRoutineTarget.createFormView: target("routine-create-form")
]

private func source(_ documents: [String: Data], killed: Set<String> = []) -> SDUIViewSource {
    SDUIViewSource(documents: documents, policy: SDUIMac.policy, bundleVersion: 12, isViewKilled: { killed.contains($0) })
}

private func critical(_ view: String) -> [String: Data] {
    [view: Data(#"{"schema":"swarmhub/ui/2","critical":true,"view":"\#(view)","root":{}}"#.utf8)]
}

/// Drawn by AppKit in an offscreen window with the light appearance pinned (`SnapshotRenderer`), as the app's other
/// snapshot tests do. `ImageRenderer` draws AppKit-backed controls as placeholders and does not pin the appearance
/// `AppColor` resolves against; under it the same compiled view drew different pixels as the run went on (the Mac runs
/// of af86f86 and b9d33dc failed different cases with the host code unchanged).
@MainActor private func pixels<V: View>(_ view: V) async throws -> String {
    let size = NSSize(width: 560, height: 520)
    let png = try #require(await SnapshotRenderer.png(view.frame(width: size.width, height: size.height, alignment: .topLeading),
                                                      size: size, scale: 1, scheme: .light))
    let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
    return try pixelDigest(try #require(CGImageSourceCreateImageAtIndex(source, 0, nil)))
}

/// The compiled baseline after one warm-up draw, drawn twice: a difference here is the renderer, not a host.
@MainActor private func baseline<V: View>(_ view: V, _ name: String) async throws -> String {
    _ = try await pixels(view)
    let first = try await pixels(view), second = try await pixels(view)
    #expect(first == second, "\(name): the compiled view must draw the same pixels every time")
    return first
}

/// Compare visible pixels, not the provider's storage (which can include undefined row padding, unused channels
/// and different bitmap formats). Keep every pixel and the dimensions, with no tolerance or downsampling.
private func pixelDigest(_ image: CGImage) throws -> String {
    var rgba = Data(repeating: 0, count: image.width * image.height * 4)
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    try rgba.withUnsafeMutableBytes { bytes in
        let context = try #require(CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    let hash = SHA256.hash(data: rgba).map { String(format: "%02x", $0) }.joined()
    return "\(image.width)x\(image.height):\(hash)"
}

@Test func routinePixelComparisonIgnoresStoragePaddingButDetectsChangedPixels() throws {
    func image(padding: UInt8, red: UInt8 = 120, height: Int = 2) throws -> CGImage {
        let row: [UInt8] = [red, 30, 60, 255, padding, padding, padding, padding]
        let bytes = Data(Array(repeating: row, count: height).flatMap { $0 })
        let provider = try #require(CGDataProvider(data: bytes as CFData))
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        return try #require(CGImage(width: 1, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
            space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
                .union(.byteOrder32Big), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }
    let first = try image(padding: 0), second = try image(padding: 255)
    // The old helper would reject these identical images.
    let firstBytes = try #require(first.dataProvider?.data) as Data
    let secondBytes = try #require(second.dataProvider?.data) as Data
    #expect(firstBytes != secondBytes)
    #expect(try pixelDigest(first) == pixelDigest(second))
    #expect(try pixelDigest(first) != pixelDigest(image(padding: 0, red: 121)))
    #expect(try pixelDigest(first) != pixelDigest(image(padding: 0, height: 1)))
}

private func sampleJob(_ id: String = "0123456789ab") -> HermesJob {
    HermesJob(id: id, name: "Morning brief", prompt: "Summarise the inbox", schedule: "0 9 * * *", scheduleDisplay: "0 9 * * *",
              enabled: true, state: "scheduled", lastRunAt: "2026-10-20T09:00:00+02:00", lastStatus: "ok")
}

/// The four wiring cases, compared pixel for pixel with the compiled card: no bundle / no document, decoder fallback
/// and kill switch draw exactly the compiled view; `update_required` draws the compiled update-required view.
@MainActor @Test func routineCardHostDrawsTheCompiledCardUnlessADocumentFits() async throws {
    let message = AppStore.routineCard(job: sampleJob(), result: HermesRunResult(sessionID: "cron_x_1", text: "All checks passed."),
                                       lookupError: nil)
    let compiled = try await baseline(RoutineResultCard(message: message), "card")
    let unknown = [SDUIRoutineTarget.resultCardView: Data(#"{"schema":"swarmhub/ui/1","view":"routine_result_card","root":{"type":"web_view"}}"#.utf8)]
    let empty = SDUIMac.installedSource(root: FileManager.default.temporaryDirectory.appending(path: "p7b-\(UUID().uuidString)"))
    for (name, compiledSource) in [("no bundle", SDUIViewSource.compiledOnly), ("nothing installed", empty),
                                   ("other views only", source([SDUIRoutineTarget.editFormView: targets[SDUIRoutineTarget.editFormView]!])),
                                   ("decoder fallback", source(unknown)),
                                   ("killed view", source(targets, killed: [SDUIRoutineTarget.resultCardView])),
                                   ("killed component", source(targets, killed: ["badge"])),
                                   ("killed critical", source(critical(SDUIRoutineTarget.resultCardView), killed: [SDUIRoutineTarget.resultCardView]))] {
        if case .compiled = SDUIRoutineTarget.resultCard(compiledSource) {} else { Issue.record("\(name): expected compiled card") }
        let hosted = try await pixels(RoutineResultCardHost(message: message).environment(\.sduiViewSource, compiledSource))
        #expect(hosted == compiled, "\(name)")
    }
    let update = try await pixels(RoutineResultCardHost(message: message).environment(\.sduiViewSource, source(critical(SDUIRoutineTarget.resultCardView))))
    let updateView = try await pixels(SDUIUpdateRequiredView(inSheet: false))
    #expect(update != compiled)
    #expect(update == updateView)
}

@MainActor @Test func routineEditorHostDrawsTheCompiledSheetUnlessADocumentFits() async throws {
    let (store, bot, _) = routinesStore(FakeJobsServer())
    for job in [nil, sampleJob()] as [HermesJob?] {
        let compiled = try await baseline(RoutineEditorSheet(bot: bot, job: job).environmentObject(store), job == nil ? "create" : "edit")
        let view = job == nil ? SDUIRoutineTarget.createFormView : SDUIRoutineTarget.editFormView
        let golden = (try? Data(contentsOf: repoRoot.appending(path: "Tests/Fixtures/release-bundles/ui/documents/routine-form.json"))) ?? Data()
        for (name, compiledSource) in [("no bundle", SDUIViewSource.compiledOnly),
                                       ("decoder fallback", source([view: Data("{".utf8)])),
                                       ("does not fit", source([SDUIRoutineTarget.editFormView: golden, SDUIRoutineTarget.createFormView: golden])),
                                       ("killed view", source(targets, killed: [view])),
                                       ("killed critical", source(critical(view), killed: [view]))] {
            if case .compiled = SDUIRoutineTarget.editor(compiledSource, routineID: job?.id, data: RoutineSDUIData.editor(bot: bot, job: job)) {
            } else { Issue.record("\(name): expected compiled editor") }
            let hosted = try await pixels(RoutineEditorHost(bot: bot, job: job).environment(\.sduiViewSource, compiledSource).environmentObject(store))
            #expect(hosted == compiled, "\(name) \(job == nil ? "create" : "edit")")
        }
        let update = try await pixels(RoutineEditorHost(bot: bot, job: job).environment(\.sduiViewSource, source(critical(view))).environmentObject(store))
        let updateView = try await pixels(SDUIUpdateRequiredView(inSheet: true))
        #expect(update != compiled)
        #expect(update == updateView)
        if case .document = SDUIRoutineTarget.editor(source(targets), routineID: job?.id, data: RoutineSDUIData.editor(bot: bot, job: job)) {
        } else {
            Issue.record("the target document should render for \(view)")
        }
    }
}

@MainActor @Test func nothingInstalledReadsAsCompiledAndCreatesNothing() {
    let root = FileManager.default.temporaryDirectory.appending(path: "p7b-\(UUID().uuidString)")
    let installed = SDUIMac.installedSource(root: root)
    #expect(!installed.hasDocuments)
    #expect(installed.bundleVersion == nil)
    #expect(!FileManager.default.fileExists(atPath: root.path))
    #expect(SDUIMac.urlHosts.isEmpty)
    // The compiled allowlist is empty, so the shared golden card (it has an open_url button) is compiled on the Mac.
    let card = (try? Data(contentsOf: repoRoot.appending(path: "Tests/Fixtures/release-bundles/ui/documents/routine-card.json"))) ?? Data()
    #expect(SDUIRoutineTarget.resultCard(source([SDUIRoutineTarget.resultCardView: card])) == .compiled(reason: "url_not_allowed"))
}

@MainActor @Test func cardDataIsWhatTheCompiledCardShowsAndNoSession() {
    let job = sampleJob()
    let message = AppStore.routineCard(job: job, result: HermesRunResult(sessionID: "cron_abc_1", text: "Done."), lookupError: nil)
    let bot = Bot(name: "Jarvis", backend: .hermes, hermesProfile: "grok-jarvis")
    let data = RoutineSDUIData.card(message, bot: bot, job: job)
    #expect(data.values["routine.id"] == .string(job.id))
    #expect(data.values["routine.name"] == .string("Morning brief"))
    #expect(data.values["result.status"] == .string("ok"))
    #expect(data.values["result.summary"] == .string("Done."))
    #expect(data.values["result.has_output"] == .bool(true))
    #expect(data.values["routine.schedule_text"] == .string(RoutineScheduleDraft.describe(job.schedule)))
    #expect(!data.values.keys.contains { $0.contains("session") })
    #expect(!data.values.values.contains(.string("cron_abc_1")))
}

private final class Counter { var value = 0 }

/// A document submit goes router → `SDUIAppCommand` → the existing `createRoutine` / `updateRoutine`, nothing else.
@MainActor @Test func documentSubmitsUseTheExistingRoutinePaths() async throws {
    let server = FakeJobsServer()
    server.add(jobPayload(id: "0123456789ab", name: "Morning brief"))
    let (store, bot, host) = routinesStore(server)
    #expect(await store.refreshRoutines(for: bot))
    let job = try #require(store.routines.state(for: bot.id).jobs.value?.first)
    let dismissed = Counter()
    let router = SDUIActionRouter(urlHosts: SDUIMac.urlHosts)

    func form(_ view: String, _ name: String, job: HermesJob?) throws -> SDUIRenderForm {
        guard case .render(let document) = SDUIDecoder.decode(target(name), view: view, policy: SDUIMac.policy),
              case .card(_, _, let children)? = SDUIRenderer.tree(document, data: RoutineSDUIData.editor(bot: bot, job: job))?.element,
              case .form(let form)? = children.first?.element else { throw CancellationError() }
        return form
    }

    let editor = RoutineSDUICommands(store: store, bot: bot, job: job, dismiss: { dismissed.value += 1 }, open: { _ in })
    let edit = router.submit(try form(SDUIRoutineTarget.editFormView, "routine-edit-form", job: job), values: ["schedule": .text("0 8 * * 1-5")])
    guard case .perform(let save) = edit else { Issue.record("save not routed: \(edit)"); return }
    #expect(save == .routineSave(job.id, SDUIRoutineDraft(name: job.name, schedule: "0 8 * * 1-5", prompt: job.prompt)))
    #expect(await editor.perform(save) == nil)
    let patch = try #require(MockHermesProtocol.recorded(host).last)
    #expect(jsonBody(patch) as NSDictionary? == ["schedule": "0 8 * * 1-5"] as NSDictionary, "only changed fields are sent")
    #expect(dismissed.value == 1)

    let creator = RoutineSDUICommands(store: store, bot: bot, job: nil, dismiss: { dismissed.value += 1 }, open: { _ in })
    let create = router.submit(try form(SDUIRoutineTarget.createFormView, "routine-create-form", job: nil),
                               values: ["name": .text("Tide check"), "schedule": .text("30 7 * * 1-5"), "prompt": .text("Check the tides")])
    guard case .perform(let created) = create else { Issue.record("create not routed: \(create)"); return }
    #expect(await creator.perform(created) == nil)
    let post = try #require(MockHermesProtocol.recorded(host).last)
    #expect(jsonBody(post) as NSDictionary? == ["name": "Tide check", "schedule": "30 7 * * 1-5", "prompt": "Check the tides",
                                                "deliver": "local"] as NSDictionary)
    #expect(dismissed.value == 2)

    // Outside its sheet, or for another routine, a submit does nothing and sends nothing.
    let sent = MockHermesProtocol.recorded(host).count
    let card = RoutineSDUICommands(store: store, bot: bot, job: job, dismiss: nil, open: { _ in })
    let draft = SDUIRoutineDraft(name: "X", schedule: "0 1 * * *", prompt: nil)
    #expect(!card.isAvailable(.routineCreate(draft)))
    #expect(!card.isAvailable(.routineSave(job.id, draft)))
    #expect(!editor.isAvailable(.routineSave("another-job", draft)))
    #expect(!editor.isAvailable(.routineCreate(draft)))
    #expect(await card.perform(.routineSave(job.id, draft)) == nil)
    #expect(await editor.perform(.routineSave("another-job", draft)) == nil)
    #expect(MockHermesProtocol.recorded(host).count == sent)
    // Screens the Mac has no compiled destination for are not offered.
    for screen in [SDUIScreen.chat, .boxes, .updates] { #expect(!card.isAvailable(.navigate(screen))) }
    for screen in [SDUIScreen.routines, .skills, .settings] { #expect(card.isAvailable(.navigate(screen))) }
}
