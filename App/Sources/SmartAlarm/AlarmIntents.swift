import AppIntents
import Foundation
import SleepCore

/// Actions taken on an alarm outside the app's UI (Lock Screen buttons, notification actions).
/// They are recorded persistently so they are processed even if SleepFlow was launched just to run
/// the intent, and posted so a running app reacts immediately.
enum AlarmIntentInbox {
    enum Action: String, Codable, Sendable {
        case stop
        case snooze
    }

    struct Entry: Codable, Sendable {
        var action: Action
        var alarmID: String
        var occurrenceKey: String
        var date: Date
    }

    static let notification = Notification.Name("SleepFlowAlarmIntent")
    private static let key = "alarm.intentInbox"

    static func record(_ action: Action, alarmID: String, occurrenceKey: String) {
        let defaults = UserDefaults.standard
        var entries = pending(defaults: defaults)
        entries.append(Entry(action: action, alarmID: alarmID, occurrenceKey: occurrenceKey, date: Date()))
        if let data = try? JSONEncoder().encode(Array(entries.suffix(20))) {
            defaults.set(data, forKey: key)
        }
        NotificationCenter.default.post(name: notification, object: nil)
    }

    static func pending(defaults: UserDefaults = .standard) -> [Entry] {
        guard let data = defaults.data(forKey: key), let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return entries
    }

    /// Returns and clears all pending entries.
    static func drain(defaults: UserDefaults = .standard) -> [Entry] {
        let entries = pending(defaults: defaults)
        defaults.removeObject(forKey: key)
        return entries
    }
}

/// "Stop" on the system alarm.
struct StopSleepAlarmIntent: LiveActivityIntent {
    static var title: LocalizedStringResource { "Stop alarm" }
    static var isDiscoverable: Bool { false }

    @Parameter(title: "Alarm")
    var alarmID: String

    @Parameter(title: "Wake-up")
    var occurrenceKey: String

    init() {
        alarmID = ""
        occurrenceKey = ""
    }

    init(alarmID: String, occurrenceKey: String) {
        self.alarmID = alarmID
        self.occurrenceKey = occurrenceKey
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        AlarmIntentInbox.record(.stop, alarmID: alarmID, occurrenceKey: occurrenceKey)
        return .result()
    }
}

/// "Snooze" on the system alarm: schedules a new one-shot alarm after the snooze time.
/// The new alarm is scheduled here directly so snoozing works even when the app is not running.
struct SnoozeSleepAlarmIntent: LiveActivityIntent {
    static var title: LocalizedStringResource { "Snooze alarm" }
    static var isDiscoverable: Bool { false }

    @Parameter(title: "Alarm")
    var alarmID: String

    @Parameter(title: "Wake-up")
    var occurrenceKey: String

    init() {
        alarmID = ""
        occurrenceKey = ""
    }

    init(alarmID: String, occurrenceKey: String) {
        self.alarmID = alarmID
        self.occurrenceKey = occurrenceKey
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let settings = AppSettings.storedAlarmSettings()
        let fireDate = Date().addingTimeInterval(TimeInterval(settings.snoozeMinutes * 60))
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            let scheduler = AlarmKitScheduler()
            scheduler.stop(alarmID: alarmID)
            if let newID = try? await scheduler.schedule(fireDate: fireDate, occurrenceKey: occurrenceKey, role: .snooze, settings: settings) {
                SnoozeLedger.store(ScheduledAlarmRecord(occurrenceKey: occurrenceKey, alarmID: newID, fireDate: fireDate, role: .snooze, backend: scheduler.backendName))
            }
        }
        #endif
        AlarmIntentInbox.record(.snooze, alarmID: alarmID, occurrenceKey: occurrenceKey)
        return .result()
    }
}

/// Snooze alarms scheduled from an intent, picked up by the coordinator on its next run.
enum SnoozeLedger {
    private static let key = "alarm.snoozeLedger"

    static func store(_ record: ScheduledAlarmRecord) {
        var records = all()
        records.append(record)
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func all() -> [ScheduledAlarmRecord] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let records = try? JSONDecoder().decode([ScheduledAlarmRecord].self, from: data) else { return [] }
        return records
    }

    static func drain() -> [ScheduledAlarmRecord] {
        let records = all()
        UserDefaults.standard.removeObject(forKey: key)
        return records
    }
}
