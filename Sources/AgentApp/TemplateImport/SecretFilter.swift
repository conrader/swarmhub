import Foundation

/// The shared secret filter (ported from AgentApp's hardened `SecretFilter`): template import, the Grok import's bundles,
/// archives and personas, and tool activity all go through it. `scripts/export-grokbot.py` mirrors it pattern for
/// pattern. Scheme and prefix matching is case-insensitive (providers accept mixed case, so `akia…`, `GITHUB_PAT_…` and
/// `XAPP-…` must not walk past), and percent- or base64-encoded credentials are decoded before matching.
///
/// Every expression runs once over the text and replaces all its matches in one pass; nothing is rescanned after a
/// replacement, so a crafted, secret-dense text costs linear time (AgentApp rescanned per match: quadratic).
enum SecretFilter {
    static let secretKeys = [
        "token", "secret", "password", "passwd", "credential", "privatekey", "apikey", "authorization", "cookie",
        "auth", "bearer", "jwt", "passphrase", "pwd", "accesskey", "awsaccesskeyid", "sessionkey", "webhookurl", "dsn", "connectionstring"
    ]
    /// Substring matching on key names makes "author"/"authored_at" look like "auth"; attribution is not a credential.
    static let exemptKeys: Set<String> = ["author", "authorid", "authorname", "authorrole", "authortype", "authored", "authoredat", "authors"]
    /// Count keys for `secretValuePatterns`, in order. `basic_auth` and `encoded_credential` count the decoded passes.
    static let categories = [
        "private_key", "bearer", "vendor_token", "github_pat", "jwt", "aws_key", "google_key", "slack_app_token",
        "slack_webhook", "url_credentials", "credential_assignment",
    ]
    static let secretValuePatterns = [
        #"(?si)-----BEGIN ([A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?)-----.*?(?:-----END \1-----[^\r\n]*(?:\r?\n|\z)|\z)"#,
        #"(?i)\b(bearer\s+)[A-Za-z0-9._~+/=-]{8,}"#,
        #"(?i)\b(sk|xox[baprs]|gh[pousr])[-_][A-Za-z0-9_-]{12,}\b"#,
        #"(?i)github_pat_[A-Za-z0-9_-]{8,}"#,
        // Starts only where a dot-separated part starts and commits to the first `eyJ` in it (the lookahead is atomic), so
        // a run of `eyJ`/`-eyJ` pieces is scanned once, yet any `eyJ` in the part counts: a header holding `-eyJ` still
        // matches. The rest of the dotted run goes too, so a JWT chained after a JWT-shaped run is not left behind.
        #"(?i)(?<![A-Za-z0-9_-])(?=([A-Za-z0-9_-]*?eyJ[A-Za-z0-9_-]{8}))\1[A-Za-z0-9_-]*\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}(?:\.[A-Za-z0-9_-]+)*"#,
        #"(?i)\b(?:AKIA|ASIA|AGPA|AIDA|AIPA|AROA|ANPA|ANVA|ABIA|ACCA)[0-9A-Za-z]{16}\b"#,
        #"(?i)\bAIza[0-9A-Za-z_-]{35}"#,
        #"(?i)\bxapp-[A-Za-z0-9_-]{8,}"#,
        #"(?i)https?://hooks\.slack\.com/services/\S+"#,
        #"://[^/\s:@]+:[^/\s@]+@"#,
        #"(?i)(?<![A-Za-z0-9])(api[_ -]?key|token|secret|password|credential|auth[_-]?token|access[_-]?token|client[_-]?secret|authorization)\s*[:=]\s*\S+"#
    ]
    // The patterns are constants covered by tests; a failure here is a programming error.
    private static let expressions = secretValuePatterns.map { try! NSRegularExpression(pattern: $0) }
    private static let jwt = expressions[categories.firstIndex(of: "jwt")!]
    private static let basic = try! NSRegularExpression(pattern: #"(?i)\bBasic\s+([A-Za-z0-9+/]{4,}={0,2})(?![A-Za-z0-9+/=])"#)
    /// A whole token holding a `%XX` escape. It starts at a token start: `\S*` tried from every offset is quadratic.
    private static let percentCandidate = try! NSRegularExpression(pattern: #"(?<!\S)\S*%[0-9A-Fa-f]{2}\S*"#)
    /// A tightly bounded base64 blob; redacted only when it decodes to printable, credential-shaped text.
    private static let base64Candidate = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9+/=_-])[A-Za-z0-9+/_-]{20,1024}={0,2}(?![A-Za-z0-9+/=_-])"#)
    private static let credentialPair = try! NSRegularExpression(pattern: #"^[^\s:]{3,64}:[^\s:]{3,64}$"#)

    static func isSecretKey(_ key: String) -> Bool {
        let normalized = normalize(key)
        guard !exemptKeys.contains(normalized) else { return false }
        return secretKeys.contains { normalized.contains(normalize($0)) }
    }

    /// JWTs, then Basic credentials, then encoded candidates, then every other `secretValuePatterns` hit, each replaced by
    /// `replacement`; `counts` gains one per replacement under its category. JWTs go first: a JWT part on its own can
    /// decode credential-shaped (`{"alg":"HS256"}` has a colon), and the encoded pass would take that part alone and
    /// leave the signature behind.
    static func redact(_ text: String, replacement: String = "[removed]", counts: inout [String: Int]) -> String {
        guard !text.isEmpty else { return text }
        func pass(_ category: String, _ expression: NSRegularExpression, _ text: String,
                  where isSecret: (NSTextCheckingResult, NSString) -> Bool = { _, _ in true }) -> String {
            let (result, count) = replacingMatches(of: expression, in: text, with: replacement, where: isSecret)
            if count > 0 { counts[category, default: 0] += count }
            return result
        }
        var text = pass("jwt", jwt, text)
        text = pass("basic_auth", basic, text) { match, source in
            guard let decoded = Data(base64Encoded: source.substring(with: match.range(at: 1))) else { return false }
            return String(data: decoded, encoding: .utf8)?.contains(":") == true
        }
        if text.contains("%") {
            text = pass("encoded_credential", percentCandidate, text) { match, source in
                decodedPercentEncoding(source.substring(with: match.range)).map(isCredentialShaped) ?? false
            }
        }
        text = pass("encoded_credential", base64Candidate, text) { match, source in
            decodedBase64(source.substring(with: match.range)).map(isCredentialShaped) ?? false
        }
        for (category, expression) in zip(categories, expressions) where category != "jwt" { text = pass(category, expression, text) }
        return text
    }

    static func redact(_ text: String, replacement: String = "[removed]") -> (text: String, count: Int) {
        var counts: [String: Int] = [:]
        let result = redact(text, replacement: replacement, counts: &counts)
        return (result, counts.values.reduce(0, +))
    }

    static func redacted(_ text: String, replacement: String = "[removed]") -> String { redact(text, replacement: replacement).text }

    /// Drops secret-named keys and filters every string, counting both.
    static func sanitize(_ value: Any, key: String? = nil, rejected: inout Int) -> Any? {
        if let key, isSecretKey(key) { rejected += 1; return nil }
        if let text = value as? String {
            let result = redact(text)
            rejected += result.count
            return result.text
        }
        if let object = value as? [String: Any] {
            var clean: [String: Any] = [:]
            for (childKey, childValue) in object { if let sanitized = sanitize(childValue, key: childKey, rejected: &rejected) { clean[childKey] = sanitized } }
            return clean
        }
        if let array = value as? [Any] { return array.compactMap { sanitize($0, rejected: &rejected) } }
        return value
    }

    /// True for `user:pass` payloads and for anything the literal patterns already reject.
    static func isCredentialShaped(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        if credentialPair.firstMatch(in: trimmed, range: range) != nil { return true }
        return expressions.contains { $0.firstMatch(in: trimmed, range: range) != nil }
    }

    static func normalize(_ value: String) -> String { value.lowercased().filter(\.isLetter) }

    /// All matches in one left-to-right pass: the text between them is copied once and nothing is rescanned, so the
    /// cost is linear however many matches there are. A match `isSecret` rejects keeps its text.
    private static func replacingMatches(of expression: NSRegularExpression, in text: String, with replacement: String,
                                         where isSecret: (NSTextCheckingResult, NSString) -> Bool) -> (String, Int) {
        let source = text as NSString
        var result = "", cursor = 0, count = 0
        for match in expression.matches(in: text, range: NSRange(location: 0, length: source.length))
        where match.range.length > 0 && isSecret(match, source) {
            result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor)) + replacement
            cursor = NSMaxRange(match.range); count += 1
        }
        guard count > 0 else { return (text, 0) }
        return (result + source.substring(from: cursor), count)
    }

    private static func decodedBase64(_ candidate: String) -> String? {
        let stripped = candidate.replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard (20...1024).contains(stripped.count), stripped.count % 4 != 1,
              let data = Data(base64Encoded: stripped + String(repeating: "=", count: (4 - stripped.count % 4) % 4)),
              let decoded = String(data: data, encoding: .utf8), isPrintable(decoded) else { return nil }
        return decoded
    }

    private static func decodedPercentEncoding(_ candidate: String) -> String? {
        guard let decoded = candidate.removingPercentEncoding, decoded != candidate, isPrintable(decoded) else { return nil }
        return decoded
    }

    private static func isPrintable(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { $0.value == 9 || ($0.value >= 0x20 && $0.value != 0x7F) }
    }
}
