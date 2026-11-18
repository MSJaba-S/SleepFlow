import Foundation
import SleepCore
import UserNotifications

/// A system mechanism that can make the phone ring at a given time.
@MainActor
protocol AlarmScheduling: AnyObject {
    /// Short name shown in settings ("AlarmKit", "Notifications").
    var backendName: String { get }
    /// Rings through Silent mode and Focus.
    var breaksThroughSilentMode: Bool { get }
    func authorization() -> PermissionState
    func requestAuthorization() async -> PermissionState
    func schedule(fireDate: Date, occurrenceKey: String, role: ScheduledAlarmRecord.Role, settings: AlarmSettings) async throws -> String
    func cancel(alarmID: String)
    func stop(alarmID: String)
}

/// Backup and fallback: a short burst of local notifications with the alarm tone.
///
/// Used as the primary alarm before iOS 26 (or when AlarmKit is not authorised), and in addition to
/// AlarmKit as a late backup a minute after the deadline. Notifications follow Silent mode and Focus,
/// which is documented in the app.
@MainActor
final class NotificationAlarmScheduler: AlarmScheduling {
    static let categoryIdentifier = "SLEEPFLOW_ALARM"
    static let stopAction = "SLEEPFLOW_STOP"
    static let snoozeAction = "SLEEPFLOW_SNOOZE"

    let backendName = "Notifications"
    let breaksThroughSilentMode = false
    /// Notifications per alarm, one per minute, so a missed first banner is repeated.
    var burstCount = 8

    private var state: PermissionState = .notDetermined

    init() {
        let stop = UNNotificationAction(identifier: NotificationAlarmScheduler.stopAction, title: String(localized: "Stop"), options: [.foreground])
        let snooze = UNNotificationAction(identifier: NotificationAlarmScheduler.snoozeAction, title: String(localized: "Snooze"), options: [])
        let category = UNNotificationCategory(identifier: NotificationAlarmScheduler.categoryIdentifier, actions: [stop, snooze], intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    func authorization() -> PermissionState { state }

    func refreshAuthorization() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: state = .granted
        case .denied: state = .denied
        default: state = .notDetermined
        }
    }

    func requestAuthorization() async -> PermissionState {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        await refreshAuthorization()
        return state
    }

    func schedule(fireDate: Date, occurrenceKey: String, role: ScheduledAlarmRecord.Role, settings: AlarmSettings) async throws -> String {
        let id = "notification-\(UUID().uuidString)"
        let center = UNUserNotificationCenter.current()
        let sound = AlarmSound.sound(id: settings.soundID)
        for index in 0..<burstCount {
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Good morning")
            content.body = role == .snooze ? String(localized: "Snooze is over. Time to get up.") : String(localized: "Time to wake up.")
            content.sound = UNNotificationSound(named: UNNotificationSoundName(sound.fileName))
            content.categoryIdentifier = NotificationAlarmScheduler.categoryIdentifier
            content.interruptionLevel = .active
            content.userInfo = ["alarmID": id, "occurrenceKey": occurrenceKey, "role": role.rawValue]
            let date = fireDate.addingTimeInterval(Double(index) * 60)
            let interval = max(1, date.timeIntervalSinceNow)
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
            let request = UNNotificationRequest(identifier: "\(id)-\(index)", content: content, trigger: trigger)
            try await center.add(request)
        }
        return id
    }

    func cancel(alarmID: String) {
        let identifiers = (0..<burstCount).map { "\(alarmID)-\($0)" }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    func stop(alarmID: String) {
        cancel(alarmID: alarmID)
    }
}
