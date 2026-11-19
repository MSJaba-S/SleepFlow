import XCTest
import SwiftData
@testable import SleepFlow
import SleepCore

/// Records what the coordinator asks the system to do, without touching AlarmKit.
@MainActor
final class FakeAlarmScheduler: AlarmScheduling {
    struct Scheduled: Equatable {
        var id: String
        var fireDate: Date
        var key: String
        var role: ScheduledAlarmRecord.Role
    }

    let backendName = "FakeKit"
    let breaksThroughSilentMode = true
    private(set) var scheduled: [Scheduled] = []
    private(set) var cancelled: [String] = []

    func authorization() -> PermissionState { .granted }
    func requestAuthorization() async -> PermissionState { .granted }

    func schedule(fireDate: Date, occurrenceKey: String, role: ScheduledAlarmRecord.Role, settings: AlarmSettings) async throws -> String {
        let id = UUID().uuidString
        scheduled.append(Scheduled(id: id, fireDate: fireDate, key: occurrenceKey, role: role))
        return id
    }

    func cancel(alarmID: String) {
        cancelled.append(alarmID)
        scheduled.removeAll { $0.id == alarmID }
    }

    func stop(alarmID: String) {
        cancel(alarmID: alarmID)
    }
}

final class AlarmCoordinatorTests: XCTestCase {
    /// A coordinator with a fake system scheduler and its own settings (never the real alarms).
    @MainActor
    private func make() -> (AlarmCoordinator, FakeAlarmScheduler, AppSettings) {
        for key in ["alarm.records", "alarm.suppressed", "alarm.nap"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        let suite = "SleepFlowTests.alarm.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let settings = AppSettings(defaults: defaults)
        let scheduler = FakeAlarmScheduler()
        let coordinator = AlarmCoordinator(settings: settings, diagnostics: DiagnosticsLog(persistent: false), scheduler: scheduler)
        return (coordinator, scheduler, settings)
    }

    @MainActor
    func testReconcileSchedulesTheDeadlines() async {
        let (coordinator, scheduler, settings) = make()
        defer { coordinator.cancelAll() }
        var alarm = AlarmSettings()
        alarm.isEnabled = true
        alarm.hour = 7
        alarm.minute = 0
        alarm.weekdays = []
        settings.alarm = alarm
        await coordinator.reconcile()
        let deadlines = scheduler.scheduled.filter { $0.role == .deadline }
        XCTAssertEqual(deadlines.count, 1)
        XCTAssertEqual(Calendar.current.component(.hour, from: deadlines[0].fireDate), 7)
        XCTAssertNotNil(coordinator.nextOccurrence)
        // Reconciling again changes nothing.
        await coordinator.reconcile()
        XCTAssertEqual(scheduler.scheduled.filter { $0.role == .deadline }.count, 1)
    }

    @MainActor
    func testDisablingTheAlarmCancelsIt() async {
        let (coordinator, scheduler, settings) = make()
        defer { coordinator.cancelAll() }
        var alarm = AlarmSettings()
        alarm.isEnabled = true
        settings.alarm = alarm
        await coordinator.reconcile()
        XCTAssertFalse(scheduler.scheduled.isEmpty)
        alarm.isEnabled = false
        settings.alarm = alarm
        await coordinator.reconcile()
        XCTAssertTrue(scheduler.scheduled.filter { $0.role == .deadline }.isEmpty)
        XCTAssertNil(coordinator.nextOccurrence)
    }

    @MainActor
    func testNapAlarmOnlyMovesEarlier() async {
        let (coordinator, scheduler, settings) = make()
        defer { coordinator.cancelAll() }
        var alarm = AlarmSettings()
        alarm.isEnabled = false
        settings.alarm = alarm
        let start = Date()
        let plan = NapPlan.powerNap(minutes: 20)
        let key = NapPlan.key(start: start, calendar: .current)
        let latest = plan.occurrence(key: key, start: start, onset: nil)
        await coordinator.beginNap(latest)
        XCTAssertEqual(scheduler.scheduled.filter { $0.key == key }.map(\.fireDate), [latest.deadline])

        // Sleep onset detected 5 minutes in: the alarm moves earlier.
        let earlier = plan.occurrence(key: key, start: start, onset: start.addingTimeInterval(300))
        await coordinator.updateNap(earlier)
        XCTAssertEqual(scheduler.scheduled.filter { $0.key == key }.map(\.fireDate), [earlier.deadline])

        // A later deadline is ignored.
        await coordinator.updateNap(latest)
        XCTAssertEqual(scheduler.scheduled.filter { $0.key == key }.map(\.fireDate), [earlier.deadline])

        // Waking up removes it for good.
        coordinator.confirmWake(occurrenceKey: key)
        XCTAssertTrue(scheduler.scheduled.filter { $0.key == key }.isEmpty)
        XCTAssertNil(coordinator.napOccurrence)
    }

    @MainActor
    func testStoppingANapEarlyCancelsItsAlarm() async {
        let (coordinator, scheduler, settings) = make()
        defer { coordinator.cancelAll() }
        settings.alarm.isEnabled = false
        let start = Date()
        let plan = NapPlan.cycles(1)
        let occurrence = plan.occurrence(key: NapPlan.key(start: start, calendar: .current), start: start, onset: nil)
        await coordinator.beginNap(occurrence)
        coordinator.sessionEndedByUser(occurrence: occurrence, at: start.addingTimeInterval(120))
        XCTAssertTrue(scheduler.scheduled.filter { $0.key == occurrence.key }.isEmpty)
    }

    @MainActor
    func testSmartWakeRingsNow() async {
        let (coordinator, scheduler, _) = make()
        defer { coordinator.cancelAll() }
        let start = Date()
        let occurrence = AlarmOccurrence(key: "test", deadline: start.addingTimeInterval(600), windowStart: start)
        await coordinator.triggerSmartWake(for: occurrence, reason: .lightSleep)
        let smart = scheduler.scheduled.filter { $0.role == .smart }
        XCTAssertEqual(smart.count, 1)
        XCTAssertLessThan(smart[0].fireDate.timeIntervalSinceNow, 5)
    }
}

final class PersistenceTests: XCTestCase {
    private static func night(seed: UInt64, start: Date, nap: NapPlan? = nil) -> CompletedSession {
        let scenario = NightScenario(method: .microphone, bedtime: start, timeInBed: nap == nil ? 7 * 3600 : 45 * 60)
        let simulated = NightSimulator.simulate(scenario, seed: seed)
        let header = SessionHeader(
            start: start,
            method: .microphone,
            alarm: nil,
            smartAlarmEnabled: false,
            sleepGoal: nap?.sleepDuration ?? 8 * 3600,
            isSimulated: true,
            appVersion: "test",
            timeZoneIdentifier: TimeZone.current.identifier,
            napPlan: nap
        )
        let input = SessionAssemblyInput(header: header, end: simulated.end, epochs: simulated.epochs, soundEvents: simulated.soundEvents, movementEvents: simulated.movementEvents, markers: [])
        return SessionAssembler.assemble(input)
    }

