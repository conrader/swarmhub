import Foundation
import Testing
@testable import SwarmHubCore

/// Deterministic decoder fuzz (P7a). The mutator is a port of `scripts/release/ui_fuzz.py` (SplitMix64, byte and
/// structural mutations of every golden document), so this test replays exactly the documents the Python reference
/// judged when it wrote `ui/fuzz.json`, and must give the same verdict for each one. Every outcome is either a whole
/// decoded document (written back, it equals the input) or a compiled screen: never a crash, never part of a document.
struct SDUIFuzzTests {
    struct SplitMix64 {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &+ 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func below(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }
    }

    enum Step: Equatable { case key(String), index(Int) }

    static let interesting: [UInt8] = [123, 125, 91, 93, 34, 58, 44, 92, 32, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57,
                                       45, 46, 101, 69, 0, 255]
    static let pool: [JCS.Value] = [.string(""), .string("x"), .string("operation_review"), .string("secret_entry"),
        .string("webview"), .string("https://evil.example/x"), .string("javascript:alert(1)"),
        .string("routine.secret_token"), .string("[x](https://evil.example)"), .integer(0), .integer(-1),
        .integer(9_007_199_254_740_991), .bool(true), .bool(false), .array([]), .object([:])]
    static let types = ["badge", "button", "card", "diff_preview", "flow", "form", "key_value", "list", "progress",
                        "text", "operation_review", "secret_entry", "webview", "script"]

    static func mutateBytes(_ input: [UInt8], _ rng: inout SplitMix64) -> [UInt8] {
        var data = input
        for _ in 0..<(1 + rng.below(4)) {
            let op = rng.below(5)
            if op == 2 {
                let position = rng.below(data.count + 1)
                data.insert(interesting[rng.below(interesting.count)], at: position)
                continue
            }
            if data.isEmpty { continue }
            switch op {
            case 0:
                let position = rng.below(data.count)
                data[position] ^= UInt8(1) << UInt8(rng.below(8))
            case 1:
                data.remove(at: rng.below(data.count))
            case 3:
                data.removeSubrange(rng.below(data.count)...)
            default:
                let start = rng.below(data.count)
                let length = 1 + rng.below(min(32, data.count - start))
                let piece = Array(data[start..<(start + length)])
                let position = rng.below(data.count + 1)
                data.insert(contentsOf: piece, at: position)
            }
        }
        return data
    }

    static func paths(_ value: JCS.Value, _ prefix: [Step]) -> [[Step]] {
        var out = [prefix]
        switch value {
        case .object(let members):
            for key in members.keys.sorted() { out += paths(members[key] ?? .object([:]), prefix + [.key(key)]) }
        case .array(let items):
            for (index, item) in items.enumerated() { out += paths(item, prefix + [.index(index)]) }
        default: break
        }
        return out
    }

    static func value(_ root: JCS.Value, at path: ArraySlice<Step>) -> JCS.Value {
        guard let step = path.first else { return root }
        switch (root, step) {
        case (.object(let members), .key(let key)): return value(members[key] ?? .object([:]), at: path.dropFirst())
        case (.array(let items), .index(let index)): return value(items[index], at: path.dropFirst())
        default: return root
        }
    }

    static func replacing(_ root: JCS.Value, at path: ArraySlice<Step>, _ change: (JCS.Value) -> JCS.Value) -> JCS.Value {
        guard let step = path.first else { return change(root) }
        switch (root, step) {
        case (.object(var members), .key(let key)):
            members[key] = replacing(members[key] ?? .object([:]), at: path.dropFirst(), change)
            return .object(members)
        case (.array(var items), .index(let index)):
            items[index] = replacing(items[index], at: path.dropFirst(), change)
            return .array(items)
        default: return root
        }
    }

    static func card(_ value: JCS.Value) -> JCS.Value { .object(["type": .string("card"), "children": .array([value])]) }

