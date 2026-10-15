import AppKit
import Foundation
import SwiftUI
import Testing
import Vision
@testable import AgentApp

// P43 part 1: a reply is kept and drawn in the order it happened (text → steps → text). The live case: the bot wrote
// an opening line, ran skill_view → terminal → write_file, then answered. Synthetic servers and text only.

private let opening = "I'll start with a read-only onboarding audit of the repo."
private let answer = "Started. I audited the live README and wrote the onboarding notes. Nothing was pushed or published."

private func step(_ name: String, at time: Date = .now) -> [(String, [String: Any])] {
    [("tool.started", ["message_id": "msg_1", "tool_name": name, "preview": "\(name) preview", "session_id": "s", "run_id": "run_1", "seq": 1, "ts": 1.0]),
     ("tool.completed", ["message_id": "msg_1", "tool_name": name, "preview": NSNull(), "session_id": "s", "run_id": "run_1", "seq": 2, "ts": 2.0])]
}

@MainActor private func orderStore(_ events: [(String, [String: Any])], url: URL = temporaryStore()) -> (AppStore, Bot) {
    let stream = ChatParityServer.Reply.sse(events)
    let (_, hermes) = ChatParityServer.serve(features: ["session_chat_streaming": true]) { request, _ in
        let path = request.url!.path
        if path.hasSuffix("/chat/stream") { return stream }
        if path == "/api/sessions" { return .json(200, ["session": ["id": "s-order"]]) }
        return .json(404, ["error": "no route"])
    }
    let store = AppStore(storeURL: url, autoConfigureHermes: false, backendFactory: { _ in hermes }, keyStore: InMemoryKeyStore(["hermes": "k"]), defaults: isolatedDefaults())
    let bot = Bot(name: "Swarmhub", backend: .hermes, hermesProfile: "default")
    store.bots = [bot]; store.selectedBot = bot
    return (store, bot)
}

