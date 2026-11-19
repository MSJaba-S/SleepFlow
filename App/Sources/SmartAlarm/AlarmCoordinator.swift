import Foundation
import Observation
import SleepCore
import UIKit
import UserNotifications
#if canImport(AlarmKit)
import AlarmKit
#endif

/// Keeps the system alarms in sync with the user's settings and runs the wake-up flow.
///
/// Guarantees:
/// * Every upcoming wake-up has a system alarm at its deadline (AlarmKit on iOS 26+, otherwise a
///   burst of local notifications). The Smart Alarm can only ring *earlier*; it never removes the
///   deadline alarm until the user has actually stopped an alarm for that morning.
/// * With AlarmKit, a backup notification follows one minute after the deadline.
/// * The schedule is reconciled on launch, when the app becomes active, after settings changes,
///   time-zone changes and significant time changes (daylight saving, manual clock changes).
@MainActor
@Observable
final class AlarmCoordinator {
    enum RingState: Equatable {
        case idle
        case ringing(since: Date, occurrenceKey: String, role: ScheduledAlarmRecord.Role)
        case snoozed(until: Date, occurrenceKey: String)
    }

    private(set) var nextOccurrence: AlarmOccurrence?
    /// A one-off "wake after sleep" alarm for the nap or cycles being tracked right now.
    private(set) var napOccurrence: AlarmOccurrence?
    private(set) var ringState: RingState = .idle
    private(set) var authorization: PermissionState = .notDetermined
    private(set) var lastReconciled: Date?
    private(set) var lastError: String?

    /// Called when the user stops an alarm (in the app, on the Lock Screen or via a notification).
    @ObservationIgnored var onWakeConfirmed: ((String) -> Void)?
    /// Called when an alarm starts ringing.
    @ObservationIgnored var onAlarmRang: ((String) -> Void)?
    @ObservationIgnored var onSnoozed: ((String) -> Void)?

    private let settings: AppSettings
    private let diagnostics: DiagnosticsLog
    private let notifications = NotificationAlarmScheduler()
    private let primary: any AlarmScheduling
    private let player = AlarmSoundPlayer()
    private var records: [ScheduledAlarmRecord] = []
    private var suppressed: [String: Date] = [:]
    private var observers: [NSObjectProtocol] = []
    private var updatesTask: Task<Void, Never>?

    private static let recordsKey = "alarm.records"
    private static let suppressedKey = "alarm.suppressed"
    private static let napKey = "alarm.nap"

    init(settings: AppSettings, diagnostics: DiagnosticsLog, scheduler: (any AlarmScheduling)? = nil) {
        self.settings = settings
        self.diagnostics = diagnostics
        if let scheduler {
            primary = scheduler
        } else {
            primary = AlarmCoordinator.makeDefaultScheduler(fallback: nil)
        }
        loadState()
        installObservers()
    }

