import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum AttachmentError: LocalizedError, Equatable {
    case unsupported(String), tooLarge(String, String), unreadable(String)
    var errorDescription: String? {
        switch self {
        case .unsupported(let name): "Can’t attach “\(name)”: only PNG, JPEG, GIF and WebP images and text files up to 200 KB can be sent."
        case .tooLarge(let name, let limit): "Can’t attach “\(name)”: it is larger than \(limit)."
        case .unreadable(let name): "Can’t read “\(name)”."
        }
    }
}

/// Turns picked, dropped or pasted files into message attachments. Images become `data:image/...`
/// parts (long edge ≤ 2048 px, data URL ≤ 5 MB); text files ≤ 200 KB are sent inline as a fenced block.
struct AttachmentEncoder {
    static let maxImageEdge = 2048
    static let maxImageDataURLBytes = 5 * 1024 * 1024
    static let maxTextBytes = 200 * 1024
    /// ImageIO type identifiers Hermes can take as image parts, with their MIME types.
    static let imageTypes: [String: String] = ["public.png": "image/png", "public.jpeg": "image/jpeg", "com.compuserve.gif": "image/gif", "org.webmproject.webp": "image/webp"]

    let directory: URL

    func prepare(fileURL: URL) throws -> ChatAttachment {
        let name = fileURL.lastPathComponent
        let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey])
        let type = UTType(filenameExtension: fileURL.pathExtension)
        if type?.conforms(to: .image) == true {
            guard (values?.fileSize ?? 0) <= 64 * 1024 * 1024, let data = try? Data(contentsOf: fileURL) else { throw AttachmentError.unreadable(name) }
            return try prepare(imageData: data, name: name)
        }
        if let size = values?.fileSize, size > Self.maxTextBytes {
            throw type?.conforms(to: .text) == true || type == nil ? AttachmentError.tooLarge(name, "200 KB") : AttachmentError.unsupported(name)
        }
        guard let data = try? Data(contentsOf: fileURL) else { throw AttachmentError.unreadable(name) }
        if CGImageSourceCreateWithData(data as CFData, nil).flatMap(CGImageSourceGetType) != nil { return try prepare(imageData: data, name: name) }
        let text = try Self.textContent(data, name: name)
        return ChatAttachment(id: UUID(), kind: .text, name: name, mimeType: type?.preferredMIMEType ?? "text/plain", byteCount: data.count, text: text)
    }

    func prepare(imageData: Data, name: String) throws -> ChatAttachment {
        let encoded = try Self.encodeImage(imageData, name: name)
        let id = UUID(); let fileName = "\(id.uuidString.lowercased()).\(encoded.mime.split(separator: "/").last ?? "img")"
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoded.data.write(to: directory.appending(path: fileName), options: .atomic)
        return ChatAttachment(id: id, kind: .image, name: name, mimeType: encoded.mime, byteCount: encoded.data.count, fileName: fileName)
    }

    func fileURL(for attachment: ChatAttachment) -> URL? { attachment.fileName.map { directory.appending(path: $0) } }

    func dataURL(for attachment: ChatAttachment) throws -> String {
        guard attachment.kind == .image, let url = fileURL(for: attachment), let data = try? Data(contentsOf: url) else { throw AttachmentError.unreadable(attachment.name) }
        return Self.dataURL(mime: attachment.mimeType, data: data)
    }

    static func dataURL(mime: String, data: Data) -> String { "data:\(mime);base64,\(data.base64EncodedString())" }
    static func dataURLLength(mime: String, byteCount: Int) -> Int { "data:\(mime);base64,".utf8.count + (byteCount + 2) / 3 * 4 }

    static func textContent(_ data: Data, name: String) throws -> String {
        guard data.count <= maxTextBytes else { throw AttachmentError.tooLarge(name, "200 KB") }
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else { throw AttachmentError.unsupported(name) }
        return text
    }

    /// Passes a supported image through when it already fits; otherwise re-encodes it (PNG when it has
    /// alpha, else JPEG at falling quality), shrinking the long edge until the data URL fits `maxBytes`.
    static func encodeImage(_ data: Data, name: String = "image", maxEdge: Int = maxImageEdge, maxBytes: Int = maxImageDataURLBytes) throws -> (data: Data, mime: String) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let type = CGImageSourceGetType(source) as String?,
              let mime = imageTypes[type] else { throw AttachmentError.unsupported(name) }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0, height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        guard width > 0, height > 0 else { throw AttachmentError.unreadable(name) }
        let longEdge = max(width, height)
        if longEdge <= maxEdge, dataURLLength(mime: mime, byteCount: data.count) <= maxBytes { return (data, mime) }
        let hasAlpha = properties[kCGImagePropertyHasAlpha] as? Bool ?? false
        var edge = min(longEdge, maxEdge)
        while edge >= 256 {
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: edge]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw AttachmentError.unreadable(name) }
            let attempts: [(UTType, Double?)] = hasAlpha ? [(.png, nil)] : [(.jpeg, 0.85), (.jpeg, 0.7), (.jpeg, 0.5)]
            for (format, quality) in attempts {
                if let encoded = encode(image, as: format, quality: quality), dataURLLength(mime: format.preferredMIMEType!, byteCount: encoded.count) <= maxBytes {
                    return (encoded, format.preferredMIMEType!)
                }
            }
            edge = edge * 3 / 4
        }
        throw AttachmentError.tooLarge(name, "5 MB after encoding")
    }

    private static func encode(_ image: CGImage, as type: UTType, quality: Double?) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else { return nil }
        let options: [CFString: Any] = quality.map { [kCGImageDestinationLossyCompressionQuality: $0] } ?? [:]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    /// `File: name` followed by the text in a fence longer than any backtick run inside it.
    static func fencedBlock(name: String, text: String) -> String {
        var longest = 0, run = 0
        for character in text { run = character == "`" ? run + 1 : 0; longest = max(longest, run) }
        let fence = String(repeating: "`", count: max(3, longest + 1))
        return "File: \(name)\n\(fence)\n\(text.hasSuffix("\n") ? String(text.dropLast()) : text)\n\(fence)"
    }

    static func compose(text: String, attachments: [ChatAttachment]) -> String {
        let files = attachments.compactMap { attachment in attachment.text.map { fencedBlock(name: attachment.name, text: $0) } }
        guard !files.isEmpty else { return text }
        return ([text].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } + files).joined(separator: "\n\n")
    }
}
