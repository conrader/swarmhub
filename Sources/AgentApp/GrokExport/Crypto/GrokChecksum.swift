import Foundation

/// Swift port of `cursor_checksum` in `scripts/grokbot_server.py` (`AA()` in main-app.cjs).
/// The timestamp is `floor(nowMs / 1e6)` taken as a signed 32-bit int; its six bytes
/// `[t>>8, t, t>>24, t>>16, t>>8, t]` (JS `>>` shift counts are mod 32) are XOR-chained from a seed,
/// base64url-encoded without padding, then the machine id is appended. A plain 64-bit shift is wrong.
enum GrokChecksum {
    static func header(machineID: String, nowMs: Int64) -> String {
        let t = Int32(truncatingIfNeeded: nowMs / GrokProtocol.checksumDivisor)
        var bytes: [UInt8] = [8, 0, 24, 16, 8, 0].map { shift in
            UInt8(truncatingIfNeeded: t >> Int32(shift % 32))
        }
        var prev = GrokProtocol.checksumSeed
        for i in bytes.indices {
            bytes[i] = (bytes[i] ^ prev) &+ UInt8(truncatingIfNeeded: i % 256)
            prev = bytes[i]
        }
        return base64URLNoPadding(bytes) + machineID
    }

    static func base64URLNoPadding(_ bytes: [UInt8]) -> String {
        var encoded = Data(bytes).base64EncodedString()
        encoded = encoded.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        while encoded.hasSuffix("=") { encoded.removeLast() }
        return encoded
    }
}
