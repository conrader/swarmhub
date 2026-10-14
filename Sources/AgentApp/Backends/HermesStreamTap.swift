import Foundation

/// P27 D9: records which SSE event names and JSON keys a live Hermes stream carries — names and key paths only, never a
/// value — so tool-activity previews are built only from fields that exist. Off unless `--capture-events` turns it on.
final class HermesStreamTap: @unchecked Sendable {
    static let shared = HermesStreamTap()
    private let lock = NSLock(); private var enabled = false; private var seen: [String: Set<String>] = [:]; private var order: [String] = []

    func start() { lock.withLock { enabled = true; seen = [:]; order = [] } }
    func stop() { lock.withLock { enabled = false } }

    func record(_ event: String, _ json: [String: Any]) {
        lock.withLock {
            guard enabled else { return }
            if seen[event] == nil { order.append(event) }
            seen[event, default: []].formUnion(Self.keyPaths(json))
        }
    }

    /// Event names in first-seen order with their sorted key paths.
    var captured: [(event: String, keys: [String])] { lock.withLock { order.map { ($0, seen[$0, default: []].sorted()) } } }

    /// Top-level keys plus one level into objects (`args.command`) and arrays of objects (`choices[].delta`).
    static func keyPaths(_ json: [String: Any]) -> Set<String> {
        var paths = Set<String>()
        for (key, value) in json {
            paths.insert(key)
            if let object = value as? [String: Any] { paths.formUnion(object.keys.map { "\(key).\($0)" }) }
            if let array = value as? [[String: Any]] { paths.formUnion(array.flatMap(\.keys).map { "\(key)[].\($0)" }) }
        }
        return paths
    }
}
