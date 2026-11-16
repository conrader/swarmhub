import Foundation
import Testing
@testable import AgentApp

// The app is Herdr only: its code names no backend that was removed, and its words for a server's secret are one.

private let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private func sources() throws -> [(name: String, text: String)] {
    let folder = repoRoot.appending(path: "Sources/AgentApp")
    let files = try #require(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" })
    return try files.map { ($0.path.replacingOccurrences(of: folder.path + "/", with: ""), try String(contentsOf: $0, encoding: .utf8)) }
}

/// The two backends that were removed are named in one place only: where a store an older build wrote is read
/// (`LegacyStore`), and where a bot's session id is read from the name it was saved under before.
@Test func theAppNamesNoRemovedBackend() throws {
    let all = try sources()
    #expect(all.count > 150)
    let allowed: [String: [String]] = ["Models/LegacyStore.swift": ["\"Hermes Agent\", \"OpenClaw\"", "hermesProfile", "hermesBaseURL", "hermesModelLock", "hermesSessionID", "openClaw"],
                                       "Models/Models.swift": ["hermesSessionID"]]
    for (name, text) in all {
        var rest = text
        for phrase in allowed[name] ?? [] { rest = rest.replacingOccurrences(of: phrase, with: "") }
        for word in ["hermes", "openclaw"] {
            #expect(!rest.localizedCaseInsensitiveContains(word), "\(name) says \(word)")
        }
    }
}

/// Settings says "access key" wherever a person reads the server's secret.
@Test func settingsSayAccessKey() throws {
    let all = try sources()
    for file in ["Views/HerdrSettingsSection.swift", "Views/HerdrServerFields.swift", "Views/HerdrSkillsViews.swift", "Views/HerdrHelperPolicySection.swift"] {
        let text = try #require(all.first { $0.name == file }?.text)
        #expect(!text.localizedCaseInsensitiveContains("access token"), "\(file) says access token")
    }
    #expect(!(HerdrClient.Failure.unauthorized.errorDescription ?? "").localizedCaseInsensitiveContains("token") && !HerdrBackend.missingToken.localizedCaseInsensitiveContains("token"))
}
