import Foundation
import SleepModels

/// One concrete wake-up: a deadline and the start of its Smart Alarm window.
public struct AlarmOccurrence: Codable, Sendable, Hashable, Identifiable {
    /// Local date and time of the deadline, `yyyy-MM-dd HH:mm`. Stable across time-zone changes
    /// of the same wall-clock alarm, so reconciliation can tell what changed.
    public var key: String
    public var deadline: Date
    public var windowStart: Date

    public init(key: String, deadline: Date, windowStart: Date) {
        self.key = key
        self.deadline = deadline
        self.windowStart = windowStart
    }

    public var id: String { key }
    public var window: TimeInterval { deadline.timeIntervalSince(windowStart) }

    public func contains(_ date: Date) -> Bool {
        date >= windowStart && date <= deadline
    }
}

/// Computes upcoming alarm occurrences in local wall-clock time.
///
/// All dates are derived with `Calendar` in the calendar's current time zone, so daylight-saving
/// transitions keep 07:00 at 07:00 local time. When the time zone changes, recomputing the plan
/// yields new instants for the same keys, which the reconciler reschedules.
public enum AlarmOccurrencePlanner {
    public static func upcoming(settings: AlarmSettings, after now: Date, calendar: Calendar, horizonDays: Int = 8) -> [AlarmOccurrence] {
        guard settings.isEnabled else { return [] }
        var occurrences: [AlarmOccurrence] = []
        let startOfToday = calendar.startOfDay(for: now)
        let lastDay = settings.weekdays.isEmpty ? 1 : max(horizonDays, 1)
        for dayOffset in 0...lastDay {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: startOfToday) else { continue }
            if !settings.weekdays.isEmpty {
                let weekdayNumber = calendar.component(.weekday, from: day)
                guard let weekday = Weekday(rawValue: weekdayNumber), settings.weekdays.contains(weekday) else { continue }
            }
            guard let deadline = wallClockDate(on: day, hour: settings.hour, minute: settings.minute, calendar: calendar) else { continue }
            guard deadline > now else { continue }
            let windowStart = deadline.addingTimeInterval(-settings.effectiveWindow)
            occurrences.append(AlarmOccurrence(key: key(for: deadline, calendar: calendar), deadline: deadline, windowStart: windowStart))
            if settings.weekdays.isEmpty { break }
        }
        return occurrences
    }

    public static func next(settings: AlarmSettings, after now: Date, calendar: Calendar) -> AlarmOccurrence? {
        upcoming(settings: settings, after: now, calendar: calendar).first
    }

    /// The local date `day` at `hour:minute`. Non-existent times (spring-forward gap) move to the
    /// next existing time; repeated times (fall-back) use the first occurrence.
    public static func wallClockDate(on day: Date, hour: Int, minute: Int, calendar: Calendar) -> Date? {
        var components = calendar.dateComponents([.year, .month, .day], from: day)
        components.hour = hour
        components.minute = minute
        components.second = 0
        if let exact = calendar.date(from: components),
           calendar.component(.hour, from: exact) == hour,
           calendar.component(.minute, from: exact) == minute,
           calendar.isDate(exact, inSameDayAs: day) {
            return exact
        }
        // The requested time does not exist on this day (DST gap): use the next valid time.
        let startOfDay = calendar.startOfDay(for: day)
        return calendar.nextDate(
            after: startOfDay,
            matching: DateComponents(hour: hour, minute: minute, second: 0),
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: .forward
        )
    }

    public static func key(for date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        func pad(_ value: Int?, _ width: Int) -> String {
            let text = String(value ?? 0)
            return String(repeating: "0", count: max(0, width - text.count)) + text
        }
        return "\(pad(c.year, 4))-\(pad(c.month, 2))-\(pad(c.day, 2)) \(pad(c.hour, 2)):\(pad(c.minute, 2))"
    }
}

/// An alarm that has been handed to the system.
public struct ScheduledAlarmRecord: Codable, Sendable, Hashable {
    public enum Role: String, Codable, Sendable {
        /// The guaranteed alarm at the deadline.
        case deadline
        /// Rings now because the Smart Alarm found a good moment.
        case smart
        case snooze
    }

    public var occurrenceKey: String
    public var alarmID: String
    public var fireDate: Date
    public var role: Role
    public var backend: String

    public init(occurrenceKey: String, alarmID: String, fireDate: Date, role: Role, backend: String) {
        self.occurrenceKey = occurrenceKey
        self.alarmID = alarmID
        self.fireDate = fireDate
        self.role = role
        self.backend = backend
    }
}

/// Difference between the alarms that should exist and those that do.
public struct AlarmReconciliation: Sendable, Equatable {
    public var toSchedule: [AlarmOccurrence]
    public var toCancel: [ScheduledAlarmRecord]
    public var toKeep: [ScheduledAlarmRecord]

    public init(toSchedule: [AlarmOccurrence], toCancel: [ScheduledAlarmRecord], toKeep: [ScheduledAlarmRecord]) {
        self.toSchedule = toSchedule
        self.toCancel = toCancel
        self.toKeep = toKeep
    }

    public var isEmpty: Bool { toSchedule.isEmpty && toCancel.isEmpty }
}

public enum AlarmReconciler {
    /// - Parameters:
    ///   - desired: occurrences that should have a deadline alarm.
    ///   - scheduled: deadline alarms currently registered.
    ///   - suppressedKeys: occurrences already handled (woken by Smart Alarm, alarm stopped) whose
    ///     deadline must not ring again.
    ///   - tolerance: fire dates closer than this to the desired deadline are kept.
    public static func reconcile(
        desired: [AlarmOccurrence],
        scheduled: [ScheduledAlarmRecord],
        suppressedKeys: Set<String> = [],
        now: Date,
        tolerance: TimeInterval = 30
    ) -> AlarmReconciliation {
        let wanted = desired.filter { !suppressedKeys.contains($0.key) }
        let wantedByKey = Dictionary(wanted.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var keep: [ScheduledAlarmRecord] = []
        var cancel: [ScheduledAlarmRecord] = []
        var covered = Set<String>()

        for record in scheduled where record.role == .deadline {
            if let occurrence = wantedByKey[record.occurrenceKey],
               abs(occurrence.deadline.timeIntervalSince(record.fireDate)) <= tolerance,
               !covered.contains(record.occurrenceKey) {
                keep.append(record)
                covered.insert(record.occurrenceKey)
            } else if record.fireDate <= now {
                // Already fired; nothing to cancel in the system but drop the record.
                cancel.append(record)
            } else {
                cancel.append(record)
            }
        }
        let schedule = wanted.filter { !covered.contains($0.key) }.sorted { $0.deadline < $1.deadline }
        return AlarmReconciliation(toSchedule: schedule, toCancel: cancel, toKeep: keep)
    }
}
