import Foundation
import Observation
import SleepCore
import SwiftUI
import UIKit

/// Runs one night of sleep tracking.
///
/// Sensor services (microphone, accelerometer or the simulator) stream epoch summaries and events
/// to this controller on the main actor. Every finished epoch is appended to the crash-safe journal,
/// fed to the online sleep estimator and to the Smart Alarm engine. When the night ends, SleepCore
/// assembles the final analysis, which is saved to SwiftData and shown as the morning report.
@MainActor
@Observable
final class TrackingController {
    struct ActiveSession {
        var header: SessionHeader
        var occurrence: AlarmOccurrence?
        var isSimulated: Bool
    }

    enum SensorState: Equatable {
        case starting
        case active
        case interrupted(String)
    }

    enum StopReason {
        case user
        case alarm
        case recovered
    }

    private(set) var lifecycle = TrackingLifecycle()
    private(set) var active: ActiveSession?
    private(set) var level: LevelReading?
    private(set) var estimate: OnlineEstimate?
    private(set) var soundCounts: [SoundEventType: Int] = [:]
    private(set) var movementCount = 0
    private(set) var epochCount = 0
    private(set) var sensorState: SensorState = .starting
    private(set) var smartWakeReason: WakeReason?
    private(set) var simulatedNow: Date?
    /// Set when a night has been saved; the UI shows its report.
    private(set) var completedSessionID: UUID?
    private(set) var completedWasSimulated = false
    private(set) var recovered: RecoveredSession?
    private(set) var errorMessage: String?
    private(set) var isPlaybackActive = false

    var phase: TrackingPhase { lifecycle.phase }
    var isTracking: Bool { lifecycle.isActive }

    private let settings: AppSettings
    private let store: SleepStore
    private let alarms: AlarmCoordinator
    private let diagnostics: DiagnosticsLog

    @ObservationIgnored private var audio: AudioCaptureService?
    @ObservationIgnored private var motion: MotionCaptureService?
    @ObservationIgnored private var simulator: SimulatedNightSource?
    @ObservationIgnored private var journal: SessionJournal?
    @ObservationIgnored private var combiner: EpochCombiner?
    @ObservationIgnored private var estimator: OnlineSleepEstimator?
    @ObservationIgnored private var engine = SmartAlarmEngine()
    @ObservationIgnored private var epochs: [EpochFeatures] = []
    @ObservationIgnored private var sounds: [SoundEvent] = []
    @ObservationIgnored private var movements: [MovementEvent] = []
    @ObservationIgnored private var markers: [SessionMarker] = []
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    @ObservationIgnored private var interruptionStart: Date?
    @ObservationIgnored private var lastThermalMarker: Date?
    @ObservationIgnored private var lowBatteryMarked = false

    init(settings: AppSettings, store: SleepStore, alarms: AlarmCoordinator, diagnostics: DiagnosticsLog) {
        self.settings = settings
        self.store = store
        self.alarms = alarms
        self.diagnostics = diagnostics
    }

    // MARK: - Start