    static func makeDefaultScheduler(fallback: NotificationAlarmScheduler?) -> any AlarmScheduling {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            return AlarmKitScheduler()
        }
        #endif
        return fallback ?? NotificationAlarmScheduler()
    }

    /// The mechanism used for the main alarm right now.
    var activeBackendName: String { usesPrimary ? primary.backendName : notifications.backendName }
    var ringsThroughSilentMode: Bool { usesPrimary && primary.breaksThroughSilentMode }

    private var usesPrimary: Bool {
        primary.backendName != notifications.backendName && primary.authorization() != .denied
    }

    var isRinging: Bool {
        if case .ringing = ringState { return true }
        return false
    }

    // MARK: - Permissions

    func refreshAuthorization() async {
        await notifications.refreshAuthorization()
        authorization = usesPrimary ? primary.authorization() : notifications.authorization()
    }

    func requestAuthorization() async {
        if primary.backendName != notifications.backendName {
            _ = await primary.requestAuthorization()
        }
        _ = await notifications.requestAuthorization()
        await refreshAuthorization()
        await reconcile()
    }

    // MARK: - Reconciliation

    func reconcile(now: Date = Date()) async {
        processInbox()
        pruneSuppressed(now: now)
        let calendar = Calendar.current
        var desired = AlarmOccurrencePlanner.upcoming(settings: settings.alarm, after: now, calendar: calendar, horizonDays: 7)
        if let nap = napOccurrence {
            if nap.deadline > now.addingTimeInterval(-30 * 60) && !isSuppressed(nap.key) {
                if nap.deadline > now { desired.append(nap) }
            } else {
                napOccurrence = nil
            }
            desired.sort { $0.deadline < $1.deadline }
        }
        nextOccurrence = desired.first { !isSuppressed($0.key) }

        let deadlineRecords = records.filter { $0.role == .deadline && $0.backend == activeBackendName }
        let staleBackend = records.filter { $0.role == .deadline && $0.backend != activeBackendName && $0.backend != "backup" }
        for record in staleBackend { cancelInSystem(record) }
        records.removeAll { record in staleBackend.contains { $0.alarmID == record.alarmID } }

        let plan = AlarmReconciler.reconcile(desired: desired, scheduled: deadlineRecords, suppressedKeys: Set(suppressed.keys), now: now)
        for record in plan.toCancel {
            if record.fireDate <= now {
                // Already due – it may be ringing right now. Only the user (or iOS) stops it; the
                // record is forgotten after a while.
                if record.fireDate < now.addingTimeInterval(-2 * 3600) {
                    records.removeAll { $0.alarmID == record.alarmID }
                }
                continue
            }
            cancelInSystem(record)
            records.removeAll { $0.alarmID == record.alarmID }
            cancelBackup(for: record.occurrenceKey)
        }
        // Notifications are limited to 64 pending requests: keep at most the next three wake-ups there.
        let limit = usesPrimary ? plan.toSchedule.count : min(plan.toSchedule.count, max(0, 3 - plan.toKeep.count))
        for occurrence in plan.toSchedule.prefix(limit) {
            await scheduleDeadline(occurrence)
        }
        // Past records are dropped.
        records.removeAll { $0.fireDate < now.addingTimeInterval(-6 * 3600) }
        ensureBackupForNext(now: now)
        lastReconciled = now
        saveState()
    }

    private func scheduleDeadline(_ occurrence: AlarmOccurrence) async {
        do {
            let scheduler: any AlarmScheduling = usesPrimary ? primary : notifications
            let id = try await scheduler.schedule(fireDate: occurrence.deadline, occurrenceKey: occurrence.key, role: .deadline, settings: settings.alarm)
            records.append(ScheduledAlarmRecord(occurrenceKey: occurrence.key, alarmID: id, fireDate: occurrence.deadline, role: .deadline, backend: scheduler.backendName))
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            diagnostics.error("alarm", "Could not schedule \(occurrence.key): \(error.localizedDescription)")
        }
    }

    /// With AlarmKit as primary, one notification burst a minute after the next deadline is a backup.
    private func ensureBackupForNext(now: Date) {
        guard usesPrimary, let next = nextOccurrence else { return }
        let backupDate = next.deadline.addingTimeInterval(60)
        let hasBackup = records.contains {
            $0.role == .deadline && $0.backend == "backup" && $0.occurrenceKey == next.key && abs($0.fireDate.timeIntervalSince(backupDate)) < 30
        }
        if hasBackup { return }
        // Remove backups for other occurrences.
        for record in records where record.backend == "backup" { notifications.cancel(alarmID: record.alarmID) }
        records.removeAll { $0.backend == "backup" }
        Task {
            notifications.burstCount = 3
            if let id = try? await notifications.schedule(fireDate: next.deadline.addingTimeInterval(60), occurrenceKey: next.key, role: .deadline, settings: settings.alarm) {
                records.append(ScheduledAlarmRecord(occurrenceKey: next.key, alarmID: id, fireDate: next.deadline.addingTimeInterval(60), role: .deadline, backend: "backup"))
                saveState()
            }
            notifications.burstCount = 8
        }
    }

    private func cancelBackup(for key: String) {
        for record in records where record.backend == "backup" && record.occurrenceKey == key {
            notifications.cancel(alarmID: record.alarmID)
        }
        records.removeAll { $0.backend == "backup" && $0.occurrenceKey == key }
    }

    private func cancelInSystem(_ record: ScheduledAlarmRecord) {
        if record.backend == primary.backendName {
            primary.cancel(alarmID: record.alarmID)
        } else {
            notifications.cancel(alarmID: record.alarmID)
        }
    }

    // MARK: - Wake after sleep

    /// Schedules the system alarm for a nap at its latest possible time. When sleep onset is
    /// detected, `updateNap` moves it earlier.
    func beginNap(_ occurrence: AlarmOccurrence) async {
        if let previous = napOccurrence, previous.key != occurrence.key {
            cancelAlarms(for: previous.key)
        }
        napOccurrence = occurrence
        diagnostics.info("alarm", "Nap alarm set for \(Formatters.time(occurrence.deadline))")
        saveState()
        await reconcile()
    }

    /// Sleep onset is known: the nap's deadline (and window) move – only ever earlier.
    func updateNap(_ occurrence: AlarmOccurrence) async {
        guard let current = napOccurrence, current.key == occurrence.key else { return }
        guard occurrence.deadline < current.deadline.addingTimeInterval(-1) else { return }
        napOccurrence = occurrence
        diagnostics.info("alarm", "Nap alarm moved to \(Formatters.time(occurrence.deadline))")
        saveState()
        await reconcile()
    }

    private func cancelAlarms(for key: String) {
        for record in records where record.occurrenceKey == key {
            cancelInSystem(record)
        }
        records.removeAll { $0.occurrenceKey == key }
    }

    // MARK: - Smart Alarm

    /// Rings now because the sleeper is in a light phase inside the window.
    func triggerSmartWake(for occurrence: AlarmOccurrence, reason: WakeReason) async {
        guard !isSuppressed(occurrence.key) else { return }
        diagnostics.info("alarm", "Smart Alarm (\(reason.rawValue)) for \(occurrence.key)")
        if usesPrimary {
            do {
                let id = try await primary.schedule(fireDate: Date().addingTimeInterval(1), occurrenceKey: occurrence.key, role: .smart, settings: settings.alarm)
                records.append(ScheduledAlarmRecord(occurrenceKey: occurrence.key, alarmID: id, fireDate: Date(), role: .smart, backend: primary.backendName))
                saveState()
                return
            } catch {
                diagnostics.error("alarm", "AlarmKit smart alarm failed: \(error.localizedDescription)")
            }
        }
        // Fallback: the app is running (it just evaluated the window), so it rings itself.
        startInAppRinging(occurrenceKey: occurrence.key, role: .smart)
    }

    /// Called every epoch while tracking: rings in-app at the deadline when no system alarm can.
    func tick(now: Date, occurrence: AlarmOccurrence?) {
        guard let occurrence, !usesPrimary, !isRinging, !isSuppressed(occurrence.key) else { return }
        if case .snoozed(let until, let key) = ringState, key == occurrence.key {
            if now >= until { startInAppRinging(occurrenceKey: key, role: .snooze) }
            return
        }
        if now >= occurrence.deadline && now < occurrence.deadline.addingTimeInterval(30 * 60) {
            startInAppRinging(occurrenceKey: occurrence.key, role: .deadline)
        }
    }

    private func startInAppRinging(occurrenceKey: String, role: ScheduledAlarmRecord.Role) {
        ringState = .ringing(since: Date(), occurrenceKey: occurrenceKey, role: role)
        player.ring(AlarmSound.sound(id: settings.alarm.soundID), vibrate: settings.alarm.vibrationEnabled)
        onAlarmRang?(occurrenceKey)
    }

    // MARK: - Stop and snooze

    /// The user is awake: stop everything for this morning and never ring again for it.
    func stopRinging() {
        let key = currentKey
        player.stop()
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *), let kit = primary as? AlarmKitScheduler {
            for id in kit.alertingAlarmIDs() { kit.stop(alarmID: id) }
        }
        #endif
        if let key { confirmWake(occurrenceKey: key) }
        ringState = .idle
    }

    func snooze() async {
        guard case .ringing(_, let key, _) = ringState else { return }
        player.stop()
        let until = Date().addingTimeInterval(TimeInterval(settings.alarm.snoozeMinutes * 60))
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *), let kit = primary as? AlarmKitScheduler, usesPrimary {
            for id in kit.alertingAlarmIDs() { kit.stop(alarmID: id) }
            if let id = try? await kit.schedule(fireDate: until, occurrenceKey: key, role: .snooze, settings: settings.alarm) {
                records.append(ScheduledAlarmRecord(occurrenceKey: key, alarmID: id, fireDate: until, role: .snooze, backend: kit.backendName))
            }
        }
        #endif
        if !usesPrimary {
            notifications.burstCount = 3
            if let id = try? await notifications.schedule(fireDate: until, occurrenceKey: key, role: .snooze, settings: settings.alarm) {
                records.append(ScheduledAlarmRecord(occurrenceKey: key, alarmID: id, fireDate: until, role: .snooze, backend: notifications.backendName))
            }
            notifications.burstCount = 8
        }
        ringState = .snoozed(until: until, occurrenceKey: key)
        saveState()
        onSnoozed?(key)
    }

    private var currentKey: String? {
        switch ringState {
        case .ringing(_, let key, _): return key
        case .snoozed(_, let key): return key
        case .idle: return nextOccurrence.flatMap { $0.deadline.timeIntervalSinceNow < 3 * 3600 ? $0.key : nil }
        }
    }

    /// Cancels every remaining alarm of the occurrence and remembers that it has been handled.
    func confirmWake(occurrenceKey key: String) {
        for record in records where record.occurrenceKey == key {
            cancelInSystem(record)
            if record.backend == "backup" { notifications.cancel(alarmID: record.alarmID) }
        }
        records.removeAll { $0.occurrenceKey == key }
        suppressed[key] = Date()
        if napOccurrence?.key == key { napOccurrence = nil }
        ringState = .idle
        player.stop()
        saveState()
        diagnostics.info("alarm", "Wake-up confirmed for \(key)")
        onWakeConfirmed?(key)
        Task { await reconcile() }
    }

    /// Stop tracking before the alarm: if it is within the wake-up window or later, this morning's
    /// alarm is no longer needed.
    func sessionEndedByUser(occurrence: AlarmOccurrence?, at date: Date) {
        guard let occurrence else { return }
        // A nap belongs to this session only: stopping it early removes its alarm.
        if occurrence.key == napOccurrence?.key {
            confirmWake(occurrenceKey: occurrence.key)
            return
        }
        guard date >= occurrence.windowStart.addingTimeInterval(-15 * 60) else { return }
        confirmWake(occurrenceKey: occurrence.key)
    }

    func isSuppressed(_ key: String) -> Bool { suppressed[key] != nil }

    // MARK: - Intents and notifications

    /// Handles Stop/Snooze taps from the Lock Screen (AlarmKit) recorded by the intents.
    func processInbox() {
        for record in SnoozeLedger.drain() { records.append(record) }
        for entry in AlarmIntentInbox.drain() {
            switch entry.action {
            case .stop:
                confirmWake(occurrenceKey: entry.occurrenceKey)
            case .snooze:
                let until = Date().addingTimeInterval(TimeInterval(settings.alarm.snoozeMinutes * 60))
                ringState = .snoozed(until: until, occurrenceKey: entry.occurrenceKey)
                onSnoozed?(entry.occurrenceKey)
            }
        }
        saveState()
    }

    func handleNotificationAction(_ identifier: String, occurrenceKey: String?) async {
        let key = occurrenceKey ?? currentKey ?? ""
        switch identifier {
        case NotificationAlarmScheduler.snoozeAction:
            ringState = .ringing(since: Date(), occurrenceKey: key, role: .deadline)
            await snooze()
        default:
            if !key.isEmpty { confirmWake(occurrenceKey: key) }
        }
    }

    /// A fallback alarm notification arrived while the app is in the foreground.
    func notificationDelivered(occurrenceKey: String?, role roleName: String?) {
        guard let key = occurrenceKey, !isSuppressed(key), !isRinging else { return }
        let role = ScheduledAlarmRecord.Role(rawValue: roleName ?? "") ?? .deadline
        startInAppRinging(occurrenceKey: key, role: role)
    }

    // MARK: - System alarm updates (AlarmKit)

    func startObservingSystemAlarms() {
        #if canImport(AlarmKit)
        guard updatesTask == nil else { return }
        if #available(iOS 26.0, *) {
            updatesTask = Task { [weak self] in
                for await alarms in AlarmManager.shared.alarmUpdates {
                    self?.handleSystemAlarms(alarms.map { (id: $0.id.uuidString, alerting: $0.state == .alerting) })
                }
            }
        }
        #endif
    }

    private func handleSystemAlarms(_ alarms: [(id: String, alerting: Bool)]) {
        processInbox()
        if let ringing = alarms.first(where: { $0.alerting }),
           let record = records.first(where: { $0.alarmID == ringing.id }) {
            if !isRinging {
                ringState = .ringing(since: Date(), occurrenceKey: record.occurrenceKey, role: record.role)
                diagnostics.info("alarm", "System alarm ringing (\(record.role.rawValue)) for \(record.occurrenceKey)")
                onAlarmRang?(record.occurrenceKey)
            }
        } else if case .ringing(_, let key, _) = ringState, primary.breaksThroughSilentMode, !player.isPlaying {
            // The system alarm is no longer alerting and no intent arrived yet: treat it as stopped
            // only if none of this morning's alarms is still scheduled for the future.
            let ids = Set(alarms.map { $0.id })
            let stillPending = records.contains { $0.occurrenceKey == key && ids.contains($0.alarmID) && $0.fireDate > Date() }
            if !stillPending { ringState = .idle }
        }
    }

    // MARK: - Observers and persistence

    private func installObservers() {
        let center = NotificationCenter.default
        for name in [UIApplication.significantTimeChangeNotification, Notification.Name.NSSystemTimeZoneDidChange] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.diagnostics.info("alarm", "Clock or time zone changed; rescheduling")
                    await self?.reconcile()
                }
            })
        }
        observers.append(center.addObserver(forName: AlarmIntentInbox.notification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.processInbox() }
        })
    }

    private func pruneSuppressed(now: Date) {
        suppressed = suppressed.filter { now.timeIntervalSince($0.value) < 36 * 3600 }
    }

    private func loadState() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: AlarmCoordinator.recordsKey), let decoded = try? JSONDecoder().decode([ScheduledAlarmRecord].self, from: data) {
            records = decoded
        }
        if let data = defaults.data(forKey: AlarmCoordinator.suppressedKey), let decoded = try? JSONDecoder().decode([String: Date].self, from: data) {
            suppressed = decoded
        }
        if let data = defaults.data(forKey: AlarmCoordinator.napKey), let decoded = try? JSONDecoder().decode(AlarmOccurrence.self, from: data) {
            napOccurrence = decoded
        }
    }

    private func saveState() {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(records) { defaults.set(data, forKey: AlarmCoordinator.recordsKey) }
        if let data = try? JSONEncoder().encode(suppressed) { defaults.set(data, forKey: AlarmCoordinator.suppressedKey) }
        if let napOccurrence, let data = try? JSONEncoder().encode(napOccurrence) {
            defaults.set(data, forKey: AlarmCoordinator.napKey)
        } else {
            defaults.removeObject(forKey: AlarmCoordinator.napKey)
        }
    }

    /// Removes every scheduled alarm (used when the user deletes all data or disables the alarm).
    func cancelAll() {
        for record in records { cancelInSystem(record) }
        records.removeAll()
        napOccurrence = nil
        player.stop()
        ringState = .idle
        saveState()
    }

    var scheduledRecords: [ScheduledAlarmRecord] { records }

    func preview(soundID: String) {
        player.preview(AlarmSound.sound(id: soundID))
    }

    func stopPreview() {
        player.stop()
    }
}
