import Foundation

/// P31 E: how many coding jobs a box can run side by side, from its `box_capacity` report, and the advice line. Pure.
struct BoxCapacity: Equatable {
    static let reserveMB = 512
    static let defaultJobMB = 600
    /// Jobs measured before the peak counts; fewer use `defaultJobMB`.
    static let measuredJobs = 3
    static let recentJobs = 20
    static let week: TimeInterval = 7 * 24 * 3600

    struct Week: Equatable { var count: Int; var averageWait: Int; var longestWait: Int }

    let report: BoxCapacityReport
    /// Memory one job needs: the largest peak of the last 20 jobs (600 MB with fewer than 3 jobs, or none measured).
    let jobMB: Int
    let advised: Int
    /// The limit `code-job` uses now: `SLOTS` from coding.conf, else 1.
    var slots: Int { report.slots ?? 1 }

    init(_ report: BoxCapacityReport) {
        self.report = report
        jobMB = Self.jobMB(report.jobs)
        advised = Self.advised(cpus: report.cpus, availMB: report.memAvailMB, jobMB: jobMB)
    }

    static func jobMB(_ jobs: [BoxCapacityReport.Job]) -> Int {
        guard jobs.count >= measuredJobs, let peak = jobs.suffix(recentJobs).map(\.peakMB).max(), peak > 0 else { return defaultJobMB }
        return peak
    }

    /// `max(1, min(cpus, floor((available − 512) / job)))`.
    static func advised(cpus: Int, availMB: Int, jobMB: Int) -> Int {
        max(1, min(cpus, (availMB - reserveMB) / max(1, jobMB)))
    }

    /// Jobs of the last 7 days before `now`: count, average and longest wait (seconds).
    func week(now: Date) -> Week {
        let recent = report.jobs.filter { now.timeIntervalSince($0.at) <= Self.week }
        guard !recent.isEmpty else { return Week(count: 0, averageWait: 0, longestWait: 0) }
        let waits = recent.map(\.waited)
        return Week(count: recent.count, averageWait: Int((Double(waits.reduce(0, +)) / Double(waits.count)).rounded()), longestWait: waits.max() ?? 0)
    }

    /// The advice line, or nil while jobs did not wait a minute on average this week. A bigger box is twice the CPUs
    /// and twice the RAM, its extra RAM free (available = this box's available + its total).
    func advice(now: Date) -> String? {
        let week = week(now: now)
        guard week.count > 0, week.averageWait >= 60 else { return nil }
        let minutes = max(1, Int((Double(week.averageWait) / 60).rounded()))
        if advised > slots { return "Jobs waited \(minutes) min on average this week. This box can run \(advised)." }
        let bigger = Self.advised(cpus: report.cpus * 2, availMB: report.memAvailMB + report.memTotalMB, jobMB: jobMB)
        return "Jobs waited \(minutes) min on average this week; a box with \(report.cpus * 2) CPUs and \(Self.gigabytes(report.memTotalMB * 2)) GB would run \(bigger)."
    }

    /// "This box: 2 CPUs, 3.8 GB — 1 coding job at a time (set by you)": the limit set in coding.conf, else what
    /// SwarmHub advises.
    var line: String {
        let count = report.slots ?? advised
        let cpus = report.cpus == 1 ? "1 CPU" : "\(report.cpus) CPUs"
        return "This box: \(cpus), \(Self.gigabytes(report.memTotalMB)) GB — \(count) coding \(count == 1 ? "job" : "jobs") at a time (\(report.slots == nil ? "advised" : "set by you"))"
    }

    /// Until "Use advised" writes it, `code-job` runs one job at a time.
    var notApplied: String? { report.slots == nil && advised > 1 ? "Not set on the box yet: jobs run one at a time until you press Use advised." : nil }

    /// "Use advised" is offered while the box runs another number than the advised one.
    var offersAdvised: Bool { advised != slots }

    /// The stepper's range in "Set limit…": 1 to twice the CPUs.
    var limitRange: ClosedRange<Int> { 1...max(1, report.cpus * 2) }

    /// MB as GB with one decimal ("3.8", "8").
    static func gigabytes(_ mb: Int) -> String {
        let value = (Double(mb) / 1024 * 10).rounded() / 10
        return value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}

enum BoxReadingsCopy {
    static let capacityMissing = "This box: not checked yet."
    static let modelsHelp = "Model for sub-agents this bot starts. Coding jobs use the coding agent instead."
    static let sameAsEachBot = "Same as each bot's model"
    static let noManager = "No bot on this box can manage the others yet."
    static let noAnswer = "The manager did not answer. Try Check again."

    /// "15 Oct" and "15 Oct 09:12", whatever the Mac's language.
    static func day(_ date: Date) -> String { formatter("d MMM").string(from: date) }
    static func checked(_ date: Date) -> String { "Checked " + formatter("d MMM HH:mm").string(from: date) }

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = format
        return formatter
    }
}