    func start(method: TrackingMethod, simulated: Bool) async throws {
        guard lifecycle.handle(.start) else { return }
        errorMessage = nil
        completedSessionID = nil
        let now = Date()

        var occurrence: AlarmOccurrence?
        if simulated {
            let source = SimulatedNightSource(method: method, start: now, interval: AppEnvironment.isUITesting ? 0.004 : 0.02)
            simulator = source
            if settings.alarm.isEnabled {
                let deadline = source.simulatedEnd.addingTimeInterval(-5 * 60)
                occurrence = AlarmOccurrence(key: "simulated", deadline: deadline, windowStart: deadline.addingTimeInterval(-settings.alarm.effectiveWindow))
            }
        } else {
            await alarms.reconcile(now: now)
            if let next = alarms.nextOccurrence, next.deadline.timeIntervalSince(now) < 18 * 3600 {
                occurrence = next
            }
        }

        let header = SessionHeader(
            start: now,
            method: method,
            alarm: occurrence,
            smartAlarmEnabled: settings.alarm.isSmartEnabled && occurrence != nil,
            sleepGoal: settings.sleepGoal,
            isSimulated: simulated,
            appVersion: AppEnvironment.appVersion,
            timeZoneIdentifier: TimeZone.current.identifier
        )
        let journal = SessionJournal(directory: simulated ? FileLocations.simulatedSession : FileLocations.activeSession) { url in
            FileLocations.protectJournalFile(url)
        }
        do {
            try journal.start(header)
        } catch {
            lifecycle.handle(.failed)
            simulator = nil
            diagnostics.error("tracking", "Journal could not be created: \(error.localizedDescription)")
            throw error
        }
        self.journal = journal
        resetNight()
        active = ActiveSession(header: header, occurrence: occurrence, isSimulated: simulated)
        combiner = EpochCombiner(sessionStart: now, method: method, secondaryExpected: false)
        estimator = OnlineSleepEstimator(method: method)

        do {
            try startSensors(method: method, header: header)
        } catch {
            await stopSensors()
            try? journal.discard()
            self.journal = nil
            active = nil
            lifecycle.handle(.failed)
            errorMessage = error.localizedDescription
            diagnostics.error("tracking", "Start failed: \(error.localizedDescription)")
            throw error
        }
        lifecycle.handle(.started)
        sensorState = .starting
        UIApplication.shared.isIdleTimerDisabled = method == .motion || simulated
        addMarker(.batteryLevel, detail: TrackingController.batteryDescription())
        startWatchdog()
        diagnostics.info("tracking", "Started \(method.rawValue)\(simulated ? " (simulated)" : "")")
    }

    private func startSensors(method: TrackingMethod, header: SessionHeader) throws {
        if let simulator {
            consume(simulator.outputs)
            simulator.start()
            return
        }
        switch method {
        case .microphone:
            guard PermissionCenter.currentMicrophoneState() == .granted else { throw CaptureError.microphoneDenied }
            try AudioSessionCoordinator.shared.setRecording(true)
            let audio = AudioCaptureService(configuration: .init(
                sessionStart: header.start,
                saveClips: settings.saveSoundClips,
                useSoundModel: settings.useSoundModel
            ))
            try audio.start()
            audio.setPlaybackMasked(isPlaybackActive)
            self.audio = audio
            consume(audio.outputs)
            // The accelerometer notices when the phone is picked up (a strong sign of being awake).
            let motion = MotionCaptureService(sessionStart: header.start, rate: 10)
            if motion.isAvailable, (try? motion.start()) != nil {
                self.motion = motion
                consume(motion.outputs)
                combiner?.secondaryExpected = true
            }
        case .motion:
            let motion = MotionCaptureService(sessionStart: header.start, rate: 20)
            try motion.start()
            self.motion = motion
            consume(motion.outputs)
        }
    }

    private func consume(_ stream: AsyncStream<SensorOutput>) {
        tasks.append(Task { [weak self] in
            for await output in stream {
                self?.handle(output)
            }
        })
    }

    // MARK: - Incoming data

    private func handle(_ output: SensorOutput) {
        guard lifecycle.isActive || lifecycle.phase == .finishing else { return }
        switch output {
        case .acousticEpoch(let summary):
            markSensorsActive()
            ingest(combiner?.add(summary) ?? [])
        case .motionEpoch(let summary):
            if active?.header.method == .motion { markSensorsActive() }
            ingest(combiner?.add(summary) ?? [])
        case .epoch(let epoch):
            markSensorsActive()
            ingest([epoch])
        case .soundEvent(let event):
            sounds.append(event)
            soundCounts[event.type, default: 0] += 1
            try? journal?.append(event)
        case .movement(let event):
            movements.append(event)
            if event.kind != .pickup { movementCount += 1 }
            try? journal?.append(event)
        case .level(let reading):
            level = reading
        case .interruption(let began, let reason):
            handleInterruption(began: began, reason: reason)
        case .failure(let message):
            diagnostics.error("tracking", message)
            errorMessage = message
        }
    }

    private func markSensorsActive() {
        if sensorState != .active {
            if interruptionStart != nil {
                addMarker(.trackingResumed)
                interruptionStart = nil
            }
            sensorState = .active
        }
    }

    private func ingest(_ newEpochs: [EpochFeatures]) {
        for epoch in newEpochs {
            epochs.append(epoch)
            epochCount = epochs.count
            try? journal?.append(epoch)
            let estimate = estimator?.update(with: epoch)
            self.estimate = estimate
            let now = active?.isSimulated == true ? epoch.end : Date()
            if active?.isSimulated == true { simulatedNow = epoch.end }
            evaluateAlarm(now: now, estimate: estimate)
        }
    }