    @MainActor
    func testSaveLoadAndDelete() throws {
        let store = SleepStore(inMemory: true)
        let session = PersistenceTests.night(seed: 1, start: Date(timeIntervalSinceNow: -86_400))
        let record = try store.save(session, demo: false)
        XCTAssertEqual(store.sessions(demo: false).count, 1)
        XCTAssertEqual(store.sessions(demo: true).count, 0, "Real and demo data are separate")
        XCTAssertEqual(record.decoded(), session)
        XCTAssertEqual(record.score, session.score.value)
        store.delete(record, demo: false)
        XCTAssertTrue(store.sessions(demo: false).isEmpty)
    }

    @MainActor
    func testNapsStayOutOfNightHistory() throws {
        let store = SleepStore(inMemory: true)
        let base = Date(timeIntervalSinceNow: -3 * 86_400)
        _ = try store.save(PersistenceTests.night(seed: 2, start: base), demo: false)
        let nap = try store.save(PersistenceTests.night(seed: 3, start: base.addingTimeInterval(36 * 3600), nap: .powerNap(minutes: 20)), demo: false)
        XCTAssertTrue(nap.isNap)
        XCTAssertEqual(store.nights(demo: false).count, 1)
        XCTAssertEqual(store.history(before: Date(), demo: false).count, 1)
        XCTAssertEqual(store.previousScore(before: Date(), demo: false, nap: true), nap.score)
    }

