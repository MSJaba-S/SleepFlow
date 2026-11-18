import AVFoundation
import Foundation
import Observation
import UIKit
import UserNotifications
#if canImport(AlarmKit)
import AlarmKit
#endif

enum PermissionState: String, Sendable {
    case notDetermined
    case granted
    case denied
    /// The capability does not exist on this iOS version (AlarmKit before iOS 26).
    case unavailable

    var isGranted: Bool { self == .granted }
}

/// Central place for every system permission SleepFlow uses.
@MainActor
@Observable
final class PermissionCenter {
    private(set) var microphone: PermissionState = .notDetermined
    private(set) var notifications: PermissionState = .notDetermined
    private(set) var alarms: PermissionState = .unavailable

    static var alarmKitSupported: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    func refresh() async {
        microphone = PermissionCenter.currentMicrophoneState()
        let notificationSettings = await UNUserNotificationCenter.current().notificationSettings()
        switch notificationSettings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: notifications = .granted
        case .denied: notifications = .denied
        case .notDetermined: notifications = .notDetermined
        @unknown default: notifications = .notDetermined
        }
        alarms = PermissionCenter.currentAlarmState()
    }

    static func currentMicrophoneState() -> PermissionState {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return .granted
        case .denied: return .denied
        case .undetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    static func currentAlarmState() -> PermissionState {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            switch AlarmManager.shared.authorizationState {
            case .authorized: return .granted
            case .denied: return .denied
            case .notDetermined: return .notDetermined
            @unknown default: return .notDetermined
            }
        }
        #endif
        return .unavailable
    }

    @discardableResult
    func requestMicrophone() async -> Bool {
        let granted = await AVAudioApplication.requestRecordPermission()
        microphone = granted ? .granted : .denied
        return granted
    }

    @discardableResult
    func requestNotifications() async -> Bool {
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        await refresh()
        return granted
    }

    @discardableResult
    func requestAlarms() async -> Bool {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            let state = (try? await AlarmManager.shared.requestAuthorization()) ?? .denied
            alarms = state == .authorized ? .granted : .denied
            return state == .authorized
        }
        #endif
        alarms = .unavailable
        return false
    }

    func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
