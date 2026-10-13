import CommonCrypto
import Foundation

enum GrokCredentialsError: Error, Equatable, CustomStringConvertible {
    case secretsUnreadable
    case noSignedInAccount
    case tokenShapeInvalid
    case tokenExpired
    case accountMismatch

    var description: String {
        switch self {
        case .secretsUnreadable: return "sand-secrets.json could not be read"
        case .noSignedInAccount: return "no signed-in Grok Bot account in sand-secrets.json"
        case .tokenShapeInvalid: return "the decrypted sign-in is not the expected shape"
        case .tokenExpired: return "the Grok Bot sign-in has expired"
        case .accountMismatch: return "the signed-in account does not match the cache's account slot"
        }
    }
}

/// The structure of `sand-secrets.json`, parsed without decrypting anything (harness step c, and preflight).
/// Mirrors `read_credentials` in `scripts/grokbot_server.py`: `cursor-accounts` is a JSON *string*.
struct GrokSecretsFile: Sendable {
    /// The active account's still-encrypted values, plus the machine id and the active account id.
    struct EncryptedAccount: Sendable {
        let activeAccountID: String
        let accessToken: String
        let teamID: String?
        let machineID: String?
    }

    let hasAccountsString: Bool
    let activeAccountID: String?
    let accountIDs: [String]
    let hasMachineID: Bool

    /// Parses the file structure only; throws nothing secret.
    static func parse(data: Data) throws -> GrokSecretsFile {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GrokCredentialsError.secretsUnreadable
        }
        let accountsString = root[GrokProtocol.accountsKey] as? String
        var active: String?
        var ids: [String] = []
        if let accountsString, let accountsData = accountsString.data(using: .utf8),
           let accounts = try? JSONSerialization.jsonObject(with: accountsData) as? [String: Any] {
            active = accounts[GrokProtocol.activeKey] as? String
            ids = ((accounts[GrokProtocol.accountsMapKey] as? [String: Any])?.keys).map(Array.init) ?? []
        }
        return GrokSecretsFile(
            hasAccountsString: accountsString != nil,
            activeAccountID: active,
            accountIDs: ids.sorted(),
            hasMachineID: root[GrokProtocol.machineIDKey] is String)
    }

    /// Pulls the active account's three encrypted values (still ciphertext). No decryption here.
    static func encryptedAccount(data: Data) throws -> EncryptedAccount {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accountsString = root[GrokProtocol.accountsKey] as? String,
              let accountsData = accountsString.data(using: .utf8),
              let accounts = try? JSONSerialization.jsonObject(with: accountsData) as? [String: Any],
              let active = accounts[GrokProtocol.activeKey] as? String,
              let map = accounts[GrokProtocol.accountsMapKey] as? [String: Any],
              let account = map[active] as? [String: Any],
              let token = account[GrokProtocol.accessTokenKey] as? String, !token.isEmpty
        else { throw GrokCredentialsError.noSignedInAccount }
        return EncryptedAccount(
            activeAccountID: active,
            accessToken: token,
            teamID: account[GrokProtocol.teamIDKey] as? String,
            machineID: root[GrokProtocol.machineIDKey] as? String)
    }
}

/// The three decrypted, shape-checked credential values the private RPCs need (port of `read_credentials`).
/// Decrypt exactly the access token, machine id and team id — never the refresh token, exec-file key or profile.
struct GrokCredentials: Sendable {
    let token: SecretBytes
    let machineID: SecretBytes
    let teamID: String?

    /// Decrypts the three values with the derived key and runs the shape checks. The key is the caller's to zero.
    /// A wrong key passes PKCS7 padding ~0.4 % of the time, so the token must also be UTF-8 and three base64url
    /// segments (`decryptText` enforces UTF-8; `tokenSegmentsValid` the rest).
    static func decrypt(from encrypted: GrokSecretsFile.EncryptedAccount, key: [UInt8], now: Date) throws -> GrokCredentials {
        let token = try GrokSafeStorage.decryptText(encrypted.accessToken, key: key)
        guard tokenSegmentsValid(token) else { throw GrokCredentialsError.tokenShapeInvalid }
        guard !tokenExpired(token, now: now) else { throw GrokCredentialsError.tokenExpired }

        var machineID = ""
        if let encryptedMachineID = encrypted.machineID {
            let decrypted = try GrokSafeStorage.decryptText(encryptedMachineID, key: key)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if (1...GrokProtocol.machineIDMaxLength).contains(decrypted.count) { machineID = decrypted }
        }

        // The team id is optional (Konrad's account has none selected, docs/P10-spike-findings.md carry 2): absent,
        // empty, undecryptable or non-numeric all mean "no team header", never a failed sign-in.
        var teamID: String?
        if let encryptedTeam = encrypted.teamID, !encryptedTeam.isEmpty,
           let decrypted = try? GrokSafeStorage.decryptText(encryptedTeam, key: key).trimmingCharacters(in: .whitespacesAndNewlines),
           let numeric = Int(decrypted), numeric > 0 {
            teamID = decrypted
        }
        return GrokCredentials(token: SecretBytes(token), machineID: SecretBytes(machineID), teamID: teamID)
    }

    /// The token must be three non-empty base64url segments (a JWT shape). Not a full signature check.
    static func tokenSegmentsValid(_ token: String) -> Bool {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3 else { return false }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        return segments.allSatisfy { !$0.isEmpty && CharacterSet(charactersIn: String($0)).isSubset(of: allowed) }
    }

    /// Reads `exp` (seconds) from the JWT payload; a non-JWT or missing/garbled `exp` is treated as not expired,
    /// matching `token_expired`. The pipeline additionally requires a 60 s margin (`exp` more than now+60).
    static func tokenExpired(_ token: String, now: Date, margin: TimeInterval = 0) -> Bool {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, let payload = base64URLDecode(String(parts[1])),
              let claims = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let exp = claims["exp"] as? Double
        else { return false }
        return exp <= now.timeIntervalSince1970 + margin
    }

    /// The cache's account slot value (percent-encoded) hashes to the active account id (lowercase hex SHA-256).
    /// With no slot blob the binding cannot be checked, which is not a failure (the caller allows it).
    static func accountBindingHolds(activeAccountID: String, accountSlotValue: String) -> Bool {
        sha256Hex(Array(accountSlotValue.utf8)) == activeAccountID.lowercased()
    }

    static func base64URLDecode(_ string: String) -> Data? {
        var s = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s)
    }

    static func sha256Hex(_ bytes: [UInt8]) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        bytes.withUnsafeBufferPointer { _ = CC_SHA256($0.baseAddress, CC_LONG($0.count), &digest) }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
