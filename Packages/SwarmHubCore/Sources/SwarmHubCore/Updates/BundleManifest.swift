import Foundation

/// Validated metadata passed to a blob provider. Archives are never executed or extracted here.
public struct UpdateComponent: Sendable {
    public let kind: String
    public let contentClass: String
    public let name: String
    public let version: String
    public let targets: [String]
    public let sha256: String
    public let size: Int64
    public let path: String
    let requires: [String: String]
    let dependencies: [Dependency]

    struct Dependency: Sendable { let name: String; let minVersion: String }

    static func parse(_ value: JCS.Value) throws -> Self {
        let s = UpdateShape(stage: "manifest")
        let c = try s.object(value)
        let kind = try s.choice(c["kind"], ["skill", "tool", "config", "ui"])
        let contentClass = try s.choice(c["class"], ["data", "code"])
        let name = try s.text(c["name"], pattern: updateName)
        let version = try s.text(c["version"], pattern: updateVersion)
        let targets = try s.stringSet(c["targets"], Set(updateAxes.keys))
        let sha256 = try s.text(c["sha256"], pattern: "[0-9a-f]{64}")
        let size = try s.number(c["size"])
        let path = try s.text(c["path"])
        try requireUpdate(ArchiveRules.safeRelative(path), "manifest")
        let requires = try s.requires(c["requires"])
        let dependencies = try s.array(c["requires_component"]).map {
            let dep = try s.object($0)
            return Dependency(name: try s.text(dep["name"], pattern: updateName),
                              minVersion: try s.text(dep["min_version"], pattern: updateVersion))
        }
        return Self(kind: kind, contentClass: contentClass, name: name, version: version, targets: targets,
                    sha256: sha256, size: size, path: path, requires: requires, dependencies: dependencies)
    }
}

struct BundleManifest {
    let signed: UpdateObject
    let version: Int64
    let components: [UpdateComponent]

    static func verify(_ raw: Data, line: UpdateLine, keys: KeyManifest, consumer: UpdateConsumer,
                       now: String, revoked: Set<String>, limits: UpdateLimits) throws -> Self {
        try requireUpdate(updateDigest(raw) == line.manifestSHA256, "manifest", "manifest_hash_mismatch")
        let s = UpdateShape(stage: "manifest")
        let envelope = try updateEnvelope(raw, stage: "manifest", limits: limits)
        let signed = envelope.signed
        try requireUpdate(signed["schema"] == .string("swarmhub/bundle/1"), "manifest")
        let version = try s.number(signed["version"], low: 1)
        _ = try s.text(signed["label"])
        _ = try s.time(signed["created"])
        let codeBearing = try s.boolean(signed["code_bearing"])
        let requires = try s.requires(signed["requires"])
        let components = try s.array(signed["components"], nonempty: true).map { try UpdateComponent.parse($0) }
        try requireUpdate(Set(components.map(\.name)).count == components.count, "manifest")
        // All schema checks precede metadata checks, and metadata checks precede signatures.
        for c in components {
            try requireUpdate(!(c.kind == "tool" && c.contentClass != "code"), "manifest", "class_mismatch")
            try requireUpdate(!(["config", "ui"].contains(c.kind) && c.contentClass != "data"),
                              "manifest", "class_mismatch")
        }
        try requireUpdate(codeBearing == components.contains { $0.contentClass == "code" },
                          "manifest", "code_bearing_mismatch")
        for c in components {
            let boxOnly = c.contentClass == "code" || ["skill", "tool"].contains(c.kind)
            try requireUpdate(!boxOnly || c.targets == ["box"], "manifest", "target_invalid")
        }
        try keys.check(envelope, role: "bundle", stage: "manifest", now: now, revoked: revoked)
        try requireUpdate(version == line.bundleVersion, "manifest", "version_mismatch")
        try requireUpdate(satisfies(requires, consumer), "manifest", "incompatible_requires")
        let names = Dictionary(uniqueKeysWithValues: components.map { ($0.name, $0) })
        for c in components {
            for dep in c.dependencies {
                guard let target = names[dep.name], target.name != c.name,
                      compareVersions(target.version, dep.minVersion) >= 0,
                      Set(c.targets).isSubset(of: Set(target.targets)) else {
                    throw UpdateRejection(stage: "manifest", reason: "dependency_invalid")
                }
            }
        }
        return Self(signed: signed, version: version, components: components)
    }

    func plan(_ consumer: UpdateConsumer) -> ([UpdateComponent], [UpdateVerdict.Skipped]) {
        let wanted = components.filter { $0.targets.contains(consumer.platform) }
        var skipped: [String: String] = [:]
        for c in wanted where !satisfies(c.requires, consumer) { skipped[c.name] = "incompatible" }
        var changed = true
        while changed {
            changed = false
            for c in wanted where skipped[c.name] == nil {
                if c.dependencies.contains(where: { skipped[$0.name] != nil }) {
                    skipped[c.name] = "dependency_skipped"
                    changed = true
                }
            }
        }
        return (wanted.filter { skipped[$0.name] == nil }, wanted.compactMap { c in
            skipped[c.name].map { UpdateVerdict.Skipped(name: c.name, reason: $0) }
        })
    }
}