    static func mutateStructure(_ root: JCS.Value, _ rng: inout SplitMix64) -> JCS.Value {
        let all = paths(root, [])
        let path = all[rng.below(all.count)]
        let op = rng.below(7)
        let current = value(root, at: path[...])
        if op == 1 || op == 2 {
            guard let last = path.last else { return op == 1 ? .object([:]) : .array([current, current]) }
            return replacing(root, at: path.dropLast()[...]) { parent in
                switch (parent, last) {
                case (.object(var members), .key(let key)):
                    if op == 1 { members[key] = nil } else { members["extra"] = current }
                    return .object(members)
                case (.array(var items), .index(let index)):
                    if op == 1 { items.remove(at: index) } else { items.insert(current, at: index) }
                    return .array(items)
                default: return parent
                }
            }
        }
        let new: JCS.Value
        switch op {
        case 0:
            new = pool[rng.below(pool.count)]
        case 3:
            new = card(current)
        case 4:
            let kind = types[rng.below(types.count)]
            if case .object(var members) = current {
                members["type"] = .string(kind)
                new = .object(members)
            } else {
                new = .string(kind)
            }
        case 5:
            var nested = current
            for _ in 0..<(1 + rng.below(16)) { nested = card(nested) }
            new = nested
        default:
            let times = 2 + rng.below(40)
            if case .array(let items) = current {
                new = .array(Array(Array(repeating: items, count: times).joined()))
            } else {
                new = .array(Array(repeating: current, count: times))
            }
        }
        return replacing(root, at: path[...]) { _ in new }
    }

    /// Mutated bytes, or nil when the structural result is not representable (nesting above 32).
    static func fuzzDocument(_ golden: [UInt8], _ rng: inout SplitMix64) -> [UInt8]? {
        if rng.below(2) == 1 {
            guard let root = try? JCS.parse(Data(golden)) else { return mutateBytes(golden, &rng) }
            return (try? JCS.canonical(mutateStructure(root, &rng))).map { Array($0) }
        }
        return mutateBytes(golden, &rng)
    }

    @Test func mutatedGoldensMatchTheReferenceAndNeverRenderPartially() throws {
        let catalog = try SDUIFixtures.catalog()
        let fuzz = try SDUIFixtures.fuzz()
        #expect(fuzz.iterations == fuzz.expected.count && fuzz.iterations >= 1000)
        var rng = SplitMix64(state: fuzz.seed)
        var labels: [String] = []
        var rendered = 0
        for _ in 0..<fuzz.iterations {
            let vector = catalog.cases[rng.below(catalog.cases.count)]
            let golden = Array(SDUIFixtures.document(vector.inputs.document))
            guard let data = Self.fuzzDocument(golden, &rng) else {
                labels.append("skip")
                continue
            }
            let outcome = SDUIFixtures.decode(Data(data), vector.inputs)
            labels.append(SDUIFixtures.label(outcome))
            switch outcome {
            case .render(let document):
                rendered += 1
                #expect(SDUIFixtures.canonical(document) == (try? JCS.canonical(JCS.parse(Data(data)))))
            case .fallback(let reason), .updateRequired(let reason):
                #expect(catalog.reasons.contains(reason), "\(reason)")
            }
        }
        #expect(rendered > 0)
        if let index = labels.indices.first(where: { $0 >= fuzz.expected.count || labels[$0] != fuzz.expected[$0] }) {
            let expected = index < fuzz.expected.count ? fuzz.expected[index] : "nothing"
            Issue.record("fuzz diverges from the Python reference at iteration \(index): \(labels[index]) vs \(expected)")
        }
        #expect(labels == fuzz.expected)
    }

    /// Fresh seeds beyond the shared replay: no crash, every outcome whole or compiled.
    @Test func moreSeedsNeverCrashOrRenderPartially() throws {
        let catalog = try SDUIFixtures.catalog()
        for seed: UInt64 in [1, 0xDEAD_BEEF, 0x5EED_0000_0000_0001] {
            var rng = SplitMix64(state: seed)
            for _ in 0..<1000 {
                let vector = catalog.cases[rng.below(catalog.cases.count)]
                guard let data = Self.fuzzDocument(Array(SDUIFixtures.document(vector.inputs.document)), &rng) else { continue }
                if case .render(let document) = SDUIFixtures.decode(Data(data), vector.inputs) {
                    #expect(SDUIFixtures.canonical(document) == (try? JCS.canonical(JCS.parse(Data(data)))))
                }
            }
        }
    }
}
