import AppKit
import Foundation
import SwiftUI
import Testing
import Vision
@testable import AgentApp

// recs1: the suggestion reads as the bot's own message with its quick replies under it. SWARMHUB_SUGGESTION_CAPTURE=<dir>
// writes the PNG (the PR's screenshot).
@MainActor @Test func aSuggestionRendersAsTheBotsMessageWithItsReplies() async throws {
    var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
    let calendar = utc
    let day = { (number: Int) in calendar.date(from: DateComponents(year: 2026, month: 10, day: number, hour: 9, minute: 30))! }
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { _ in GroupBackend(name: "Ada") }, keyStore: InMemoryKeyStore(),
                         defaults: isolatedDefaults())
    store.heartbeatTimeZone = calendar.timeZone; store.now = { day(21).addingTimeInterval(1_800) }
    let bot = Bot(name: "Ada"); store.bots = [bot]
    bot.messages = [19, 20, 21].flatMap { index in
        [ChatMessage(role: .user, content: "Summarize my inbox", createdAt: day(index)),
         ChatMessage(role: .assistant, content: "3 new messages: the invoice from Acme, a meeting move to Thursday and a newsletter.", createdAt: day(index).addingTimeInterval(30))]
    }
    _ = try #require(await store.suggestRoutineIfRepeated(bot: bot))
    let target = ConversationActionTarget.bot(botID: bot.id, threadID: nil)
    let view = VStack(alignment: .leading, spacing: 0) { ForEach(Array(bot.messages.suffix(3))) { MessageView(message: $0, actionTarget: target) } }
        .environmentObject(store).frame(width: 720, height: 420, alignment: .topLeading).background(AppColor.panel)
    let data = try #require(await SnapshotRenderer.png(view, size: NSSize(width: 720, height: 420), scheme: .dark))
    let bitmap = try #require(NSBitmapImageRep(data: data)), cgImage = try #require(bitmap.cgImage)
    let recognition = VNRecognizeTextRequest(); recognition.recognitionLevel = .accurate; recognition.recognitionLanguages = ["en-US"]
    try VNImageRequestHandler(cgImage: cgImage).perform([recognition])
    let text = recognition.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ") ?? ""
    #expect(text.contains("Want me to run it") && text.contains("Different time") && text.contains("No thanks"), "the question and its chips render: \(text)")
    if let directory = ProcessInfo.processInfo.environment["SWARMHUB_SUGGESTION_CAPTURE"] {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: directory).appending(path: "suggestion-dark.png"))
    }
}
