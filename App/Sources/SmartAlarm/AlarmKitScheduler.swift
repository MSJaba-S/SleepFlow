#if canImport(AlarmKit)
import ActivityKit
import AlarmKit
import Foundation
import SleepCore
import SwiftUI

/// Metadata attached to every SleepFlow alarm.
struct SleepFlowAlarmMetadata: AlarmMetadata {
    var occurrenceKey: String
    var role: String
}

/// Native alarms on iOS 26+ through AlarmKit.
///
/// AlarmKit alarms are delivered by the system: they ring when SleepFlow is not running, with the
/// screen locked, in Silent mode and during Focus, and they appear on the Lock Screen with Stop and
/// Snooze buttons. Every alarm is a one-shot alarm at a fixed instant; the coordinator keeps the next
/// week of occurrences scheduled and reconciles them after time-zone or daylight-saving changes.
@available(iOS 26.0, *)
@MainActor
final class AlarmKitScheduler: AlarmScheduling {
    let backendName = "AlarmKit"
    let breaksThroughSilentMode = true

    func authorization() -> PermissionState {
        switch AlarmManager.shared.authorizationState {
        case .authorized: return .granted
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    func requestAuthorization() async -> PermissionState {
        do {
            let state = try await AlarmManager.shared.requestAuthorization()
            return state == .authorized ? .granted : .denied
        } catch {
            Log.alarm.error("AlarmKit authorization failed: \(error.localizedDescription, privacy: .public)")
            return .denied
        }
    }

    func schedule(fireDate: Date, occurrenceKey: String, role: ScheduledAlarmRecord.Role, settings: AlarmSettings) async throws -> String {
        let id = UUID()
        let stopButton = AlarmButton(text: "Stop", textColor: .white, systemImageName: "stop.fill")
        let snoozeButton = AlarmButton(text: "Snooze", textColor: .white, systemImageName: "zzz")
        let title: LocalizedStringResource = role == .snooze ? "Snooze is over" : "Good morning"
        let alert = AlarmPresentation.Alert(
            title: title,
            stopButton: stopButton,
            secondaryButton: snoozeButton,
            secondaryButtonBehavior: .custom
        )
        let attributes = AlarmAttributes<SleepFlowAlarmMetadata>(
            presentation: AlarmPresentation(alert: alert),
            metadata: SleepFlowAlarmMetadata(occurrenceKey: occurrenceKey, role: role.rawValue),
            tintColor: Color(red: 1.0, green: 0.54, blue: 0.24)
        )
        let sound = AlarmSound.sound(id: settings.soundID)
        let configuration = AlarmManager.AlarmConfiguration<SleepFlowAlarmMetadata>.alarm(
            schedule: .fixed(fireDate),
            attributes: attributes,
            stopIntent: StopSleepAlarmIntent(alarmID: id.uuidString, occurrenceKey: occurrenceKey),
            secondaryIntent: SnoozeSleepAlarmIntent(alarmID: id.uuidString, occurrenceKey: occurrenceKey),
            sound: .named(sound.fileName)
        )
        _ = try await AlarmManager.shared.schedule(id: id, configuration: configuration)
        Log.alarm.info("AlarmKit alarm \(id.uuidString, privacy: .public) at \(fireDate, privacy: .public) role \(role.rawValue, privacy: .public)")
        return id.uuidString
    }

    func cancel(alarmID: String) {
        guard let id = UUID(uuidString: alarmID) else { return }
        try? AlarmManager.shared.cancel(id: id)
    }

    func stop(alarmID: String) {
        guard let id = UUID(uuidString: alarmID) else { return }
        try? AlarmManager.shared.stop(id: id)
    }

    /// IDs of the alarms the system currently holds for SleepFlow.
    func systemAlarmIDs() -> Set<String> {
        let alarms = (try? AlarmManager.shared.alarms) ?? []
        return Set(alarms.map { $0.id.uuidString })
    }

    /// IDs of alarms that are ringing right now.
    func alertingAlarmIDs() -> Set<String> {
        let alarms = (try? AlarmManager.shared.alarms) ?? []
        return Set(alarms.filter { $0.state == .alerting }.map { $0.id.uuidString })
    }
}
#endif
