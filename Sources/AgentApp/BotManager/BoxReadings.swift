import Foundation

/// P31 D: one bot's models as the manager's "Bot models" recipe read them from its config.yaml (op `models`). An empty
/// `subModel` means no pin: its sub-agents run on the bot's own model.
struct BotModels: Codable, Equatable {
    var name: String; var model: String; var provider: String; var subModel: String; var subProvider: String

    static let rowLimit = 200

    /// A model or provider id SwarmHub shows and puts into a command: `[A-Za-z0-9._:/-]`, at most 100 characters
    /// (empty allowed: not set).
    static func isValidID(_ text: String) -> Bool {
        text.count <= 100 && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._:/-".contains($0)) }
    }

    /// One row; nil for an invalid profile name or any id that is not a string of the allowed characters.
    init?(_ row: [String: Any]) {
        guard let name = row["name"] as? String, HermesKeyPaste.isValidProfileName(name) else { return nil }
        var ids: [String] = []
        for key in ["model", "provider", "sub_model", "sub_provider"] {
            // A missing key is empty (not set); anything else must be a string of allowed characters.
            guard let text = (row[key] ?? "") as? String, Self.isValidID(text) else { return nil }
            ids.append(text)
        }
        self.init(name: name, model: ids[0], provider: ids[1], subModel: ids[2], subProvider: ids[3])
    }

    init(name: String, model: String, provider: String, subModel: String = "", subProvider: String = "") {
        self.name = name; self.model = model; self.provider = provider; self.subModel = subModel; self.subProvider = subProvider
    }

    /// The `list` of a `models` op: bad rows dropped, the first row per name kept, at most `rowLimit` rows.
    static func list(_ rows: [Any]) -> [BotModels] {
        var seen: Set<String> = [], result: [BotModels] = []
        for case let row as [String: Any] in rows.prefix(rowLimit * 2) {
            guard let parsed = BotModels(row), seen.insert(parsed.name).inserted else { continue }
            result.append(parsed)
            if result.count == rowLimit { break }
        }
        return result
    }
}

/// P31 E: what the "Box capacity" probe reported (op `box_capacity`): CPUs, memory, disk, load, the coding job limit
/// set in `coding.conf` (nil: not set, `code-job` runs one) and the last coding jobs (no bot or agent names).
struct BoxCapacityReport: Codable, Equatable {
    struct Job: Codable, Equatable { var at: Date; var waited: Int; var ran: Int; var peakMB: Int; var exit: Int }

    var cpus: Int; var memTotalMB: Int; var memAvailMB: Int; var diskFreeMB: Int; var load1: String
    var slots: Int?
    var jobs: [Job]

    static let jobLimit = 200

    init(cpus: Int, memTotalMB: Int, memAvailMB: Int, diskFreeMB: Int = 0, load1: String = "0.00", slots: Int? = nil, jobs: [Job] = []) {
        self.cpus = cpus; self.memTotalMB = memTotalMB; self.memAvailMB = memAvailMB; self.diskFreeMB = diskFreeMB
        self.load1 = load1; self.slots = slots; self.jobs = jobs
    }

    /// Nil when a number is missing or out of range; bad job rows are dropped and only the last `jobLimit` kept.
    init?(_ object: [String: Any]) {
        func int(_ key: String, _ range: ClosedRange<Int>) -> Int? { Self.int(object[key]).flatMap { range.contains($0) ? $0 : nil } }
        guard let cpus = int("cpus", 1...1024), let total = int("mem_total_mb", 1...16_777_216), let avail = int("mem_avail_mb", 0...total),
              let disk = int("disk_free_mb", 0...1_000_000_000), let load = object["load1"] as? String,
              load.count <= 10, load.range(of: #"^[0-9]+(\.[0-9]+)?$"#, options: .regularExpression) != nil else { return nil }
        let slots: Int?
        switch object["slots"] {
        case nil, is NSNull: slots = nil
        case let value: guard let number = Self.int(value), (0...1024).contains(number) else { return nil }; slots = number == 0 ? nil : number
        }
        let rows = (object["jobs"] as? [Any]) ?? []
        self.init(cpus: cpus, memTotalMB: total, memAvailMB: avail, diskFreeMB: disk, load1: load, slots: slots,
                  jobs: Array(rows.suffix(Self.jobLimit * 2).compactMap(Self.job).suffix(Self.jobLimit)))
    }

    /// `["2026-10-15T01:02:03Z", waited_s, ran_s, peak_mb, exit]`.
    static func job(_ value: Any) -> Job? {
        guard let row = value as? [Any], row.count == 5, let time = row[0] as? String, time.count <= 32,
              let at = try? Date(time, strategy: .iso8601) else { return nil }
        let numbers = row.dropFirst().map(int)
        guard let waited = numbers[0], let ran = numbers[1], let peak = numbers[2], let exit = numbers[3],
              (0...31_536_000).contains(waited), (0...31_536_000).contains(ran), (0...10_000_000).contains(peak), (-255...255).contains(exit) else { return nil }
        return Job(at: at, waited: waited, ran: ran, peakMB: peak, exit: exit)
    }

    /// Whole JSON numbers only (no fractions, no booleans, no strings).
    private static func int(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.rounded() == double, abs(double) < 1e12 else { return nil }
        return number.intValue
    }
}

/// What SwarmHub last heard about one box (keyed by `connection(of:)`), kept in store.json across launches.
struct BoxReadings: Codable, Equatable {
    var models: [BotModels]?; var modelsAt: Date?
    var capacity: BoxCapacityReport?; var capacityAt: Date?

    func models(for profile: String) -> BotModels? { models?.first { $0.name == profile } }
}
