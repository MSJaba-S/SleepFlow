import XCTest
@testable import SleepSession
@testable import SleepScoring
@testable import SleepModels
@testable import AudioAnalysis
@testable import MotionAnalysis
@testable import SmartAlarm
@testable import SleepSimulation

final class SessionJournalTests: XCTestCase {
    var directory: URL!
    let start = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("journal-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func header() -> SessionHeader {
        SessionHeader(start: start, method: .microphone, alarm: nil, smartAlarmEnabled: false, sleepGoal: 8 * 3600, isSimulated: true, appVersion: "test", timeZoneIdentifier: "UTC")
    }

    func testWritesAndRecoversEverything() throws {
        let journal = SessionJournal(directory: directory)
        let header = header()
        try journal.start(header)
        for index in 0..<10 {
            try journal.append(EpochFeatures(index: index, start: start.addingTimeInterval(Double(index) * 30), audioCoverage: 1, soundActivity: Double(index)))
        }
        try journal.append(SoundEvent(start: start.addingTimeInterval(65), duration: 1.2, type: .snoring, confidence: 0.8, peakDecibels: -50, levelAboveFloor: 18))
        try journal.append(MovementEvent(start: start.addingTimeInterval(80), duration: 3, intensity: 0.05, kind: .large))
        try journal.append(SessionMarker(time: start.addingTimeInterval(120), kind: .trackingInterrupted, detail: "call"))
        journal.close()

        XCTAssertTrue(SessionJournal.exists(at: directory))
        let recovered = try XCTUnwrap(SessionJournal.recover(from: directory))
        XCTAssertEqual(recovered.header, header)
        XCTAssertEqual(recovered.epochs.count, 10)
        XCTAssertEqual(recovered.epochs.last?.soundActivity, 9)
        XCTAssertEqual(recovered.soundEvents.first?.type, .snoring)
        XCTAssertEqual(recovered.movementEvents.first?.kind, .large)
        XCTAssertEqual(recovered.markers.first?.detail, "call")
        XCTAssertFalse(recovered.isFinished)
        XCTAssertEqual(recovered.lastRecordedTime, start.addingTimeInterval(300))
    }

    func testTruncatedLastLineIsIgnored() throws {
        let journal = SessionJournal(directory: directory)
        try journal.start(header())
        try journal.append(EpochFeatures(index: 0, start: start, audioCoverage: 1))
        try journal.append(EpochFeatures(index: 1, start: start.addingTimeInterval(30), audioCoverage: 1))
        journal.close()
        // Simulate the app being killed in the middle of a write.
        let url = directory.appendingPathComponent("epochs.jsonl")
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"index\":2,\"start\":17".utf8))
        try handle.close()

        let recovered = try XCTUnwrap(SessionJournal.recover(from: directory))
        XCTAssertEqual(recovered.epochs.map(\.index), [0, 1])
    }

    func testAppendingBeforeStartThrows() {
        let journal = SessionJournal(directory: directory)
        XCTAssertThrowsError(try journal.append(EpochFeatures(index: 0, start: start)))
    }

    func testDiscardRemovesFiles() throws {
        let journal = SessionJournal(directory: directory)
        try journal.start(header())
        try journal.append(SessionMarker(time: start, kind: .ended))
        XCTAssertTrue(SessionJournal.exists(at: directory))
        XCTAssertTrue(SessionJournal.recover(from: directory)?.isFinished ?? false)
        try journal.discard()
        XCTAssertFalse(SessionJournal.exists(at: directory))
        XCTAssertNil(SessionJournal.recover(from: directory))
    }

    func testProtectionHandlerIsCalledForCreatedFiles() throws {
        var protected: [String] = []
        let journal = SessionJournal(directory: directory) { url in protected.append(url.lastPathComponent) }
        try journal.start(header())
        XCTAssertTrue(protected.contains("header.json"))
        XCTAssertTrue(protected.contains("epochs.jsonl"))
    }
}

