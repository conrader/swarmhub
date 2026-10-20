import Foundation
import Testing
@testable import AgentApp

// P2c: the bootstrap package's expected SHA-256 comes from the build's .sha256 file; export checks the bytes against it.

private let abc = Data("abc".utf8)
private let abcDigest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"  // FIPS 180-2 SHA-256("abc")
private let name = "swarmhub-updater-1.0.0.tar"

private func folder(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "AgentAppP2c-\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func bootstrap(package bytes: Data, line: String) throws -> URL {
    let dir = try folder("bootstrap")
    try bytes.write(to: dir.appending(path: name))
    try Data(line.utf8).write(to: dir.appending(path: name + ".sha256"))
    return dir
}

@Test func digestIsSHA256OfTheBytes() {
    #expect(BootstrapPackage.digest(of: abc) == abcDigest)
}

@Test func exportWritesBytesMatchingTheShownDigest() throws {
    let source = try bootstrap(package: abc, line: "\(abcDigest)  \(name)\n")
    let updaterPackage = try #require(BootstrapPackage.locate([source]))
    #expect(updaterPackage.expectedDigest == abcDigest)
    let actual = try updaterPackage.actualDigest()
    #expect(actual == updaterPackage.expectedDigest)
    let out = try folder("export")
    let written = try updaterPackage.export(to: out)
    #expect(written.lastPathComponent == name)
    let bytes = try Data(contentsOf: written)
    #expect(bytes == abc)
    #expect(BootstrapPackage.digest(of: bytes) == updaterPackage.expectedDigest)
    let sidecar = try String(contentsOf: out.appending(path: name + ".sha256"), encoding: .utf8)
    #expect(sidecar == "\(abcDigest)  \(name)\n")
}

@Test func alteredPackageIsNotExported() throws {
    let source = try bootstrap(package: Data("abd".utf8), line: "\(abcDigest)  \(name)\n")
    let updaterPackage = try #require(BootstrapPackage.locate([source]))
    let out = try folder("refused")
    #expect(throws: BootstrapPackage.ExportError.self) { try updaterPackage.export(to: out) }
    let left = try FileManager.default.contentsOfDirectory(atPath: out.path)
    #expect(left.isEmpty)
}

@Test(arguments: ["\(abcDigest.uppercased())  \(name)\n", "\(abcDigest)  other.tar\n", "\(abcDigest) \(name)\n", "\(abcDigest)  \(name)", "deadbeef  \(name)\n"])
func malformedDigestLinesAreRefused(line: String) throws {
    let source = try bootstrap(package: abc, line: line)
    #expect(BootstrapPackage.locate([source]) == nil)
}

@Test func buildWithoutPackageShowsNone() throws {
    let empty = try folder("empty")
    #expect(BootstrapPackage.locate([empty, URL(fileURLWithPath: "/nonexistent-p2c")]) == nil)
}

/// After `./scripts/build.sh` on the Mac: the package build.sh embedded matches the digest it recorded.
private let builtBootstrap: URL? = {
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    guard let bin = try? String(contentsOf: repo.appending(path: ".build/agentapp-bin-path"), encoding: .utf8) else { return nil }
    let url = URL(fileURLWithPath: bin.trimmingCharacters(in: .whitespacesAndNewlines)).appending(path: "AgentApp.resources/Bootstrap")
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
}()

@Test(.enabled(if: builtBootstrap != nil)) func builtPackageMatchesItsRecordedDigest() throws {
    let built = try #require(builtBootstrap)
    let updaterPackage = try #require(BootstrapPackage.locate([built]))
    let actual = try updaterPackage.actualDigest()
    #expect(actual == updaterPackage.expectedDigest)
}