    @MainActor
    func testJournalEntryLinksToTheNight() throws {
        let store = SleepStore(inMemory: true)
        let start = Calendar.current.date(bySettingHour: 23, minute: 0, second: 0, of: Date(timeIntervalSinceNow: -2 * 86_400)) ?? Date()
        let record = try store.save(PersistenceTests.night(seed: 4, start: start), demo: false)
        let nightDate = StatisticsCalculator.nightDate(for: start, calendar: .current)
        let entry = try XCTUnwrap(store.journalEntry(forNight: nightDate, demo: false, create: true))
        entry.feeling = 5
        entry.factors = ["caffeine"]
        store.saveJournal(demo: false)
        XCTAssertEqual(store.journalEntries(demo: false).count, 1)
        XCTAssertEqual(entry.session?.id, record.id)
    }

    @MainActor
    func testRescoringChangesStoredScores() throws {
        let store = SleepStore(inMemory: true)
        _ = try store.save(PersistenceTests.night(seed: 5, start: Date(timeIntervalSinceNow: -86_400)), demo: false)
        let before = try XCTUnwrap(store.sessions(demo: false).first?.score)
        let durationOnly = ScoreWeights(duration: 1, efficiency: 0, latency: 0, interruptions: 0, restlessness: 0, consistency: 0)
        store.rescoreAll(weights: durationOnly, demo: false)
        let record = try XCTUnwrap(store.sessions(demo: false).first)
        let decoded = try XCTUnwrap(record.decoded())
        XCTAssertEqual(record.score, decoded.score.value)
        XCTAssertEqual(decoded.score.component(.duration)?.weight ?? 0, 1, accuracy: 1e-9)
        _ = before
    }

