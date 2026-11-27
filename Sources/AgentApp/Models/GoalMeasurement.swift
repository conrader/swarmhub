import Foundation

extension ChatGoal {
    struct Measurement: Codable, Equatable {
        enum Direction: String, Codable { case increase, decrease }
        let unit: String
        let direction: Direction
        let target: Double
        let before: Double
        let after: Double

        var valid: Bool {
            !unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && unit.count <= 80
                && [target, before, after].allSatisfy(\.isFinite)
        }

        func matches(_ other: Measurement) -> Bool {
            unit == other.unit && direction == other.direction && target == other.target
        }

        func improves(_ baseline: Double) -> Bool {
            direction == .increase ? after > baseline : after < baseline
        }

        var reached: Bool { direction == .increase ? after >= target : after <= target }
    }
}

extension ChatGoal {
    /// Bind explicit free-space thresholds to the requested unit even if the first
    /// report omits its measurement. Other numeric goals establish a metric in their report.
    var freeSpaceThreshold: (Double, String)? {
        let primary = objective.components(separatedBy: "\nFollow-up: ").first ?? objective
        let pattern = #/(?i)\b([0-9]+(?:[.,][0-9]+)?)\s*(KiB|MiB|GiB|TiB|KB|MB|GB|TB)\s+(?:wolnego\b|wolnej\s+przestrzeni\b|(?:of\s+)?free(?:\s+(?:disk\s+)?space)?\b)/#
        guard let match = primary.firstMatch(of: pattern),
              let target = Double(match.1.replacingOccurrences(of: ",", with: ".")), target > 0
        else { return nil }
        return (target, String(match.2))
    }
}
