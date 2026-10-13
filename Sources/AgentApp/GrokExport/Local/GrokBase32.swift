import Foundation

/// Grok Bot names each cache file `<unpadded lowercase RFC 4648 base32 of the slice key>.blob` (port of `decode_name`).
enum GrokBase32 {
    private static let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567".utf8)

    /// Decodes an unpadded lowercase stem. Lengths of 1, 3 or 6 mod 8 cannot come from whole bytes and reject the
    /// name, as does any character outside the alphabet (uppercase and `=` included) or bytes that are not UTF-8.
    static func decode(_ stem: String) -> String? {
        guard ![1, 3, 6].contains(stem.utf8.count % 8) else { return nil }
        var bits = 0, value = 0
        var out: [UInt8] = []
        out.reserveCapacity(stem.utf8.count * 5 / 8)
        for byte in stem.utf8 {
            guard let index = alphabet.firstIndex(of: byte) else { return nil }
            value = ((value << 5) | index) & 0xFFFF
            bits += 5
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((value >> bits) & 0xFF))
            }
        }
        return String(data: Data(out), encoding: .utf8)
    }

    /// The slice key for a cache file name, or nil for a non-`.blob` or undecodable name.
    static func sliceKey(forFileName name: String) -> String? {
        guard name.hasSuffix(GrokProtocol.blobExtension) else { return nil }
        return decode(String(name.dropLast(GrokProtocol.blobExtension.count)))
    }
}