    private func evaluateAlarm(now: Date, estimate: OnlineEstimate?) {
        guard let active, let occurrence = active.occurrence, lifecycle.phase == .tracking else { return }
        if active.isSimulated {
            if case .wake(let reason) = engine.evaluate(now: now, occurrence: occurrence, estimate: estimate) {
                smartWakeReason = reason
                addMarker(reason == .deadline ? .alarmRang : .smartAlarmTriggered, detail: reason.rawValue)
                lifecycle.handle(.alarmFired)
                simulator?.stop()
            }
            return
        }
        if active.header.smartAlarmEnabled, smartWakeReason == nil,
           case .wake(let reason) = engine.evaluate(now: now, occurrence: occurrence, estimate: estimate) {
            smartWakeReason = reason
            addMarker(.smartAlarmTriggered, detail: reason.rawValue)
            if reason != .deadline {
                Task { await alarms.triggerSmartWake(for: occurrence, reason: reason) }
            }
        }
        alarms.tick(now: now, occurrence: occurrence)
    }

    private func handleInterruption(began: Bool, reason: String) {
        if began {
            if interruptionStart == nil {
                interruptionStart = Date()
                addMarker(.trackingInterrupted, detail: reason)
                diagnostics.warning("tracking", "Interrupted: \(reason)")
            }
            sensorState = .interrupted(reason)
        } else {
            addMarker(.trackingResumed, detail: reason)
            interruptionStart = nil
            sensorState = .active
            diagnostics.info("tracking", "Resumed: \(reason)")
        }
    }

    // MARK: - Alarm hooks

    func alarmDidRing(occurrenceKey: String) {
        guard let active, active.occurrence?.key == occurrenceKey, lifecycle.isActive else { return }
        addMarker(.alarmRang)
        lifecycle.handle(.alarmFired)
    }

    func alarmSnoozed(occurrenceKey: String) {
        guard lifecycle.phase == .alarmRinging else { return }
        addMarker(.snoozed)
        lifecycle.handle(.snooze)
    }

    func wakeConfirmed(occurrenceKey: String) async {
        guard let active, lifecycle.isActive else { return }
        if active.isSimulated || active.occurrence?.key == occurrenceKey {
            addMarker(.alarmStopped)
            await stop(reason: .alarm)
        }
    }

    /// Relaxation audio is playing; sound events are less reliable while it lasts.
    func setPlaybackActive(_ active: Bool) {
        guard active != isPlaybackActive else { return }
        isPlaybackActive = active
        audio?.setPlaybackMasked(active)
        if lifecycle.isActive {
            addMarker(active ? .playbackStarted : .playbackStopped)
        }
    }

    /// Motion mode cannot run in the background: record the pause honestly.
    func scenePhaseChanged(_ phase: ScenePhase) {
        guard let active, lifecycle.isActive, !active.isSimulated, active.header.method == .motion else { return }
        switch phase {
        case .background:
            handleInterruption(began: true, reason: "app in background")
        case .active:
            if interruptionStart != nil { handleInterruption(began: false, reason: "app active") }
        default:
            break
        }
    }

    // MARK: - Stop

