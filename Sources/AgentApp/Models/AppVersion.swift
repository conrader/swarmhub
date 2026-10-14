import Foundation

/// `1.2.3`, `v1.2`, `0.4.0-beta.1`: numeric parts compared left to right (missing parts are 0); a
/// pre-release sorts before the same release. Build metadata after `+` is ignored.
struct SemanticVersion: Comparable, Sendable, CustomStringConvertible {
    let parts: [Int]
    let prerelease: String?

    init?(_ text: String) {
        var value = text.trimmingCharacters(in: .whitespaces)
        if value.first == "v" || value.first == "V" { value.removeFirst() }
        if let plus = value.firstIndex(of: "+") { value = String(value[..<plus]) }
        let split = value.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard let core = split.first, !core.isEmpty else { return nil }
        let numbers = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !numbers.isEmpty, numbers.count <= 4, numbers.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
        parts = numbers.compactMap { $0 }
        prerelease = split.count == 2 ? String(split[1]) : nil
    }

    var description: String { parts.map(String.init).joined(separator: ".") + (prerelease.map { "-\($0)" } ?? "") }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        for index in 0..<max(lhs.parts.count, rhs.parts.count) {
            let left = index < lhs.parts.count ? lhs.parts[index] : 0, right = index < rhs.parts.count ? rhs.parts[index] : 0
            if left != right { return left < right }
        }
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, _): return false
        case (_, nil): return true
        case let (left?, right?): return left.compare(right, options: .numeric) == .orderedAscending
        }
    }
    static func == (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool { !(lhs < rhs) && !(rhs < lhs) }
}

/// The running app's version (Info.plist) and the source commit `package-release.sh` writes into
/// `Contents/Resources/SOURCE.txt` (`source_sha=…`, `dirty=…`). A bare SwiftPM binary has neither.
struct AppBuildInfo: Equatable, Sendable {
    var version: String
    var build: String?
    var sourceSHA: String?
    var dirty = false

    var shortSHA: String? { sourceSHA.map { String($0.prefix(12)) } }
    var summary: String {
        var text = version + (build.map { " (\($0))" } ?? "")
        if let shortSHA { text += " · \(shortSHA)\(dirty ? "-dirty" : "")" }
        return text
    }

    static func current(bundle: Bundle = .main) -> AppBuildInfo {
        let info = bundle.infoDictionary ?? [:]
        let source = bundle.url(forResource: "SOURCE", withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        return make(version: info["CFBundleShortVersionString"] as? String, build: info["CFBundleVersion"] as? String, sourceText: source)
    }

    static func make(version: String?, build: String?, sourceText: String) -> AppBuildInfo {
        var fields: [String: String] = [:]
        for line in sourceText.split(whereSeparator: \.isNewline) {
            let pair = line.split(separator: "=", maxSplits: 1)
            if pair.count == 2 { fields[String(pair[0])] = String(pair[1]) }
        }
        let sha = fields["source_sha"].flatMap { $0.allSatisfy(\.isHexDigit) && !$0.isEmpty ? $0 : nil }
        return AppBuildInfo(version: version ?? "development build", build: build, sourceSHA: sha, dirty: fields["dirty"] == "true")
    }
}

struct ReleaseInfo: Equatable, Sendable {
    var tag: String
    var name: String?
    /// Only an https github.com page is kept, so the link can open nothing else.
    var pageURL: URL?

    static func parse(_ json: [String: Any]) -> ReleaseInfo? {
        guard let tag = json["tag_name"] as? String, !tag.isEmpty else { return nil }
        let page = (json["html_url"] as? String).flatMap(URL.init(string:)).flatMap { $0.scheme == "https" && $0.host?.lowercased() == "github.com" ? $0 : nil }
        return ReleaseInfo(tag: tag, name: (json["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }, pageURL: page)
    }
}

enum UpdateStatus: Equatable, Sendable {
    case newer(ReleaseInfo), upToDate(String), noReleases, unknownVersion(String), failed(String)

    static func evaluate(current: String, latest: ReleaseInfo?) -> UpdateStatus {
        guard let latest else { return .noReleases }
        guard let mine = SemanticVersion(current), let theirs = SemanticVersion(latest.tag) else { return .unknownVersion(latest.tag) }
        return theirs > mine ? .newer(latest) : .upToDate(latest.tag)
    }

    var message: String {
        switch self {
        case .newer(let release): "\(release.tag) is available."
        case .upToDate(let tag): "You’re up to date (latest release \(tag))."
        case .noReleases: "No releases have been published yet."
        case .unknownVersion(let tag): "Latest release is \(tag); it could not be compared with this version."
        case .failed(let reason): "Could not check: \(reason)"
        }
    }
}

/// On-demand check of `GET https://api.github.com/repos/<AppConstants.releasesRepo>/releases/latest`, falling back to the
/// pre-rename repo on 404 (GitHub also redirects the old name after the rename). Nothing is downloaded.
enum ReleaseChecker {
    static let latestURLs = [AppConstants.releasesRepo, AppConstants.previousReleasesRepo].map { URL(string: "https://api.github.com/repos/\($0)/releases/latest")! }

    static func check(current: String, session: URLSession = TestRunGuard.sharedSession, urls: [URL] = latestURLs) async -> UpdateStatus {
        for url in urls {
            var request = URLRequest(url: url, timeoutInterval: 15)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue(AppConstants.userAgent(version: GrokRequestHeaders.appVersion(fromShortVersion: current)), forHTTPHeaderField: "User-Agent")
            let status = await fetch(request, current: current, session: session)
            if status != .noReleases { return status }
        }
        return .noReleases
    }

    private static func fetch(_ request: URLRequest, current: String, session: URLSession) async -> UpdateStatus {
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 404 { return .noReleases }
            guard (200..<300).contains(status) else { return .failed("GitHub answered HTTP \(status).") }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], let release = ReleaseInfo.parse(json) else { return .failed("GitHub returned an unexpected answer.") }
            return .evaluate(current: current, latest: release)
        } catch { return .failed(error.localizedDescription) }
    }
}
