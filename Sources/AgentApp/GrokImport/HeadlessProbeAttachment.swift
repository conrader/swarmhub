import Foundation

/// `AgentApp --probe-attachment <path>`: runs the real `prepareAll` on one file with an encoder pointed at a
/// throwaway folder (deleted afterwards, so page images never reach the real store). No network. Prints
/// counts and names only, never the file's text.
@MainActor enum HeadlessProbeAttachment {
    static func run(arguments: [String]) -> Int32 {
        guard let index = arguments.firstIndex(of: "--probe-attachment"), arguments.indices.contains(index + 1) else {
            print("Usage: AgentApp --probe-attachment <file>"); return 64
        }
        let url = URL(fileURLWithPath: (arguments[index + 1] as NSString).expandingTildeInPath)
        return HeadlessRunLoop.wait { await probe(url, output: { print($0); fflush(stdout) }) }
    }

    static func probe(_ url: URL, limits: DocumentLimits = .standard, output: (String) -> Void) async -> Int32 {
        let folder = FileManager.default.temporaryDirectory.appending(path: "swarmhub-probe-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let encoder = AttachmentEncoder(directory: folder.appending(path: "attachments", directoryHint: .isDirectory))
        output("file: \(url.lastPathComponent)")
        output("pl-PL OCR model: \(PageOCR.languages().polish ? "available" : "not available")")
        let started = Date()
        do {
            let (attachments, extraction) = try await encoder.prepareAllDetailed(fileURL: url, limits: limits)
            output("attachments: \(attachments.count) (\(attachments.map { "\($0.kind.rawValue) \($0.mimeType)" }.joined(separator: ", ")))")
            if let first = attachments.first, first.kind == .text { output("characters: \(first.text?.count ?? 0)") }
            if let extraction {
                output("document: \(extraction.kind.label)")
                if let pages = extraction.pageCount { output("pages: \(pages) (read \(extraction.pagesRead), with text \(extraction.textPages))") }
                output("pages read by OCR: \(extraction.ocrPages) (OCR attempts \(extraction.ocrAttempts))")
                output("page images: \(extraction.images.count) (skipped \(extraction.imagesSkipped))")
                output("copy-restricted: \(extraction.copyRestricted ? "yes" : "no")")
                output("summary: \(extraction.summary)")
            }
            output(String(format: "time: %.2f s", Date().timeIntervalSince(started)))
            return 0
        } catch {
            output("refused: \(error.localizedDescription)")
            return 1
        }
    }
}
