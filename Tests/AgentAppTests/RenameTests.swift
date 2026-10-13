import Foundation
import Testing
@testable import AgentApp

// P18: the visible name comes from AppConstants.name; paths and prefixes written under the old name still work.

private let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

@Test func infoPlistNamesTheAppLikeTheConstant() throws {
    let plist = try #require(NSDictionary(contentsOf: repoRoot.appending(path: "Resources/Info.plist")) as? [String: Any])
    #expect(plist["CFBundleName"] as? String == AppConstants.name)
    #expect(plist["CFBundleDisplayName"] as? String == AppConstants.name)
    // Internal identity is unchanged, so settings, history and Keychain items carry over.
    #expect(plist["CFBundleIdentifier"] as? String == "com.konrad.agentapp" && plist["CFBundleExecutable"] as? String == "AgentApp")
}

/// Code with `//` and `/* */` comments removed; string literals (including `"https://…"`) are kept.
func strippingComments(_ source: String) -> String {
    var out = "", inString = false, inBlock = false, inLine = false
    var chars = Array(source)[...]
    while let c = chars.popFirst() {
        let next = chars.first
        if inLine { if c == "\n" { inLine = false; out.append(c) }; continue }
        if inBlock { if c == "*" && next == "/" { chars.removeFirst(); inBlock = false }; continue }
        if inString {
            out.append(c)
            if c == "\\", let escaped = chars.popFirst() { out.append(escaped) } else if c == "\"" || c == "\n" { inString = false }
            continue
        }
        if c == "/" && next == "/" { inLine = true; continue }
        if c == "/" && next == "*" { chars.removeFirst(); inBlock = true; continue }
        if c == "\"" { inString = true }
        out.append(c)
    }
    return out
}

@Test func noSourceFileNamesTheOldAppOutsideAppConstantsAndComments() throws {
    let old = AppConstants.previousName
    #expect(strippingComments("let a = 1 // \(old)\n/* \(old) */ let b = \"https://x/\(old)\"") == "let a = 1 \n let b = \"https://x/\(old)\"")
    let sources = repoRoot.appending(path: "Sources")
    let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)).compactMap { $0 as? URL }
        .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "AppConstants.swift" }
    #expect(files.count > 100)
    var offenders: [String] = []
    for file in files {
        // `LockOrigin.torvliDefault` is a stored raw value (store format unchanged), not a name the user sees.
        let code = strippingComments(try String(contentsOf: file, encoding: .utf8)).replacingOccurrences(of: "torvliDefault", with: "")
        for (number, line) in code.split(separator: "\n", omittingEmptySubsequences: false).enumerated() where line.range(of: old, options: .caseInsensitive) != nil {
            offenders.append("\(file.lastPathComponent):\(number + 1)")
        }
    }
    #expect(offenders.isEmpty, "the old name in code: \(offenders)")
}

@Test @MainActor func selfTestSessionsAreRecognisedUnderBothPrefixes() {
    #expect(AppConstants.selfTestPrefix == "\(AppConstants.name.lowercased())-selftest-")
    #expect(HeadlessE2E.namespace == AppConstants.selfTestPrefix)
    #expect(AppConstants.isSelfTestSession("\(AppConstants.selfTestPrefix)abc"))
    #expect(AppConstants.isSelfTestSession("\(AppConstants.previousName.lowercased())-selftest-abc"))
    #expect(!AppConstants.isSelfTestSession("grok-import-2026-10-13") && !AppConstants.isSelfTestSession("selftest-abc"))
}

