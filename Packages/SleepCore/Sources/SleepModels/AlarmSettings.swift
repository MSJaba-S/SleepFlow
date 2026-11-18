import Foundation

/// The user's wake-up configuration.
public struct AlarmSettings: Codable, Sendable, Hashable {
    public var isEnabled: Bool
    /// Desired latest wake-up time (the deadline), local wall-clock time.
    public var hour: Int
    public var minute: Int
    public var isSmartEnabled: Bool
    /// Length of the Smart Alarm window before the deadline, in minutes.
    public var smartWindowMinutes: Int
    /// Repeating weekdays. Empty means "only the next occurrence".
    public var weekdays: Set<Weekday>
    public var soundID: String
    public var snoozeMinutes: Int
    public var vibrationEnabled: Bool

    public init(
        isEnabled: Bool = true,
        hour: Int = 7,
        minute: Int = 0,
        isSmartEnabled: Bool = true,
        smartWindowMinutes: Int = 30,
        weekdays: Set<Weekday> = Weekday.weekdays,
        soundID: String = "sunrise",
        snoozeMinutes: Int = 9,
        vibrationEnabled: Bool = true
    ) {
        self.isEnabled = isEnabled
        self.hour = min(max(hour, 0), 23)
        self.minute = min(max(minute, 0), 59)
        self.isSmartEnabled = isSmartEnabled
        self.smartWindowMinutes = min(max(smartWindowMinutes, 0), 90)
        self.weekdays = weekdays
        self.soundID = soundID
        self.snoozeMinutes = min(max(snoozeMinutes, 1), 30)
        self.vibrationEnabled = vibrationEnabled
    }

    public static let `default` = AlarmSettings()

    /// Smart window actually in use (0 when Smart Alarm is off).
    public var effectiveWindow: TimeInterval {
        isSmartEnabled ? TimeInterval(smartWindowMinutes * 60) : 0
    }

    public static let allowedWindows: [Int] = [10, 15, 20, 30, 45, 60]
    public static let allowedSnooze: [Int] = [5, 9, 10, 15, 20]
}
