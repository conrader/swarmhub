import Foundation

public struct SSEFrame: Equatable, Sendable {
    public let event: String
    public let data: String
    public let id: String?
}

/// Dispatch on a blank line, retaining multiple data lines and ignoring comments.
public struct SSEDecoder: Sendable {
    private var name = "message"
    private var lines: [String] = []
    private var id: String?
    private var size = 0
    public init() {}

    public mutating func consume(_ line: String) throws -> SSEFrame? {
        if line.isEmpty {
            defer { name = "message"; lines = []; size = 0 }
            guard !lines.isEmpty else { return nil }
            return SSEFrame(event: name, data: lines.joined(separator: "\n"), id: id)
        }
        size += line.utf8.count
        guard size <= 1_048_576 else { throw CoreError.invalidResponse }
        if line.hasPrefix(":") { return nil }
        let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        var value = parts.count > 1 ? String(parts[1]) : ""
        if value.hasPrefix(" ") { value.removeFirst() }
        switch parts[0] {
        case "event": name = value
        case "data": lines.append(value)
        case "id": if !value.contains("\0") { id = value }
        default: break
        }
        return nil
    }
}

/// Foundation's AsyncBytes.lines can discard empty lines. SSE needs those event boundaries.
public struct SSEByteDecoder: Sendable {
    private var line: [UInt8] = []
    private var frames = SSEDecoder()
    private var firstLine = true
    public init() {}
    public mutating func consume(_ byte: UInt8) throws -> SSEFrame? {
        guard byte == 10 else {
            guard line.count < 1_048_576 else { throw CoreError.invalidResponse }
            line.append(byte); return nil
        }
        if line.last == 13 { line.removeLast() }
        guard var text = String(bytes: line, encoding: .utf8) else { throw CoreError.invalidResponse }
        line.removeAll(keepingCapacity: true)
        if firstLine { firstLine = false; if text.hasPrefix("\u{FEFF}") { text.removeFirst() } }
        return try frames.consume(text)
    }
}