@Test func grokExportFolderFallsBackToTheOldNameOnlyWhileTheNewOneIsMissing() throws {
    let home = FileManager.default.temporaryDirectory.appending(path: "rename-home-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: home) }
    let current = home.appending(path: "Documents/\(AppConstants.name) Grok Export", directoryHint: .isDirectory)
    let previous = home.appending(path: "Documents/\(AppConstants.previousName) Grok Export", directoryHint: .isDirectory)
    #expect(AppConstants.grokExportFolder(home: home).path == current.path)
    try FileManager.default.createDirectory(at: previous, withIntermediateDirectories: true)
    #expect(AppConstants.grokExportFolder(home: home).path == previous.path)
    try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
    #expect(AppConstants.grokExportFolder(home: home).path == current.path)
}

@Test func gitignoreCoversBothExportFolders() throws {
    let ignore = try String(contentsOf: repoRoot.appending(path: ".gitignore"), encoding: .utf8).split(separator: "\n").map(String.init)
    #expect(ignore.contains("\(AppConstants.name) Grok Export/") && ignore.contains("\(AppConstants.previousName) Grok Export/"))
}

@Test func userAgentsNameTheApp() {
    #expect(AppConstants.userAgent(version: "0.4.0") == "\(AppConstants.name)/0.4.0")
    #expect(GrokProtocol.userAgent(appVersion: "0.4.0") == AppConstants.userAgent(version: "0.4.0"))
}

// MARK: Updates across the repo rename

/// `ReleaseChecker.latestURLs` with the host swapped for the mock's, so the paths under test are the real ones.
private func mocked(_ urls: [URL], host: String) -> [URL] {
    urls.map { var parts = URLComponents(url: $0, resolvingAgainstBaseURL: false)!; parts.host = host; return parts.url! }
}
private func release() -> [String: Any] { ["tag_name": "v9.0.0", "html_url": "https://github.com/conrader/x/releases/tag/v9.0.0"] }

@Test func updatesUseTheNewRepoAndFallBackToTheOldOne() {
    #expect(ReleaseChecker.latestURLs.map(\.absoluteString) == [
        "https://api.github.com/repos/\(AppConstants.releasesRepo)/releases/latest",
        "https://api.github.com/repos/\(AppConstants.previousReleasesRepo)/releases/latest",
    ])
    #expect(AppConstants.releasesRepo == "conrader/\(AppConstants.name.lowercased())")
}

@Test func updatesWorkBeforeTheRepoRename() async {
    let newPath = "/repos/\(AppConstants.releasesRepo)/releases/latest", oldPath = "/repos/\(AppConstants.previousReleasesRepo)/releases/latest"
    let (host, session) = MockHermesProtocol.serve { request in request.url?.path == oldPath ? (200, release()) : (404, ["message": "Not Found"]) }
    let status = await ReleaseChecker.check(current: "0.4.0", session: session, urls: mocked(ReleaseChecker.latestURLs, host: host))
    guard case .newer(let info) = status else { Issue.record("got \(status)"); return }
    #expect(info.tag == "v9.0.0")
    let recorded = MockHermesProtocol.recorded(host)
    #expect(recorded.map { $0.url!.path } == [newPath, oldPath])
    #expect(recorded.allSatisfy { $0.value(forHTTPHeaderField: "User-Agent") == AppConstants.userAgent(version: "0.4.0") && $0.httpMethod == "GET" })
}

@Test func updatesWorkAfterTheRepoRenameIncludingTheOldNamesRedirect() async {
    let newPath = "/repos/\(AppConstants.releasesRepo)/releases/latest", oldPath = "/repos/\(AppConstants.previousReleasesRepo)/releases/latest"
    let (host, session) = MockHermesProtocol.serve { request in
        switch request.url?.path { case newPath: (200, release()); case oldPath: (301, ["location": newPath]); default: (404, ["message": "Not Found"]) }
    }
    let urls = mocked(ReleaseChecker.latestURLs, host: host)
    #expect(await ReleaseChecker.check(current: "0.4.0", session: session, urls: urls) == .newer(ReleaseInfo.parse(release())!))
    #expect(MockHermesProtocol.recorded(host).map { $0.url!.path } == [newPath], "the new name answers first")
    // An old link (a build from before P18) still lands on the release through GitHub's redirect.
    #expect(await ReleaseChecker.check(current: "0.4.0", session: session, urls: [urls[1]]) == .newer(ReleaseInfo.parse(release())!))
    #expect(MockHermesProtocol.recorded(host).map { $0.url!.path } == [newPath, oldPath, newPath])
}

@Test func updatesReportNoReleasesOnlyWhenNeitherRepoHasOne() async {
    let (host, session) = MockHermesProtocol.serve { _ in (404, ["message": "Not Found"]) }
    #expect(await ReleaseChecker.check(current: "0.4.0", session: session, urls: mocked(ReleaseChecker.latestURLs, host: host)) == .noReleases)
    #expect(MockHermesProtocol.recorded(host).count == 2)
}