@Test @MainActor func streamedTextToolsTextKeepsThatOrderAndSurvivesAReload() async throws {
    let url = temporaryStore()
    let (store, bot) = orderStore([("assistant.delta", ["delta": opening])] + step("skill_view") + step("terminal") + step("write_file")
                                  + [("assistant.delta", ["delta": answer]), ("run.completed", [:])], url: url)
    #expect(store.send(text: "Onboard the repo")); try await waitUntil { !store.anyTurnRunning }
    let reply = try #require(bot.messages.last { $0.role == .assistant })
    #expect(reply.content == opening + answer)
    #expect(ReplyLayout.segments(content: reply.content, activity: reply.activity) == [.text(opening), .steps(0..<3), .text(answer)])
    #expect(reply.finalText == answer)
    #expect(reply.metadata["status"] == nil)

    let reloaded = AppStore(storeURL: url, autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let saved = try #require(reloaded.bots.first?.messages.last { $0.role == .assistant })
    #expect(ReplyLayout.segments(content: saved.content, activity: saved.activity) == [.text(opening), .steps(0..<3), .text(answer)])
}

@Test @MainActor func statusOfTheFirstToolIsClearedWhenTheTurnFinishes() async throws {
    let (store, bot) = orderStore(step("skill_view") + [("assistant.delta", ["delta": answer]), ("run.completed", [:])])
    #expect(store.send(text: "go")); try await waitUntil { !store.anyTurnRunning }
    let reply = try #require(bot.messages.last { $0.role == .assistant })
    #expect(reply.metadata["status"] == nil, "the live status was \(reply.metadata["status"] ?? "-")")
    #expect(ReplyLayout.segments(content: reply.content, activity: reply.activity) == [.steps(0..<1), .text(answer)])
}

private func activity(_ offsets: [Int?]) -> ToolActivity {
    var activity = ToolActivity(); let start = Date(timeIntervalSince1970: 1_000)
    for (index, offset) in offsets.enumerated() {
        activity.apply(ToolEvent(phase: .started, name: "terminal", callID: "c\(index)"), at: start.addingTimeInterval(Double(index)), textOffset: offset)
        activity.apply(ToolEvent(phase: .completed, name: "terminal", callID: "c\(index)"), at: start.addingTimeInterval(Double(index) + 0.5))
    }
    activity.finish(at: start.addingTimeInterval(10)); return activity
}

@Test func severalBurstsSplitTheTextWhereTheyHappened() {
    let a = "First look.", b = "\n\nHalf way.", c = " Done."
    let content = a + b + c
    let one = a.utf16.count, two = (a + b).utf16.count
    #expect(ReplyLayout.segments(content: content, activity: activity([one, one, two])) == [.text(a), .steps(0..<2), .text(b), .steps(2..<3), .text(c)])
    #expect(ReplyLayout.finalText(content: content, activity: activity([one, one, two])) == "Done.")
    // Only whitespace between two bursts: one burst.
    let spaced = a + "\n\n" + c
    #expect(ReplyLayout.segments(content: spaced, activity: activity([one, one + 2])) == [.text(a), .steps(0..<2), .text(c)])
    // Text only before the tools (still streaming, or no answer): text then steps, as before P43.
    #expect(ReplyLayout.segments(content: a, activity: activity([one])) == [.text(a), .steps(0..<1)])
    #expect(ReplyLayout.finalText(content: a, activity: activity([one])) == a)
    // An offset past the text (a replaced text) is clamped.
    #expect(ReplyLayout.segments(content: a, activity: activity([500])) == [.text(a), .steps(0..<1)])
}

@Test func oldMessagesWithoutOffsetsAreUnchanged() throws {
    let old = """
    {"steps":[{"name":"terminal","startedAt":0,"finishedAt":1,"failed":false}],"total":1,"endedAt":1}
    """
    let decoded = try JSONDecoder().decode(ToolActivity.self, from: Data(old.utf8))
    #expect(decoded.steps.first?.textOffset == nil)
    #expect(ReplyLayout.segments(content: "Old reply", activity: decoded) == nil)
    #expect(ReplyLayout.finalText(content: "Old reply", activity: decoded) == "Old reply")
    #expect(ReplyLayout.segments(content: "No tools", activity: nil) == nil)
}

@Test @MainActor func sidebarPreviewShowsTheFinalSegment() {
    let content = opening + answer
    let reply = ChatMessage(role: .assistant, content: content)
    reply.activity = activity([opening.utf16.count, opening.utf16.count, opening.utf16.count])
    let line = SidebarFragment.text(messages: [reply], draft: nil, isWorking: false, archiveNewest: nil)
    #expect(line.hasPrefix("Started. I audited"), "\(line)")
}

@Test func reconcileOfTheLiveRowShapeKeepsTextStepsText() throws {
    let rows: [[String: Any]] = [
        ["id": 1, "role": "user", "content": "Onboard the repo", "timestamp": 100.0],
        ["id": 2, "role": "assistant", "content": opening, "timestamp": 101.0, "tool_calls": [["id": "a", "type": "function", "function": ["name": "skill_view", "arguments": "{}"]]]],
        ["id": 3, "role": "tool", "content": "skill text", "tool_call_id": "a", "timestamp": 102.0],
        ["id": 4, "role": "assistant", "content": NSNull(), "timestamp": 103.0, "tool_calls": "[{\"id\":\"b\",\"function\":{\"name\":\"terminal\"}}]"],
        ["id": 5, "role": "tool", "content": "ok", "tool_call_id": "b", "timestamp": 104.0],
        ["id": 6, "role": "assistant", "content": "", "timestamp": 105.0, "tool_calls": [["id": "c", "function": ["name": "write_file"]]]],
        ["id": 7, "role": "tool", "content": "written", "tool_call_id": "c", "timestamp": 106.0],
        ["id": 8, "role": "assistant", "content": answer, "timestamp": 107.0, "finish_reason": "stop"]
    ]
    let server = rows.compactMap { HermesBackend.parseMessage($0, toolCalls: true) }
    #expect(server.map(\.role) == ["user", "assistant", "assistant", "assistant", "assistant"], "tool rows are dropped, tool-only assistant rows kept")
    #expect(rows.compactMap { HermesBackend.parseMessage($0) }.count == 3, "other readers see the rows as before")

    // A turn the app does not have: added with its steps where they happened.
    let plan = HistoryReconciler.plan(.init(local: [], server: server, mode: .chat(additions: true)))
    let added = try #require(plan.additions.first?.rows.last)
    #expect(added.content == opening + "\n\n" + answer)
    let steps = try #require(added.activity)
    #expect(steps.steps.map(\.name) == ["skill_view", "terminal", "write_file"])
    #expect(ReplyLayout.segments(content: added.content, activity: steps) == [.text(opening), .steps(0..<3), .text("\n\n" + answer)])

    // The live row (both texts joined, steps kept) pairs as equal and is left alone.
    let user = HistoryReconciler.LocalRow(role: .user, text: "Onboard the repo")
    var live = HistoryReconciler.LocalRow(role: .assistant, text: opening + answer, state: .finished); live.hasSteps = true
    let same = HistoryReconciler.plan(.init(local: [user, live], server: server, mode: .chat(additions: true)))
    #expect(same.isEmpty)

    // A cut row without steps is filled with the box's text and its steps, placed in the new text.
    let cut = HistoryReconciler.LocalRow(role: .assistant, text: opening, state: .incomplete)
    let fill = HistoryReconciler.plan(.init(local: [user, cut], server: server, mode: .chat(additions: true)))
    let edit = try #require(fill.edits.first)
    let content = try #require(edit.content)
    #expect(ReplyLayout.segments(content: content, activity: edit.activity)?.first == .text(opening))
    #expect(ReplyLayout.finalText(content: content, activity: edit.activity) == answer)
}

@Test @MainActor func aRenderDrawsTextThenStepsThenTheAnswer() async throws {
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let reply = ChatMessage(role: .assistant, content: "Opening line here." + "Final answer here.", turnState: .finished)
    reply.activity = activity([18, 18, 18])
    let size = NSSize(width: 640, height: 320)
    let view = VStack { MessageView(message: reply); Spacer() }.frame(width: size.width, height: size.height, alignment: .topLeading).background(AppColor.chat)
        .environmentObject(store).defaultAppStorage(store.defaults).environment(\.colorScheme, .dark)
    _ = NSApplication.shared
    let host = NSHostingView(rootView: view)
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false; window.contentView = host; host.frame = NSRect(origin: .zero, size: size)
    defer { window.contentView = nil; window.close() }
    for _ in 0..<3 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(80)) }
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    bitmap.size = size; host.cacheDisplay(in: host.bounds, to: bitmap)
    let lines = try await topToBottom(try #require(bitmap.cgImage))
    let order = ["Opening line", "3 steps", "Final answer"].compactMap { key in lines.firstIndex { $0.contains(key) } }
    #expect(order.count == 3 && order == order.sorted(), "\(lines)")
}

/// Recognized lines sorted top to bottom (Vision's origin is bottom-left).
private func topToBottom(_ image: CGImage) async throws -> [String] {
    nonisolated(unsafe) let image = image
    return try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global().async {
            let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
            do {
                try VNImageRequestHandler(cgImage: image).perform([request])
                let found = (request.results ?? []).compactMap { result in result.topCandidates(1).first.map { ($0.string, result.boundingBox.midY) } }
                continuation.resume(returning: found.sorted { $0.1 > $1.1 }.map(\.0))
            } catch { continuation.resume(throwing: error) }
        }
    }
}
