import CryptoKit
import Foundation
import Testing
@testable import SwarmHubCore

// P2c: the baseline embedded in the app build loads from disk alone; hashes bind index → manifest → blobs.

private let abcDigest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"  // FIPS 180-2 SHA-256("abc")

private func hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

/// A minimal baseline in the service layout; returns its folder.
private func layout(blob: Data = Data("abc".utf8), manifestTail: String = "") throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(path: "SwarmHubCoreP2c-\(UUID().uuidString)")
    for sub in ["channels", "bundles", "blobs/sha256"] {
        try FileManager.default.createDirectory(at: dir.appending(path: sub), withIntermediateDirectories: true)
    }
    let sig = #"[{"key_id":"TEST-release-1","sig":"00"}]"#
    let manifest = Data((#"{"signatures":\#(sig),"signed":{"components":[{"kind":"config","class":"data","name":"policy","sha256":"\#(abcDigest)","size":3,"#
        + #""targets":["mac","ios"],"version":"1.0.0"}],"label":"baseline","version":2}}"#).utf8)
    let index = #"{"signatures":\#(sig),"signed":{"lines":[{"bundle_version":2,"manifest_sha256":"\#(hex(manifest))"}],"seq":7}}"#
    try Data(#"{"roots":[],"schema":"swarmhub/pins/1","threshold":1}"#.utf8).write(to: dir.appending(path: "pins.json"))
    try Data(#"{"signatures":[],"signed":{"version":3}}"#.utf8).write(to: dir.appending(path: "keys.json"))
    try Data(index.utf8).write(to: dir.appending(path: "channels/stable.json"))
    try (manifest + Data(manifestTail.utf8)).write(to: dir.appending(path: "bundles/2.json"))
    try blob.write(to: dir.appending(path: "blobs/sha256/\(abcDigest)"))
    return dir
}

@Test func baselineLoadsFromDiskAlone() throws {
    let dir = try layout()
    let baseline = try EmbeddedBaseline.load(from: dir)
    #expect(baseline.bundleVersion == 2 && baseline.indexSequence == 7 && baseline.keysVersion == 3 && baseline.label == "baseline")
    #expect(baseline.components.map(\.name) == ["policy"])
    #expect(baseline.components(for: "ios").count == 1 && baseline.components(for: "box").isEmpty)
    #expect(try baseline.blob(for: baseline.components[0]) == Data("abc".utf8))
    let pins = try Data(contentsOf: dir.appending(path: "pins.json"))
    #expect(baseline.pins == pins)
}

@Test func iosLoadsWithoutBoxBlobs() throws {
    let dir = try layout()
    try FileManager.default.removeItem(at: dir.appending(path: "blobs/sha256/\(abcDigest)"))
    #expect(throws: EmbeddedBaseline.LoadError.missing("blobs/sha256/\(abcDigest)")) { try EmbeddedBaseline.load(from: dir) }
    #expect(throws: EmbeddedBaseline.LoadError.missing("blobs/sha256/\(abcDigest)")) { try EmbeddedBaseline.load(from: dir, target: "ios") }
    #expect(try EmbeddedBaseline.load(from: dir, target: "box").components.count == 1)
}

@Test func alteredManifestIsRefused() throws {
    let dir = try layout(manifestTail: " ")
    #expect(throws: EmbeddedBaseline.LoadError.manifestHashMismatch) { try EmbeddedBaseline.load(from: dir) }
}

@Test func alteredBlobIsRefused() throws {
    let dir = try layout(blob: Data("abd".utf8))
    #expect(throws: EmbeddedBaseline.LoadError.blobMismatch("policy")) { try EmbeddedBaseline.load(from: dir) }
}

@Test func missingBaselineIsReported() throws {
    let empty = FileManager.default.temporaryDirectory.appending(path: "SwarmHubCoreP2c-empty-\(UUID().uuidString)")
    #expect(throws: EmbeddedBaseline.LoadError.missing("pins.json")) { try EmbeddedBaseline.load(from: empty) }
    let good = try layout()
    #expect(EmbeddedBaseline.locate([empty, good])?.bundleVersion == 2)
    #expect(EmbeddedBaseline.locate([empty]) == nil)
}