final class EpochCombinerTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_700_000_000)

    func testMicrophoneWaitsForMotionThenGivesUp() {
        var combiner = EpochCombiner(sessionStart: start, method: .microphone, secondaryExpected: true, maximumWait: 2)
        XCTAssertTrue(combiner.add(AcousticEpochSummary(epochIndex: 0, coveredSeconds: 30, snoreSeconds: 4)).isEmpty)
        let combined = combiner.add(MotionEpochSummary(epochIndex: 0, coveredSeconds: 30, activity: 1, pickup: true))
        XCTAssertEqual(combined.count, 1)
        XCTAssertEqual(combined.first?.snoreSeconds, 4)
        XCTAssertTrue(combined.first?.pickup ?? false)
        XCTAssertEqual(combined.first?.audioCoverage ?? 0, 1, accuracy: 0.001)

        // Motion stops arriving: epoch 1 is released once the microphone is two epochs ahead.
        XCTAssertTrue(combiner.add(AcousticEpochSummary(epochIndex: 1, coveredSeconds: 30)).isEmpty)
        XCTAssertTrue(combiner.add(AcousticEpochSummary(epochIndex: 2, coveredSeconds: 30)).isEmpty)
        let released = combiner.add(AcousticEpochSummary(epochIndex: 3, coveredSeconds: 30))
        XCTAssertEqual(released.map(\.index), [1])
        XCTAssertEqual(combiner.flush().map(\.index), [2, 3])
    }

    func testMotionOnlyEmitsImmediately() {
        var combiner = EpochCombiner(sessionStart: start, method: .motion, secondaryExpected: false)
        let result = combiner.add(MotionEpochSummary(epochIndex: 0, coveredSeconds: 29, activity: 3, movementCount: 1))
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.movementActivity, 3)
        XCTAssertEqual(result.first?.audioCoverage, 0)
        XCTAssertEqual(result.first?.start, start)
    }

    func testLateSummariesAreDropped() {
        var combiner = EpochCombiner(sessionStart: start, method: .motion, secondaryExpected: false)
        _ = combiner.add(MotionEpochSummary(epochIndex: 5, coveredSeconds: 30))
        XCTAssertTrue(combiner.add(MotionEpochSummary(epochIndex: 4, coveredSeconds: 30)).isEmpty)
        XCTAssertEqual(combiner.lastEmittedIndex, 5)
    }
}

final class TrackingLifecycleTests: XCTestCase {
    func testHappyPath() {
        var lifecycle = TrackingLifecycle()
        XCTAssertTrue(lifecycle.handle(.start))
        XCTAssertTrue(lifecycle.handle(.started))
        XCTAssertTrue(lifecycle.isActive)
        XCTAssertTrue(lifecycle.handle(.alarmFired))
        XCTAssertTrue(lifecycle.handle(.snooze))
        XCTAssertTrue(lifecycle.handle(.alarmFired))
        XCTAssertTrue(lifecycle.handle(.stop))
        XCTAssertEqual(lifecycle.phase, .finishing)
        XCTAssertTrue(lifecycle.handle(.finished))
        XCTAssertTrue(lifecycle.handle(.reset))
        XCTAssertEqual(lifecycle.phase, .idle)
    }

    func testInvalidTransitionsAreRejected() {
        var lifecycle = TrackingLifecycle()
        XCTAssertFalse(lifecycle.handle(.stop))
        XCTAssertFalse(lifecycle.handle(.snooze))
        XCTAssertEqual(lifecycle.phase, .idle)
        lifecycle.handle(.start)
        lifecycle.handle(.started)
        XCTAssertFalse(lifecycle.handle(.snooze), "No snooze without a ringing alarm")
        lifecycle.handle(.stop)
        XCTAssertFalse(lifecycle.handle(.stop), "Stopping twice is rejected")
    }

    func testRecoveryResumesTracking() {
        var lifecycle = TrackingLifecycle()
        XCTAssertTrue(lifecycle.handle(.recover))
        XCTAssertEqual(lifecycle.phase, .tracking)
    }

    func testFailedStartReturnsToIdle() {
        var lifecycle = TrackingLifecycle()
        lifecycle.handle(.start)
        XCTAssertTrue(lifecycle.handle(.failed))
        XCTAssertEqual(lifecycle.phase, .idle)
    }
}

