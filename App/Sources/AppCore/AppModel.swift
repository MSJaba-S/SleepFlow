import Foundation
import Observation
import SwiftData
import SwiftUI
import UserNotifications
import SleepCore

enum AppTab: Hashable {
    case today, statistics, journal, relax, settings
}

/// A report to present: which night, and from which store.
struct ReportRoute: Identifiable, Hashable {
    let sessionID: UUID
    let demo: Bool
    var id: UUID { sessionID }
}

/// Composition root: creates the services once and wires them together.
@MainActor
@Observable
final class AppModel {
    let settings: AppSettings
    let diagnostics: DiagnosticsLog
    let permissions: PermissionCenter
    let store: SleepStore
    let alarms: AlarmCoordinator
    let tracking: TrackingController
    let relaxation: RelaxationController

    var selectedTab: AppTab = .today
    var reportRoute: ReportRoute?
    var isGeneratingDemoData = false
    /// Increments when stored data changes outside SwiftData queries (forces refresh).
    private(set) var dataVersion = 0

    private let notificationDelegate = NotificationDelegate()
    @ObservationIgnored private var launched = false

    init() {
        if AppEnvironment.resetState, let domain = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: domain)
        }
        FileLocations.prepare()
        let settings = AppSettings()
        if AppEnvironment.skipOnboarding { settings.hasCompletedOnboarding = true }
        if AppEnvironment.isUITesting { settings.demoMode = AppEnvironment.seedDemoData }
        self.settings = settings
        let diagnostics = DiagnosticsLog(persistent: !AppEnvironment.usesInMemoryStorage)
        self.diagnostics = diagnostics
        permissions = PermissionCenter()
        let store = SleepStore(inMemory: AppEnvironment.usesInMemoryStorage)
        self.store = store
        let alarms = AlarmCoordinator(
            settings: settings,
            diagnostics: diagnostics,
            scheduler: AppEnvironment.usesInMemoryStorage ? NotificationAlarmScheduler() : nil
        )
        self.alarms = alarms
        let tracking = TrackingController(settings: settings, store: store, alarms: alarms, diagnostics: diagnostics)
        self.tracking = tracking
        relaxation = RelaxationController()
        wire()
    }

    private func wire() {
        alarms.onAlarmRang = { [weak self] key in self?.tracking.alarmDidRing(occurrenceKey: key) }
        alarms.onSnoozed = { [weak self] key in self?.tracking.alarmSnoozed(occurrenceKey: key) }
        alarms.onWakeConfirmed = { [weak self] key in
            guard let self else { return }
            Task { await self.tracking.wakeConfirmed(occurrenceKey: key) }
        }
        relaxation.onPlaybackChanged = { [weak self] playing in self?.tracking.setPlaybackActive(playing) }
        notificationDelegate.alarms = alarms
        UNUserNotificationCenter.current().delegate = notificationDelegate
    }

    var isDemo: Bool { settings.demoMode }
    var activeContainer: ModelContainer { store.container(demo: settings.demoMode) }

    /// The wake-up screen is shown while an alarm rings or the simulated night reached its alarm.
    var showsWakeUp: Bool {
        alarms.isRinging || tracking.phase == .alarmRinging
    }

    /// Drives the full-screen night/wake-up cover. Dismissal is controlled by tracking state only:
    /// the cover stays while sensors start and while the finished night is being analysed.
    var isNightCoverPresented: Bool {
        get {
            tracking.isTracking || showsWakeUp || tracking.phase == .starting || tracking.phase == .finishing
        }
        set { _ = newValue }
    }

    // MARK: - Lifecycle

    func onLaunch() async {
        guard !launched else { return }
        launched = true
        await permissions.refresh()
        await alarms.refreshAuthorization()
        alarms.startObservingSystemAlarms()
        await alarms.reconcile()
        tracking.checkForRecovery()
        if AppEnvironment.isUITesting && AppEnvironment.seedDemoData {
            await generateDemoData(nights: 21)
        }
        diagnostics.info("app", "Launched \(AppEnvironment.appVersion) (\(AppEnvironment.buildNumber))")
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        tracking.scenePhaseChanged(phase)
        guard phase == .active, launched else { return }
        Task {
            await permissions.refresh()
            await alarms.refreshAuthorization()
            await alarms.reconcile()
        }
    }

    // MARK: - Actions

    /// Starts a night. In demo mode (and in UI tests) the night simulator replaces the sensors.
    func startTracking() async throws {
        let simulated = settings.demoMode || AppEnvironment.useSimulatedSensors
        try await tracking.start(method: settings.trackingMethod, simulated: simulated)
    }

    /// Ends the night. The report is presented by the root view once the night screen has closed.
    func stopTracking() async {
        await tracking.stop(reason: .user)
    }

    func presentCompletedReportIfNeeded() {
        if let id = tracking.completedSessionID {
            reportRoute = ReportRoute(sessionID: id, demo: tracking.completedWasSimulated)
            tracking.acknowledgeCompletedSession()
            dataVersion += 1
        }
    }

    func alarmChanged() {
        Task { await alarms.reconcile() }
    }

    /// Switches between real and demo data. Turning demo mode on for the first time creates demo nights.
    var demoModeEnabled: Bool {
        get { settings.demoMode }
        set {
            guard newValue != settings.demoMode else { return }
            settings.demoMode = newValue
            if newValue && store.sessions(demo: true).isEmpty && !isGeneratingDemoData {
                Task { await generateDemoData() }
            }
        }
    }

    func generateDemoData(nights: Int = 30) async {
        isGeneratingDemoData = true
        await DemoDataGenerator.populate(store: store, settings: settings, nights: nights)
        isGeneratingDemoData = false
        dataVersion += 1
    }

    /// Applies the current score weighting to all stored nights of the active store.
    func rescoreStoredNights() {
        store.rescoreAll(weights: settings.scoreWeights, demo: settings.demoMode)
        dataVersion += 1
    }

    func clearDemoData() {
        store.deleteAll(demo: true)
        dataVersion += 1
    }

    /// GDPR erasure: every session, journal entry, clip, journal file and the diagnostics log.
    func deleteAllPersonalData() {
        store.deleteAll(demo: false)
        FileLocations.deleteAllClips()
        tracking.discardRecovered()
        diagnostics.clear()
        dataVersion += 1
    }
}

/// Receives notification taps for the fallback alarm.
@MainActor
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    weak var alarms: AlarmCoordinator?

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let info = notification.request.content.userInfo
        let key = info["occurrenceKey"] as? String
        let role = info["role"] as? String
        if key != nil {
            await MainActor.run {
                self.alarms?.notificationDelivered(occurrenceKey: key, role: role)
            }
        }
        return [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        let key = response.notification.request.content.userInfo["occurrenceKey"] as? String
        await handle(action: action, key: key)
    }

    private func handle(action: String, key: String?) async {
        guard let alarms else { return }
        if action == UNNotificationDefaultActionIdentifier {
            // Opening the notification shows the wake-up screen; the user stops it there.
            alarms.notificationDelivered(occurrenceKey: key, role: nil)
        } else {
            await alarms.handleNotificationAction(action, occurrenceKey: key)
        }
    }
}