    @discardableResult
    func stop(reason: StopReason = .user) async -> UUID? {
        guard lifecycle.handle(.stop) else { return nil }
        let endTime = active?.isSimulated == true ? (simulatedNow ?? Date()) : Date()
        watchdog?.cancel()
        watchdog = nil
        await stopSensors()
        ingest(combiner?.flush() ?? [])
        for task in tasks { task.cancel() }
        tasks.removeAll()
        try? AudioSessionCoordinator.shared.setRecording(false)
        UIApplication.shared.isIdleTimerDisabled = false
        addMarker(.batteryLevel, detail: TrackingController.batteryDescription())
        addMarker(.ended)

        guard let active else {
            lifecycle.handle(.failed)
            return nil
        }
        let demo = active.isSimulated
        let input = SessionAssemblyInput(
            header: active.header,
            end: endTime,
            epochs: epochs,
            soundEvents: sounds,
            movementEvents: movements,
            markers: markers,
            history: store.history(before: active.header.start, demo: demo),
            previousScore: store.previousScore(before: active.header.start, demo: demo),
            weights: settings.scoreWeights,
            calendar: .current
        )
        let completed = await Task.detached(priority: .userInitiated) {
            SessionAssembler.assemble(input)
        }.value

        do {
            try store.save(completed, demo: demo)
            try? journal?.discard()
            journal = nil
            completedSessionID = completed.id
            completedWasSimulated = demo
            lifecycle.handle(.finished)
            diagnostics.info("tracking", "Night saved: score \(completed.score.value), \(epochs.count) epochs")
        } catch {
            // Keep the journal: the night can be recovered on the next launch.
            journal?.close()
            journal = nil
            errorMessage = error.localizedDescription
            diagnostics.error("tracking", "Saving failed: \(error.localizedDescription)")
            lifecycle.handle(.failed)
        }
        if !demo && reason == .user {
            alarms.sessionEndedByUser(occurrence: active.header.alarm, at: endTime)
        }
        self.active = nil
        resetNight()
        return completedSessionID
    }

    private func stopSensors() async {
        var finals: [SensorOutput] = []
        if let audio { finals += await audio.stop() }
        if let motion { finals += await motion.stop() }
        simulator?.stop()
        audio = nil
        motion = nil
        simulator = nil
        for output in finals { handle(output) }
    }

    /// Called when the report of the finished night has been shown.
    func acknowledgeCompletedSession() {
        completedSessionID = nil
        if lifecycle.phase == .finished { lifecycle.handle(.reset) }
    }

    private func resetNight() {
        epochs.removeAll()
        sounds.removeAll()
        movements.removeAll()
        markers.removeAll()
        soundCounts.removeAll()
        movementCount = 0
        epochCount = 0
        level = nil
        estimate = nil
        smartWakeReason = nil
        simulatedNow = nil
        interruptionStart = nil
        lowBatteryMarked = false
        engine = SmartAlarmEngine()
    }

    private func addMarker(_ kind: MarkerKind, detail: String? = nil) {
        let time = active?.isSimulated == true ? (simulatedNow ?? Date()) : Date()
        let marker = SessionMarker(time: time, kind: kind, detail: detail)
        markers.append(marker)
        try? journal?.append(marker)
    }

    // MARK: - Watchdog

