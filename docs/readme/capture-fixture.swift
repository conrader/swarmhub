import AppKit
import Foundation
import Testing
import SwiftUI
@testable import AgentApp

@MainActor @Test func captureCurrentSwarmHubReadme() async throws {
    let store = AppStore(demoMode: true, storeURL: temporaryStore(), autoConfigureHermes: false,
                         keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    store.defaults.set("Demo", forKey: "accountName")
    let marks = [AvatarMark(shape: "blob", colour: "black"), AvatarMark(shape: "hex", colour: "blue"),
                 AvatarMark(shape: "bean", colour: "green"), AvatarMark(shape: "sparkle", colour: "orange"),
                 AvatarMark(shape: "clover", colour: "violet")]
    for (bot, mark) in zip(store.bots, marks) { bot.avatarMark = mark }
    let atlas = try #require(store.bots.first)
    atlas.messages = [
        ChatMessage(role: .user, content: "Can you review the launch plan and prepare the team update?"),
        ChatMessage(role: .assistant, content: "## Ready for launch\n\nThe checklist is complete.\n\n- Desktop QA passed.\n- Release notes are ready for review.\n- The team update is drafted below."),
        ChatMessage(role: .assistant, content: "```draft\nto: Team <team@example.com>\nsubject: SwarmHub launch update\n\nHi team,\n\nEverything is ready for launch. Please review the release notes before we send the final update.\n```")
    ]
    store.groups = [GroupChat(name: "Launch crew", memberIDs: [store.bots[0].id, store.bots[2].id])]
    store.selectedBot = atlas
    store.showInfo = true
    store.approvals = []
    let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SWARMHUB_README_OUTPUT"] ?? "/tmp/SwarmHub-readme-capture", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for (name, scheme) in [("swarmhub-dark.png", ColorScheme.dark), ("swarmhub-light.png", ColorScheme.light)] {
        SidebarWidth.dropStaleSavedWidths(in: store.defaults)
        let data = try #require(await SnapshotRenderer.contentPNG(store: store, size: NSSize(width: 1440, height: 900), scale: 2, scheme: scheme))
        let rep = try #require(NSBitmapImageRep(data: data))
        #expect(rep.pixelsWide == 2880 && rep.pixelsHigh == 1800)
        let path = directory.appending(path: name)
        try data.write(to: path)
        print("README_CAPTURE \(path.path) \(data.count) bytes \(rep.pixelsWide)x\(rep.pixelsHigh)")
    }
}