    @MainActor
    func testExportWritesJSONAndCSV() throws {
        let store = SleepStore(inMemory: true)
        _ = try store.save(PersistenceTests.night(seed: 6, start: Date(timeIntervalSinceNow: -86_400)), demo: false)
        let urls = try DataExporter.export(store: store, demo: false)
        XCTAssertEqual(urls.count, 2)
        let csv = try String(contentsOf: urls[1], encoding: .utf8)
        XCTAssertEqual(csv.split(separator: "\n").count, 2, "Header plus one night")
        let json = try Data(contentsOf: urls[0])
        XCTAssertGreaterThan(json.count, 1_000)
    }
}

final class TrackingControllerTests: XCTestCase {
    @MainActor
    private func makeController() -> (TrackingController, SleepStore, AppSettings) {
        let defaults = UserDefaults(suiteName: "SleepFlowTests.tracking.\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        let store = SleepStore(inMemory: true)
        let diagnostics = DiagnosticsLog(persistent: false)
        let alarms = AlarmCoordinator(settings: settings, diagnostics: diagnostics, scheduler: FakeAlarmScheduler())
        let tracking = TrackingController(settings: settings, store: store, alarms: alarms, diagnostics: diagnostics)
        return (tracking, store, settings)
    }

    @MainActor
    private func waitForAlarm(_ tracking: TrackingController, timeout: TimeInterval = 30) async {
        let deadline = Date().addingTimeInterval(timeout)
        while tracking.phase != .alarmRinging && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    @MainActor
    func testSimulatedPowerNapCountsFromSleepAndWakesEarly() async throws {
        let (tracking, store, _) = makeController()
        try await tracking.start(method: .microphone, simulated: true, wake: .afterSleep(.powerNap20))
        XCTAssertTrue(tracking.isTracking)
        XCTAssertNotNil(tracking.napPlan)
        await waitForAlarm(tracking)
        XCTAssertEqual(tracking.phase, .alarmRinging, "The simulated nap should end with its alarm")
        XCTAssertNotNil(tracking.napCountStart)
        let latest = NapPlan.powerNap(minutes: 20).latestDeadline(start: try XCTUnwrap(tracking.active?.header.start))
        XCTAssertLessThanOrEqual(try XCTUnwrap(tracking.simulatedNow), latest.addingTimeInterval(30))

        await tracking.wakeConfirmed(occurrenceKey: "simulated-nap")
        XCTAssertNotNil(tracking.completedSessionID)
        let saved = try XCTUnwrap(store.sessions(demo: true).first)
        XCTAssertTrue(saved.isNap)
        XCTAssertTrue(store.sessions(demo: false).isEmpty, "Simulated sessions never reach the real store")
        let session = try XCTUnwrap(saved.decoded())
        XCTAssertNotNil(session.wakeUp.countedFrom)
        XCTAssertNotNil(session.wakeUp.reason)
    }

    @MainActor
    func testSimulatedNightIsSavedToTheDemoStore() async throws {
        let (tracking, store, settings) = makeController()
        var alarm = AlarmSettings()
        alarm.isEnabled = true
        settings.alarm = alarm
        try await tracking.start(method: .motion, simulated: true)
        await waitForAlarm(tracking, timeout: 60)
        _ = await tracking.stop(reason: .user)
        let saved = try XCTUnwrap(store.sessions(demo: true).first)
        XCTAssertFalse(saved.isNap)
        XCTAssertGreaterThan(saved.totalSleep, 3 * 3600)
        XCTAssertTrue(store.sessions(demo: false).isEmpty)
    }
}

final class LocalizationTests: XCTestCase {
    private func table(_ language: String) throws -> [String: String] {
        let bundle = Bundle(for: SleepFlowBundleMarker.self)
        let url = try XCTUnwrap(
            Bundle.main.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: language)
                ?? bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: language),
            "No \(language) strings table in the app"
        )
        let dictionary = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
        return dictionary
    }

    private func specifiers(_ text: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: "%(?:\\d+\\$)?(lld|ld|d|@|lf|f)")
        let range = NSRange(text.startIndex..., in: text)
        return pattern.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }.sorted()
    }

    func testDanishTableIsCompleteAndFormatSafe() throws {
        let danish = try table("da")
        XCTAssertGreaterThan(danish.count, 300)
        for (key, value) in danish {
            XCTAssertFalse(value.isEmpty, "Empty translation for \(key)")
            XCTAssertEqual(specifiers(key), specifiers(value), "Format specifiers differ for \"\(key)\"")
        }
        for key in ["Start sleep tracking", "Wake after sleep", "Good morning", "Sleep Score", "Power nap"] {
            XCTAssertNotNil(danish[key], "Missing Danish text for \(key)")
        }
    }
}

/// Helper so the test can find the app bundle.
private final class SleepFlowBundleMarker {}

final class NapPresetTests: XCTestCase {
    func testPresetsMatchTheirPlans() {
        XCTAssertEqual(NapPreset.powerNap20.plan.sleepDuration, 20 * 60)
        XCTAssertTrue(NapPreset.powerNap30.isPowerNap)
        XCTAssertEqual(NapPreset.cycles2.plan.cycleCount, 2)
        XCTAssertEqual(NapPreset.from(rawValue: "unknown"), .powerNap20)
        XCTAssertEqual(NapPreset.allCases.count, 7)
    }
}
