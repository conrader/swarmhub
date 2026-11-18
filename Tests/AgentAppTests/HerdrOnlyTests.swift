import Foundation
import Testing
@testable import AgentApp

private let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private func sources() throws -> [(name: String, text: String)] {
    let folder = repoRoot.appending(path: "Sources/AgentApp")
    let files = try #require(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" })
    return try files.map { ($0.path.replacingOccurrences(of: folder.path + "/", with: ""), try String(contentsOf: $0, encoding: .utf8)) }
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
