import AppKit
import CryptoKit
import SwiftUI
import Testing
@testable import AgentApp

@MainActor private final class PickerSelection: ObservableObject {
    @Published var choice = AvatarChoice.mark(shape: "star", colour: "blue")
}

@MainActor private struct PickerForm: View {
    @ObservedObject var selection: PickerSelection
    var body: some View {
        Form { Section("Avatar") { AvatarPickerView(choice: $selection.choice, seed: "picker-ui-test") } }
            .formStyle(.grouped).environment(\.colorScheme, .dark)
    }
}

@MainActor @Test func pickerSelectionChangesTheVisiblePreviewAndSavedAvatar() async throws {
    _ = NSApplication.shared
    let selection = PickerSelection()
    let size = NSSize(width: 500, height: 560)
    let host = NSHostingView(rootView: PickerForm(selection: selection).frame(width: size.width, height: size.height))
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false; window.contentView = host; host.frame = NSRect(origin: .zero, size: size)
    defer { window.contentView = nil; window.close() }
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(300))
    let before = try #require(await SnapshotRenderer.png(PickerForm(selection: selection), size: size, scale: 1))
    var touched = false
    let binding = Binding(get: { selection.choice }, set: { selection.choice = $0; touched = true })
    binding.wrappedValue.selectShape("circle", seed: "picker-ui-test")
    try await Task.sleep(for: .milliseconds(100))
    #expect(selection.choice == .mark(shape: "circle", colour: "blue"))
    binding.wrappedValue.selectColour(.orange, seed: "picker-ui-test")
    try await Task.sleep(for: .milliseconds(100))
    #expect(selection.choice == .mark(shape: "circle", colour: "orange") && touched)
    let after = try #require(await SnapshotRenderer.png(PickerForm(selection: selection), size: size, scale: 1))
    #expect(before != after, "The picker must visibly show the new shape, color and selected tile.")
    let bot = Bot(name: "UI picker test")
    selection.choice.apply(to: bot)
    #expect(bot.avatarLook == .mark(shape: "circle", colour: .orange))

    if let path = ProcessInfo.processInfo.environment["SWARMHUB_AVATAR_PREVIEW_DIR"] {
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try before.write(to: directory.appending(path: "picker-before.png"))
        try after.write(to: directory.appending(path: "picker-circle-orange.png"))
    }
}

@MainActor @Test func savedAvatarChangesRefreshAnExistingAvatarView() async throws {
    _ = NSApplication.shared
    let bot = Bot(name: "Reactive avatar")
    bot.avatarMark = AvatarMark(shape: "star", colour: "blue")
    let probe = "picker-reactivity"
    let key = "\(probe)|\(bot.id)"
    let host = NSHostingView(rootView: BotAvatar(bot: bot, size: 48, probe: probe))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false; window.contentView = host
    host.frame = NSRect(x: 0, y: 0, width: 100, height: 100)
    defer { window.contentView = nil; window.close(); UISmokeProbe.avatarFacts.removeValue(forKey: key) }
    host.layoutSubtreeIfNeeded()
    let appeared = await HeadlessE2E.wait(.seconds(2), poll: .milliseconds(25)) {
        UISmokeProbe.avatarFacts[key]?["words"] as? String == "star/blue"
    }
    #expect(appeared)
    AvatarChoice.mark(shape: "circle", colour: "orange").apply(to: bot)
    let refreshed = await HeadlessE2E.wait(.seconds(2), poll: .milliseconds(25)) {
        UISmokeProbe.avatarFacts[key]?["words"] as? String == "circle/orange"
    }
    #expect(refreshed, "Saving must refresh the same mounted avatar without reopening the chat.")
}

@MainActor @Test func pickerBodiesHaveDistinctVisibleRenders() throws {
    _ = NSApplication.shared
    var images: [String: String] = [:]
    for shape in AvatarKitMap.pickerShapes {
        let renderer = ImageRenderer(content: AvatarStillMark(type: AvatarKitMap.body(for: shape).type, colourHex: "#1084FE", size: 48)
            .frame(width: 72, height: 72).environment(\.colorScheme, .dark))
        let image = try #require(renderer.cgImage)
        let pixels = try #require(image.dataProvider?.data)
        let digest = SHA256.hash(data: pixels as Data).map { String(format: "%02x", $0) }.joined()
        #expect(images[digest] == nil, "\(shape) repeats the visible avatar for \(images[digest] ?? "unknown").")
        images[digest] = shape
    }
}

@MainActor @Test func newAgentEditorSavesTheLookShownBeforeAnySelection() {
    let seed = "avatar-editor-preview"
    let fields = BotEditorFields.newAgent(hermesConfigured: false, avatarSeed: seed)
    let shown = fields.avatar.previewMark(seed: seed)
    let bot = Bot(name: "Saved agent")
    fields.avatar.apply(to: bot)
    #expect(bot.avatarMark == shown)
    #expect(fields.avatar != .unpicked)
}
