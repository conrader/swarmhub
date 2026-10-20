import Foundation
import Testing
@testable import AgentApp

private let abc = Data("abc".utf8)
private let abcDigest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
private let name = "swarmhub-updater-1.0.0.tar"

private func folder(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "AgentAppP2c-\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func appBundle(at root: URL, name: String = "SwarmHub.app") throws -> Bundle {
    let app = root.appending(path: name)
    try FileManager.default.createDirectory(at: app.appending(path: "Contents/Resources"), withIntermediateDirectories: true)
    let plist: [String: String] = ["CFBundleIdentifier": "test.p2c.\(UUID().uuidString)", "CFBundlePackageType": "APPL"]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: app.appending(path: "Contents/Info.plist"))
    return try #require(Bundle(url: app))
}

private func bootstrap(in directory: URL, package: Data = abc, line: String = "\(abcDigest)  \(name)\n") throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try package.write(to: directory.appending(path: name))
    try Data(line.utf8).write(to: directory.appending(path: name + ".sha256"))
}

@Test func digestIsSHA256OfTheBytes() {
    #expect(BootstrapPackage.digest(of: abc) == abcDigest)
}

@Test func exportWritesBytesMatchingTheShownDigest() throws {
    let root = try folder("export")
    defer { try? FileManager.default.removeItem(at: root) }
    let bundle = try appBundle(at: root)
    try bootstrap(in: #require(bundle.resourceURL).appending(path: "Bootstrap"))
    let package = try #require(BootstrapPackage.locate(in: bundle))
    #expect(package.expectedDigest == abcDigest)
    #expect(try package.actualDigest() == package.expectedDigest)
    let written = try package.export(to: root)
    #expect(try Data(contentsOf: written) == abc)
    #expect(try String(contentsOf: root.appending(path: name + ".sha256"), encoding: .utf8) == "\(abcDigest)  \(name)\n")
}

@Test func alteredPackageIsNeitherShownNorExported() throws {
    let root = try folder("altered")
    defer { try? FileManager.default.removeItem(at: root) }
    let bundle = try appBundle(at: root)
    let source = try #require(bundle.resourceURL).appending(path: "Bootstrap")
    try bootstrap(in: source)
    let package = try #require(BootstrapPackage.locate(in: bundle))
    try Data("abd".utf8).write(to: source.appending(path: name))
    #expect(BootstrapPackage.locate(in: bundle) == nil)
    let out = root.appending(path: "out")
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    #expect(throws: BootstrapPackage.ExportError.self) { try package.export(to: out) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).isEmpty)
}

@Test(arguments: ["\(abcDigest.uppercased())  \(name)\n", "\(abcDigest)  other.tar\n", "\(abcDigest) \(name)\n", "\(abcDigest)  \(name)", "deadbeef  \(name)\n"])
func malformedDigestLinesAreRefused(line: String) throws {
    let root = try folder("malformed")
    defer { try? FileManager.default.removeItem(at: root) }
    let bundle = try appBundle(at: root)
    try bootstrap(in: #require(bundle.resourceURL).appending(path: "Bootstrap"), line: line)
    #expect(BootstrapPackage.locate(in: bundle) == nil)
}

// Changing cwd is process-global: keep these cases serialized with each other, and always restore it.
@Suite(.serialized) struct BootstrapNonBundleTests {
    @Test func workingDirectoryAndExecutableSiblingsAreNeverOffered() throws {
        let root = try folder("untrusted")
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try appBundle(at: root)
        for path in ["Resources/Bootstrap", "Bootstrap", "AgentApp.resources/Bootstrap",
                     "AgentApp_AgentApp.bundle/Contents/Resources/Bootstrap"] {
            try bootstrap(in: root.appending(path: path))
        }
        let previous = FileManager.default.currentDirectoryPath
        defer { _ = FileManager.default.changeCurrentDirectoryPath(previous) }
        #expect(FileManager.default.changeCurrentDirectoryPath(root.path))
        #expect(BootstrapPackage.locate(in: bundle) == nil)
    }

    @Test(arguments: ["Bootstrap", name, name + ".sha256"])
    func symlinkOutsideTheBundleIsNeverOffered(link: String) throws {
        let root = try folder("symlink")
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try appBundle(at: root)
        let source = try #require(bundle.resourceURL).appending(path: "Bootstrap")
        let outside = root.appending(path: "outside")
        try bootstrap(in: outside)
        try bootstrap(in: source)
        let destination = link == "Bootstrap" ? source : source.appending(path: link)
        let target = link == "Bootstrap" ? outside : outside.appending(path: link)
        try FileManager.default.removeItem(at: destination)
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: target)
        #expect(BootstrapPackage.locate(in: bundle) == nil)
    }
}

@Test func buildWithoutPackageShowsNone() throws {
    let root = try folder("empty")
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(BootstrapPackage.locate(in: try appBundle(at: root)) == nil)
}

@Test func looseResourceBundleIsNeverOffered() throws {
    let root = try folder("loose-bundle")
    defer { try? FileManager.default.removeItem(at: root) }
    let bundle = try appBundle(at: root, name: "AgentApp_AgentApp.bundle")
    try bootstrap(in: #require(bundle.resourceURL).appending(path: "Bootstrap"))
    #expect(BootstrapPackage.locate(in: bundle) == nil)
}

/// After packaging on the Mac, retain the integration check against the actual embedded bytes.
private let builtAppURL: URL? = {
    var repo = URL(fileURLWithPath: #filePath)
    for _ in 0..<3 { repo.deleteLastPathComponent() }
    let app = repo.appending(path: "dist/SwarmHub.app")
    return FileManager.default.fileExists(atPath: app.appending(path: "Contents/Resources/Bootstrap").path) ? app : nil
}()

@Test(.enabled(if: builtAppURL != nil)) func builtPackageMatchesItsRecordedDigest() throws {
    let url = try #require(builtAppURL)
    let bundle = try #require(Bundle(url: url))
    let package = try #require(BootstrapPackage.locate(in: bundle))
    #expect(try package.actualDigest() == package.expectedDigest)
}
