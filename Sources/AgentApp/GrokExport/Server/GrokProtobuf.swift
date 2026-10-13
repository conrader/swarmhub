import Foundation

enum GrokProtobufError: Error, Equatable, CustomStringConvertible {
    case truncatedVarint
    case varintOverflow
    case truncatedField
    case unsupportedWireType(Int)
    case lengthOverflow

    var description: String {
        switch self {
        case .truncatedVarint: return "truncated protobuf varint"
        case .varintOverflow: return "protobuf varint overflow"
        case .truncatedField: return "truncated protobuf field"
        case .unsupportedWireType(let w): return "unsupported protobuf wire type \(w)"
        case .lengthOverflow: return "protobuf length-delimited field overruns the message"
        }
    }
}

/// The slice of protobuf wire format these two messages use (port of the `_varint`/`parse_message`/encoders in
/// `scripts/grokbot_server.py`). Bounds-checked, first occurrence of a field wins, only wire types 0/1/2/5.
/// A decode failure is `GrokProtobufError`, which the RPC layer turns into `protocolChanged`.
enum GrokProtobuf {
    enum Value: Equatable {
        case varint(UInt64)
        case bytes([UInt8])
        case fixed64([UInt8])
        case fixed32([UInt8])
    }

    // MARK: Encoding

    static func varint(_ value: UInt64) -> [UInt8] {
        var v = value
        var out: [UInt8] = []
        repeat {
            let byte = UInt8(v & 0x7F)
            v >>= 7
            out.append(v != 0 ? byte | 0x80 : byte)
        } while v != 0
        return out
    }

    static func key(_ field: Int, _ wire: Int) -> [UInt8] { varint(UInt64(field << 3 | wire)) }

    static func bytesField(_ field: Int, _ data: [UInt8]) -> [UInt8] {
        key(field, 2) + varint(UInt64(data.count)) + data
    }

    static func varintField(_ field: Int, _ value: UInt64) -> [UInt8] { key(field, 0) + varint(value) }

    // MARK: Decoding

    static func readVarint(_ data: [UInt8], _ pos: inout Int) throws -> UInt64 {
        var shift: UInt64 = 0
        var value: UInt64 = 0
        while true {
            guard pos < data.count else { throw GrokProtobufError.truncatedVarint }
            let byte = data[pos]
            pos += 1
            if shift >= 64 { throw GrokProtobufError.varintOverflow }
            value |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
    }

    /// Wire-level decode: {field: [Value, ...]} in the order seen.
    static func parse(_ data: [UInt8]) throws -> [Int: [Value]] {
        var fields: [Int: [Value]] = [:]
        var pos = 0
        while pos < data.count {
            let tag = try readVarint(data, &pos)
            let field = Int(tag >> 3)
            let wire = Int(tag & 7)
            let value: Value
            switch wire {
            case 0:
                value = .varint(try readVarint(data, &pos))
            case 2:
                let size = Int(try readVarint(data, &pos))
                guard size >= 0, pos + size <= data.count, size <= data.count else { throw GrokProtobufError.lengthOverflow }
                value = .bytes(Array(data[pos..<pos + size]))
                pos += size
            case 1:
                guard pos + 8 <= data.count else { throw GrokProtobufError.truncatedField }
                value = .fixed64(Array(data[pos..<pos + 8]))
                pos += 8
            case 5:
                guard pos + 4 <= data.count else { throw GrokProtobufError.truncatedField }
                value = .fixed32(Array(data[pos..<pos + 4]))
                pos += 4
            default:
                throw GrokProtobufError.unsupportedWireType(wire)
            }
            fields[field, default: []].append(value)
        }
        return fields
    }

    // MARK: ListGrokBotTranscriptEntries

    static func encodeListRequest(agentID: String, limit: UInt32, beforeSeq: Int64? = nil, sessionID: String = "") -> [UInt8] {
        var out = bytesField(1, Array(agentID.utf8))
        if let beforeSeq { out += varintField(3, UInt64(beforeSeq)) }
        out += varintField(4, UInt64(limit))
        if !sessionID.isEmpty { out += bytesField(5, Array(sessionID.utf8)) }
        return out
    }

    /// One response row (GrokBotTranscriptEntry). First occurrence of each field wins.
    struct TranscriptRow: Equatable {
        var seq: Int64
        var entryKind: String
        var body: [UInt8]?
        var blobHash: String?
        var entryID: String?
        var bodyOmitted: Bool
    }

    static func decodeListResponse(_ data: [UInt8]) throws -> [TranscriptRow] {
        let top = try parse(data)
        var rows: [TranscriptRow] = []
        for case .bytes(let raw) in top[1] ?? [] {
            let f = try parse(raw)
            rows.append(TranscriptRow(
                seq: Int64(bitPattern: firstVarint(f, 1) ?? 0),
                entryKind: firstBytes(f, 2).flatMap { String(bytes: $0, encoding: .utf8) } ?? "",
                body: firstBytes(f, 3),
                blobHash: firstBytes(f, 4).flatMap { String(bytes: $0, encoding: .utf8) },
                entryID: firstBytes(f, 6).flatMap { String(bytes: $0, encoding: .utf8) },
                bodyOmitted: (firstVarint(f, 7) ?? 0) != 0))
        }
        return rows
    }

    // MARK: PresignSandBoxStoreReads

    static func encodePresignRequest(relPaths: [String]) -> [UInt8] {
        relPaths.flatMap { bytesField(1, Array($0.utf8)) }
    }

    /// PresignSandBoxStoreReadsResponse.instructions -> [relPath: url].
    static func decodePresignResponse(_ data: [UInt8]) throws -> [String: String] {
        let top = try parse(data)
        var out: [String: String] = [:]
        for case .bytes(let raw) in top[1] ?? [] {
            let f = try parse(raw)
            if let path = firstBytes(f, 1).flatMap({ String(bytes: $0, encoding: .utf8) }),
               let url = firstBytes(f, 2).flatMap({ String(bytes: $0, encoding: .utf8) }) {
                out[path] = url
            }
        }
        return out
    }

    // MARK: Field helpers (first occurrence wins)

    private static func firstVarint(_ fields: [Int: [Value]], _ field: Int) -> UInt64? {
        if case .varint(let v)? = fields[field]?.first { return v }
        return nil
    }

    private static func firstBytes(_ fields: [Int: [Value]], _ field: Int) -> [UInt8]? {
        if case .bytes(let b)? = fields[field]?.first { return b }
        return nil
    }
}
