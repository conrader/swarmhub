import Darwin
import Foundation

enum PerformanceMetrics {
    static var residentMegabytes: Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return Double(usage.ru_maxrss) / 1_048_576
    }

    static func reportReady() {
        let line = "[Performance] app initialized; peak resident memory \(String(format: "%.1f", residentMegabytes)) MB\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}
