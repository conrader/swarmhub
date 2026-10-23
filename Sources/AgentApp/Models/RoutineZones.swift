import Foundation

/// recsfix1 (live finding #13): a suggestion's routine is offered in the Mac's time ("every weekday at 9:00"), but the box
/// runs its cron in its own time zone (Hermes's configured one, else the server's: UTC on our boxes). The two zones, and
/// the conversion between them for a once-a-day cron ("0 9 * * 1-5" in Warsaw is "0 7 * * 1-5" in UTC in summer, "0 8 *
/// * 1-5" in winter). Pure.
struct RoutineZones: Equatable, Sendable {
    /// The Mac's zone (what the user sees) and the box's (what its cron runs in).
    var local: TimeZone, box: TimeZone
    /// The conversion uses both zones' offsets at the schedule's next run after `now`, so a routine offered before a DST
    /// change but first run after it runs at the time offered.
    var now: Date

    var isSame: Bool { local.identifier == box.identifier || (Self.isFixed(local) && Self.isFixed(box) && local.secondsFromGMT() == box.secondsFromGMT()) }
    /// recsfix2: the difference between the clocks changes during the year (daylight saving time on one side, or on other
    /// dates): a cron converted once runs an hour off part of the year, so the app moves its suggestions' routines.
    var drifts: Bool { !isSame && !(Self.isFixed(local) && Self.isFixed(box)) }

    /// `schedule` (Mac time) in the box's zone; unchanged when it is not a fixed daily time or the zones are the same.
    func boxSchedule(_ schedule: String) -> String { Self.convert(schedule, from: local, to: box, now: now) }
    /// `schedule` (box time) in the Mac's zone.
    func localSchedule(_ schedule: String) -> String { Self.convert(schedule, from: box, to: local, now: now) }

    /// Minutes the Mac's clock is ahead of the box's (negative: behind) at the next run of `schedule` (Mac time).
    func shift(_ schedule: String) -> Int {
        let fire = Self.nextRun(schedule, in: local, after: now) ?? now
        return (local.secondsFromGMT(for: fire) - box.secondsFromGMT(for: fire)) / 60
    }

    /// "UTC", "UTC+05:30", or the zone's name when it follows daylight saving time ("Europe/Warsaw").
    var boxName: String {
        guard Self.isFixed(box) else { return box.identifier }
        let seconds = box.secondsFromGMT()
        guard seconds != 0 else { return "UTC" }
        let minutes = abs(seconds) / 60
        return "UTC" + (seconds < 0 ? "-" : "+") + String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    /// The box's cron zone from a time its jobs reported (`next_run_at`, else `last_run_at`): the Mac's own zone when the
    /// offset is the Mac's at that time and not UTC (a box set to the user's zone, so DST and all), else that fixed offset;
    /// UTC when no job says (the server default on our boxes).
    static func boxZone(_ jobs: [HermesJob], local: TimeZone) -> TimeZone {
        let utc = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0)!
        var reported: (offset: Int, at: Date)?
        search: for job in jobs {
            for stamp in [job.nextRunAt, job.lastRunAt] {
                guard let offset = CronDeliveryRow.offsetMinutes(stamp), let date = stamp.flatMap(RoutineTime.date) else { continue }
                reported = (offset, date); break search
            }
        }
        guard let reported, reported.offset != 0 else { return utc }
        if local.secondsFromGMT(for: reported.at) == reported.offset * 60 { return local }
        return TimeZone(secondsFromGMT: reported.offset * 60) ?? utc
    }

    // MARK: Conversion

    /// A zone without daylight saving time (UTC or a fixed offset).
    static func isFixed(_ zone: TimeZone) -> Bool {
        zone.nextDaylightSavingTimeTransition == nil && !zone.isDaylightSavingTime()
    }

    /// The fields of a once-a-day cron ("30 7 * * 1-5"): minute, hour and days (0 = Sunday).
    static func fields(_ schedule: String) -> (minute: Int, hour: Int, days: Set<Int>, field: String)? {
        guard CronDays.isDailyTime(schedule) else { return nil }
        let parts = schedule.split(separator: " ").map(String.init)
        guard let minute = Int(parts[0]), let hour = Int(parts[1]), let days = CronDays.parse(parts[4]) else { return nil }
        return (minute, hour, days, parts[4])
    }

    /// The first run of `schedule` in `zone` after `now` (within a week).
    static func nextRun(_ schedule: String, in zone: TimeZone, after now: Date) -> Date? {
        guard let parts = fields(schedule) else { return nil }
        let minute = parts.minute, hour = parts.hour, days = parts.days
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let today = calendar.startOfDay(for: now)
        for offset in 0...8 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                  days.contains(calendar.component(.weekday, from: day) - 1),
                  let run = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day), run > now else { continue }
            return run
        }
        return nil
    }

    /// `schedule` read in `from` and written in `to`: the time moved by the zones' difference at its next run, and the
    /// days moved with it when the time crosses midnight ("30 0 * * 1-5" in Warsaw is "30 22 * * 0-4" in UTC in summer).
    static func convert(_ schedule: String, from: TimeZone, to: TimeZone, now: Date) -> String {
        guard let parts = fields(schedule), let run = nextRun(schedule, in: from, after: now) else { return schedule }
        let total = parts.hour * 60 + parts.minute + (to.secondsFromGMT(for: run) - from.secondsFromGMT(for: run)) / 60
        let dayShift = total < 0 ? -1 : (total >= 1_440 ? 1 : 0), time = (total % 1_440 + 1_440) % 1_440
        let moved = dayShift == 0 ? parts.field : CronDays.field(Set(parts.days.map { ($0 + dayShift + 7) % 7 }))
        return "\(time % 60) \(time / 60) * * \(moved)"
    }
}
