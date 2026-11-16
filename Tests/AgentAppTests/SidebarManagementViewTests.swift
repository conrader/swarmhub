import AppKit
import SwiftUI
import Testing
import Vision
@testable import AgentApp

private struct SidebarManagementFixture: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        HStack(spacing: 1) {
            SidebarView(selection: .constant(store.selectedBot)).frame(width: 300)
        }.background(AppColor.chat)
    }
}

@MainActor private func sidebarWords(_ host: NSView, save: String? = nil) async throws -> [(text: String, y: CGFloat)] {
    for _ in 0..<3 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(80)) }
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(host.bounds.width * 2), pixelsHigh: Int(host.bounds.height * 2),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    bitmap.size = host.bounds.size; host.cacheDisplay(in: host.bounds, to: bitmap)
    if let save, let folder = ProcessInfo.processInfo.environment["SWARMHUB_SIDEBAR_PREVIEW_DIR"] {
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: folder).appending(path: "\(save).png"))
    }
    let recognition = VNRecognizeTextRequest(); recognition.recognitionLevel = .accurate; recognition.recognitionLanguages = ["en-US"]
    try VNImageRequestHandler(cgImage: #require(bitmap.cgImage)).perform([recognition])
    return recognition.results?.compactMap { result in result.topCandidates(1).first.map { ($0.string, result.boundingBox.midY) } } ?? []
}

private func y(_ text: String, in words: [(text: String, y: CGFloat)]) throws -> CGFloat {
    try #require(words.first { $0.text == text }).y
}