final class SessionAssemblerTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_700_000_000)

    func testAssemblesSimulatedNight() throws {
        let night = NightSimulator.simulate(NightScenario(method: .microphone, bedtime: start, snoringPropensity: 0.3), seed: 42)
        let deadline = night.end
        let header = SessionHeader(
            start: start, method: .microphone,
            alarm: AlarmOccurrence(key: "k", deadline: deadline, windowStart: deadline.addingTimeInterval(-1800)),
            smartAlarmEnabled: true, sleepGoal: 7.5 * 3600, isSimulated: true, appVersion: "test", timeZoneIdentifier: "UTC"
        )
        let markers = [
            SessionMarker(time: deadline.addingTimeInterval(-600), kind: .smartAlarmTriggered, detail: WakeReason.lightSleep.rawValue),
            SessionMarker(time: deadline.addingTimeInterval(-60), kind: .snoozed)
        ]
        let session = SessionAssembler.assemble(SessionAssemblyInput(
            header: header, end: night.end, epochs: night.epochs, soundEvents: night.soundEvents,
            movementEvents: night.movementEvents, markers: markers, previousScore: 60
        ))
        XCTAssertEqual(session.hypnogram.count, night.groundTruth.count)
        XCTAssertEqual(session.epochs.count, night.groundTruth.count)
        XCTAssertGreaterThan(session.metrics.totalSleep, 5 * 3600)
        XCTAssertTrue((0...100).contains(session.score.value))
        XCTAssertFalse(session.suggestions.isEmpty)
        XCTAssertEqual(session.wakeUp.reason, .lightSleep)
        XCTAssertEqual(session.wakeUp.snoozeCount, 1)
        XCTAssertEqual(session.wakeUp.minutesBeforeDeadline ?? 0, 10, accuracy: 0.01)
        XCTAssertEqual(session.previousScore, 60)

        // Codable round trip (the app stores sessions as JSON with the default, lossless date strategy).
        let decoded = try JSONDecoder().decode(CompletedSession.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(decoded, session)
    }

    func testRescoringAStoredNight() {
        let night = NightSimulator.simulate(NightScenario(method: .microphone, bedtime: start, timeInBed: 6 * 3600, sleepLatency: 40 * 60), seed: 5)
        let header = SessionHeader(start: start, method: .microphone, alarm: nil, smartAlarmEnabled: false, sleepGoal: 8 * 3600, isSimulated: true, appVersion: "test", timeZoneIdentifier: "UTC")
        let input = SessionAssemblyInput(header: header, end: night.end, epochs: night.epochs, soundEvents: night.soundEvents, movementEvents: night.movementEvents, markers: [])
        let session = SessionAssembler.assemble(input)

        // Same weights: nothing changes.
        XCTAssertEqual(session.rescored(with: .standard, previousScore: nil), session)

        // Duration-only weighting equals a fresh assembly with those weights.
        let durationOnly = ScoreWeights(duration: 1, efficiency: 0, latency: 0, interruptions: 0, restlessness: 0, consistency: 0)
        var weightedInput = input
        weightedInput.weights = durationOnly
        let fresh = SessionAssembler.assemble(weightedInput)
        let rescored = session.rescored(with: durationOnly, previousScore: 50)
        XCTAssertEqual(rescored.score.value, fresh.score.value)
        XCTAssertEqual(rescored.suggestions, fresh.suggestions)
        XCTAssertEqual(rescored.previousScore, 50)
        XCTAssertEqual(rescored.hypnogram, session.hypnogram)
    }

    func testGapsAreReported() {
        let scenario = NightScenario(method: .motion, bedtime: start, timeInBed: 4 * 3600, gaps: [(3600)...(5400)])
        let night = NightSimulator.simulate(scenario, seed: 8)
        let header = SessionHeader(start: start, method: .motion, alarm: nil, smartAlarmEnabled: false, sleepGoal: 8 * 3600, isSimulated: true, appVersion: "test", timeZoneIdentifier: "UTC")
        let session = SessionAssembler.assemble(SessionAssemblyInput(header: header, end: night.end, epochs: night.epochs, soundEvents: [], movementEvents: night.movementEvents, markers: []))
        XCTAssertEqual(session.gaps.count, 1)
        XCTAssertEqual(session.gaps.first?.duration ?? 0, 1_830, accuracy: 31)
        XCTAssertLessThan(session.metrics.dataCoverage, 0.9)
    }

    func testMissingEpochsAreFilled() {
        let epochs = [0, 1, 2, 7, 8].map { EpochFeatures(index: $0, start: start.addingTimeInterval(Double($0) * 30), motionCoverage: 1) }
        let header = SessionHeader(start: start, method: .motion, alarm: nil, smartAlarmEnabled: false, sleepGoal: 8 * 3600, isSimulated: true, appVersion: "test", timeZoneIdentifier: "UTC")
        let session = SessionAssembler.assemble(SessionAssemblyInput(header: header, end: start.addingTimeInterval(300), epochs: epochs, soundEvents: [], movementEvents: [], markers: []))
        XCTAssertEqual(session.epochs.map(\.index), Array(0..<10))
        XCTAssertEqual(session.epochs[4].motionCoverage, 0)
        XCTAssertEqual(session.gaps.count, 1, "Epochs 3–6 form a gap; one missing epoch at the end does not")
        XCTAssertEqual(session.gaps.first?.duration ?? 0, 120, accuracy: 0.1)
    }
}
