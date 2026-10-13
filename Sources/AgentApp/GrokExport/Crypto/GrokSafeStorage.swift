import CommonCrypto
import Foundation

enum GrokSafeStorageError: Error, Equatable, CustomStringConvertible {
    case notBase64
    case unsupportedVersion
    case badScopedValue
    case decryptFailed(Int32)
    case notUTF8
    case keyDerivationFailed(Int32)

    var description: String {
        switch self {
        case .notBase64: return "safeStorage value is not base64"
        case .unsupportedVersion: return "safeStorage value has an unknown version prefix"
        case .badScopedValue: return "scoped safeStorage value has an unexpected shape"
        case .decryptFailed(let status): return "safeStorage decrypt returned CommonCrypto status \(status)"
        case .notUTF8: return "safeStorage value did not decode to text"
        case .keyDerivationFailed(let status): return "safeStorage key derivation returned CommonCrypto status \(status)"
        }
    }
}

/// Swift port of `safe_storage_key` / `decrypt_safe_storage` in `scripts/grokbot_server.py`.
/// Electron `safeStorage` on macOS wraps a value as `base64("v10" + AES-128-CBC/PKCS7)`; the key is
/// `PBKDF2-HMAC-SHA1(keychain bytes verbatim, "saltysalt", 1003, 16)` and the IV is sixteen 0x20 bytes.
/// CryptoKit has neither PBKDF2 nor AES-CBC, so this uses CommonCrypto. Callers zero the password and key.
enum GrokSafeStorage {
    static func deriveKey(password: [UInt8]) throws -> [UInt8] {
        var key = [UInt8](repeating: 0, count: GrokProtocol.safeStorageKeyLength)
        let salt = GrokProtocol.safeStorageSalt
        let status = password.withUnsafeBufferPointer { pw in
            salt.withUnsafeBufferPointer { st in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    pw.baseAddress?.withMemoryRebound(to: CChar.self, capacity: pw.count) { $0 }, pw.count,
                    st.baseAddress, st.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                    GrokProtocol.safeStorageIterations,
                    &key, key.count)
            }
        }
        guard status == kCCSuccess else {
            Self.zero(&key)
            throw GrokSafeStorageError.keyDerivationFailed(status)
        }
        return key
    }

    /// Decrypts one safeStorage string, unwrapping the optional `scoped:v1:<scope>:<base64>` form first.
    /// Returns the plaintext bytes; the caller decides whether they are UTF-8 text (tokens) or raw.
    static func decrypt(_ value: String, key: [UInt8]) throws -> [UInt8] {
        var unwrapped = value
        if value.hasPrefix(GrokProtocol.scopedPrefix) {
            let parts = value.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
            guard parts.count == 4 else { throw GrokSafeStorageError.badScopedValue }
            unwrapped = String(parts[3])
        }
        guard let raw = Data(base64Encoded: unwrapped) else { throw GrokSafeStorageError.notBase64 }
        let prefix = GrokProtocol.safeStoragePrefix
        guard raw.count >= prefix.count, Array(raw.prefix(prefix.count)) == prefix else {
            throw GrokSafeStorageError.unsupportedVersion
        }
        return try decryptCBC(Array(raw.dropFirst(prefix.count)), key: key)
    }

    /// Decrypts and requires UTF-8 text — used for the three credential values.
    static func decryptText(_ value: String, key: [UInt8]) throws -> String {
        var bytes = try decrypt(value, key: key)
        defer { Self.zero(&bytes) }
        guard let text = String(bytes: bytes, encoding: .utf8) else { throw GrokSafeStorageError.notUTF8 }
        return text
    }

    private static func decryptCBC(_ cipher: [UInt8], key: [UInt8]) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: cipher.count + kCCBlockSizeAES128)
        var moved = 0
        let iv = GrokProtocol.safeStorageIV
        let status = cipher.withUnsafeBufferPointer { ci in
            key.withUnsafeBufferPointer { ky in
                iv.withUnsafeBufferPointer { vi in
                    CCCrypt(
                        CCOperation(kCCDecrypt),
                        CCAlgorithm(kCCAlgorithmAES128),
                        CCOptions(kCCOptionPKCS7Padding),
                        ky.baseAddress, ky.count,
                        vi.baseAddress,
                        ci.baseAddress, ci.count,
                        &out, out.count, &moved)
                }
            }
        }
        guard status == kCCSuccess else {
            Self.zero(&out)
            throw GrokSafeStorageError.decryptFailed(status)
        }
        let result = Array(out[0..<moved])
        Self.zero(&out)
        return result
    }

    /// Best-effort overwrite of a byte buffer (Rule 6: Swift strings cannot be zeroed, but byte arrays can be).
    static func zero(_ bytes: inout [UInt8]) {
        for index in bytes.indices { bytes[index] = 0 }
    }
}