    private func startWatchdog() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                self?.checkHealth()
            }
        }
    }

    private func checkHealth() {
        guard lifecycle.isActive, let active, !active.isSimulated else { return }
        if let audio {
            let silence = audio.secondsSinceLastBuffer()
            if silence > 20 {
                handleInterruption(began: true, reason: "no audio for \(Int(silence)) s")
                audio.restartIfNeeded(reason: "watchdog")
            }
        }
        let thermal = ProcessInfo.processInfo.thermalState
        if thermal == .serious || thermal == .critical {
            if lastThermalMarker.map({ Date().timeIntervalSince($0) > 3600 }) ?? true {
                lastThermalMarker = Date()
                addMarker(.thermalWarning, detail: thermal == .critical ? "critical" : "serious")
                diagnostics.warning("tracking", "Phone is warm (\(thermal == .critical ? "critical" : "serious")); model classification paused")
            }
        }
        UIDevice.current.isBatteryMonitoringEnabled = true
        let battery = UIDevice.current.batteryLevel
        if battery >= 0, battery < 0.1, UIDevice.current.batteryState == .unplugged, !lowBatteryMarked {
            lowBatteryMarked = true
            addMarker(.lowBattery, detail: TrackingController.batteryDescription())
            diagnostics.warning("tracking", "Battery below 10 % while tracking")
        }
        // Make sure the alarm logic runs even if no epoch arrived recently.
        if let occurrence = active.occurrence {
            alarms.tick(now: Date(), occurrence: occurrence)
        }
    }

    static func batteryDescription() -> String {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel
        let state: String
        switch UIDevice.current.batteryState {
        case .charging: state = "charging"
        case .full: state = "full"
        case .unplugged: state = "unplugged"
        default: state = "unknown"
        }
        return level >= 0 ? "\(Int((level * 100).rounded())) % \(state)" : state
    }

    // MARK: - Recovery

    /// Looks for a night that was interrupted by the app being terminated.
    func checkForRecovery() {
        guard !lifecycle.isActive else { return }
        // Simulated nights are not worth recovering.
        if SessionJournal.exists(at: FileLocations.simulatedSession) {
            try? SessionJournal(directory: FileLocations.simulatedSession).discard()
        }
        guard let found = SessionJournal.recover(from: FileLocations.activeSession) else {
            recovered = nil
            return
        }
        if store.session(id: found.header.id, demo: false) != nil {
            // Already saved before the app ended; just clean up.
            try? SessionJournal(directory: FileLocations.activeSession).discard()
            recovered = nil
            return
        }
        recovered = found
        diagnostics.warning("tracking", "Found interrupted night from \(found.header.start.formatted(date: .abbreviated, time: .shortened))")
    }

    /// Whether continuing the interrupted night still makes sense.
    var canResumeRecovered: Bool {
        guard let recovered else { return false }
        return Date().timeIntervalSince(recovered.lastRecordedTime) < 3 * 3600 && Date().timeIntervalSince(recovered.header.start) < 14 * 3600
    }

    /// Saves the interrupted night with the data recorded so far.
    func finishRecovered() async {
        guard let recovered else { return }
        var markers = recovered.markers
        markers.append(SessionMarker(time: recovered.lastRecordedTime, kind: .recovered, detail: "saved after interruption"))
        let input = SessionAssemblyInput(
            header: recovered.header,
            end: max(recovered.lastRecordedTime, recovered.header.start.addingTimeInterval(60)),
            epochs: recovered.epochs,
            soundEvents: recovered.soundEvents,
            movementEvents: recovered.movementEvents,
            markers: markers,
            history: store.history(before: recovered.header.start, demo: false),
            previousScore: store.previousScore(before: recovered.header.start, demo: false),
            weights: settings.scoreWeights
        )
        let completed = await Task.detached(priority: .userInitiated) { SessionAssembler.assemble(input) }.value
        do {
            try store.save(completed, demo: false)
            try? SessionJournal(directory: FileLocations.activeSession).discard()
            self.recovered = nil
            completedSessionID = completed.id
            completedWasSimulated = false
            diagnostics.info("tracking", "Recovered night saved")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Continues tracking the interrupted night (same start time; the gap is recorded).
    func resumeRecovered() async throws {
        guard let recovered, lifecycle.handle(.recover) else { return }
        let header = recovered.header
        let journal = SessionJournal(directory: FileLocations.activeSession) { url in FileLocations.protectJournalFile(url) }
        journal.resume(header)
        self.journal = journal
        resetNight()
        epochs = recovered.epochs.sorted { $0.index < $1.index }
        sounds = recovered.soundEvents
        movements = recovered.movementEvents
        markers = recovered.markers
        epochCount = epochs.count
        for event in sounds { soundCounts[event.type, default: 0] += 1 }
        movementCount = movements.filter { $0.kind != .pickup }.count
        let estimator = OnlineSleepEstimator(method: header.method)
        for epoch in epochs { estimate = estimator.update(with: epoch) }
        self.estimator = estimator
        var combiner = EpochCombiner(sessionStart: header.start, method: header.method, secondaryExpected: false)
        if let last = epochs.last {
            // Prime the combiner so older indices are ignored.
            _ = combiner.add(AcousticEpochSummary(epochIndex: last.index))
            _ = combiner.flush()
        }
        self.combiner = combiner
        var occurrence = header.alarm
        if let alarm = occurrence, alarm.deadline < Date() { occurrence = nil }
        active = ActiveSession(header: header, occurrence: occurrence, isSimulated: false)
        addMarker(.recovered, detail: "resumed")
        self.recovered = nil
        do {
            try startSensors(method: header.method, header: header)
            sensorState = .starting
            UIApplication.shared.isIdleTimerDisabled = header.method == .motion
            startWatchdog()
            diagnostics.info("tracking", "Resumed interrupted night")
        } catch {
            errorMessage = error.localizedDescription
            await stop(reason: .recovered)
            throw error
        }
    }

    func clearError() {
        errorMessage = nil
    }

    func discardRecovered() {
        try? SessionJournal(directory: FileLocations.activeSession).discard()
        recovered = nil
        diagnostics.info("tracking", "Interrupted night discarded by user")
    }
}
