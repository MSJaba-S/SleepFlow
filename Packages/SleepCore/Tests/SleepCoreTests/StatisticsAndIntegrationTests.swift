import XCTest
@testable import SleepStatistics
@testable import SleepModels
@testable import AudioAnalysis
@testable import MotionAnalysis
@testable import SleepIntelligence
@testable import SleepSession
@testable import SleepSimulation
@testable import SmartAlarm

final class StatisticsTests: XCTestCase {
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Copenhagen") ?? TimeZone(secondsFromGMT: 3_600)!
        calendar.firstWeekday = 2
        return calendar
    }

    func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    func night(_ day: Int, bed: (Int, Int), wake: (Int, Int), sleepHours: Double, score: Int, factors: [String] = []) -> NightSummary {
        let bedDay = bed.0 < 12 ? day + 1 : day
        let start = date(bedDay, bed.0, bed.1)
        let end = date(day + 1, wake.0, wake.1)
        return NightSummary(
            start: start, end: end, sleepOnset: start.addingTimeInterval(600), finalAwakening: end.addingTimeInterval(-300),
            totalSleep: sleepHours * 3600, timeInBed: end.timeIntervalSince(start), efficiency: 0.9, score: score,
            sleepGoal: 8 * 3600, factors: factors
        )
    }

    func testNightDateAttribution() {
        XCTAssertEqual(StatisticsCalculator.nightDate(for: date(18, 23, 30), calendar: calendar), date(18, 0))
        XCTAssertEqual(StatisticsCalculator.nightDate(for: date(19, 0, 45), calendar: calendar), date(18, 0), "After-midnight bedtimes belong to the previous evening")
        XCTAssertEqual(StatisticsCalculator.nightDate(for: date(19, 13, 0), calendar: calendar), date(19, 0), "A nap in the afternoon belongs to that day")
    }

    func testSummaryAverages() {
        let nights = [
            night(10, bed: (23, 0), wake: (7, 0), sleepHours: 7.5, score: 80),
            night(11, bed: (23, 30), wake: (7, 15), sleepHours: 7.0, score: 70),
            night(12, bed: (0, 15), wake: (7, 30), sleepHours: 6.5, score: 60)
        ]
        let summary = StatisticsCalculator.summary(nights, calendar: calendar)
        XCTAssertEqual(summary.nights, 3)
        XCTAssertEqual(summary.averageSleep, 7 * 3600, accuracy: 1)
        XCTAssertEqual(summary.averageScore, 70, accuracy: 0.001)
        XCTAssertNotNil(summary.consistencyScore)
        // Bedtimes (after the 10-minute onset) 23:10, 23:40, 00:25 → circular mean ≈ 23:45.
        XCTAssertEqual(summary.bedtimeMean ?? 0, 23 * 60 + 45, accuracy: 3)
        XCTAssertEqual(summary.goalAchievement, 0, accuracy: 0.001)
    }

    func testConsistencyScore() {
        XCTAssertEqual(StatisticsCalculator.consistencyScore(bedSpread: 10, wakeSpread: 10), 100)
        XCTAssertEqual(StatisticsCalculator.consistencyScore(bedSpread: 130, wakeSpread: 130), 0)
        XCTAssertEqual(StatisticsCalculator.consistencyScore(bedSpread: 67.5, wakeSpread: 67.5), 50, accuracy: 0.01)
    }

    func testPeriodsAndShifting() {
        let week = StatisticsCalculator.interval(for: .week, containing: date(19, 12), calendar: calendar)
        XCTAssertEqual(week.start, date(16, 0), "Weeks start on Monday")
        let previous = StatisticsCalculator.shift(week, period: .week, by: -1, calendar: calendar)
        XCTAssertEqual(previous.start, date(9, 0))
        let month = StatisticsCalculator.interval(for: .month, containing: date(19, 12), calendar: calendar)
        XCTAssertEqual(month.start, date(1, 0))
    }

    func testAggregatesAndStreak() {
        let nights = [
            night(9, bed: (23, 0), wake: (7, 0), sleepHours: 8, score: 85),
            night(16, bed: (23, 0), wake: (7, 0), sleepHours: 6, score: 60),
            night(17, bed: (23, 0), wake: (7, 0), sleepHours: 8, score: 88),
            night(18, bed: (23, 0), wake: (7, 0), sleepHours: 7.9, score: 84)
        ]
        let weekly = StatisticsCalculator.aggregates(nights, by: .weekOfYear, calendar: calendar)
        XCTAssertEqual(weekly.count, 2)
        XCTAssertEqual(weekly.last?.nights, 3)
        XCTAssertEqual(StatisticsCalculator.goalStreak(nights), 2)
        let daily = StatisticsCalculator.dailyPoints(nights, calendar: calendar)
        XCTAssertEqual(daily.map(\.score), [85, 60, 88, 84])
    }

    func testFactorImpactNeedsEnoughNights() {
        var nights: [NightSummary] = []
        for day in 1...4 { nights.append(night(day, bed: (23, 0), wake: (7, 0), sleepHours: 7, score: 60, factors: ["caffeine"])) }
        for day in 5...8 { nights.append(night(day, bed: (23, 0), wake: (7, 0), sleepHours: 8, score: 80)) }
        nights.append(night(9, bed: (23, 0), wake: (7, 0), sleepHours: 8, score: 82, factors: ["exercise"]))
        let impacts = StatisticsCalculator.factorImpacts(nights)
        XCTAssertEqual(impacts.map(\.factor), ["caffeine"], "exercise has only one night")
        XCTAssertEqual(impacts.first?.difference ?? 0, -20.4, accuracy: 0.01)
    }

    func testEmptySummary() {
        XCTAssertEqual(StatisticsCalculator.summary([], calendar: calendar).nights, 0)
    }
}

/// Raw synthesised signals through every engine stage into a finished session.
final class PipelineIntegrationTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_700_000_000)

    func testMicrophonePipelineEndToEnd() {
        let sampleRate = 48_000.0
        var synth = SignalSynthesizer(sampleRate: sampleRate, seed: 77)
        // Three minutes: quiet, snoring in minute two, a cough at the end.
        var signal = synth.background(duration: 180)
        for index in 0..<10 { synth.mix(synth.snore(), into: &signal, at: 62 + Double(index) * 4.3) }
        synth.mix(synth.cough(), into: &signal, at: 170)

        let analyzer = AudioAnalyzer(sampleRate: sampleRate, sessionStart: start)
        var combiner = EpochCombiner(sessionStart: start, method: .microphone, secondaryExpected: false)
        let estimator = OnlineSleepEstimator(method: .microphone)
        var epochs: [EpochFeatures] = []
        var events: [SoundEvent] = []
        var offset = 0
        let chunk = 4_800
        while offset < signal.count {
            let end = min(offset + chunk, signal.count)
            let output = analyzer.process(Array(signal[offset..<end]), startingAt: start.addingTimeInterval(Double(offset) / sampleRate))
            events += output.events
            for summary in output.epochs {
                for epoch in combiner.add(summary) {
                    epochs.append(epoch)
                    estimator.update(with: epoch)
                }
            }
            offset = end
        }
        let final = analyzer.finish()
        events += final.events
        for summary in final.epochs { epochs += combiner.add(summary) }
        epochs += combiner.flush()

        XCTAssertEqual(epochs.map(\.index), [0, 1, 2, 3, 4, 5])
        XCTAssertGreaterThan(epochs[2].snoreSeconds + epochs[3].snoreSeconds, 5)
        XCTAssertEqual(epochs[5].coughCount, 1)
        XCTAssertGreaterThanOrEqual(estimator.epochsProcessed, 4)

        let header = SessionHeader(start: start, method: .microphone, alarm: nil, smartAlarmEnabled: false, sleepGoal: 8 * 3600, isSimulated: true, appVersion: "test", timeZoneIdentifier: "UTC")
        let session = SessionAssembler.assemble(SessionAssemblyInput(header: header, end: start.addingTimeInterval(180), epochs: epochs, soundEvents: events, movementEvents: [], markers: []))
        XCTAssertEqual(session.hypnogram.count, 6)
        XCTAssertGreaterThanOrEqual(session.metrics.count(of: .snoring), 6)
        XCTAssertEqual(session.metrics.dataCoverage, 1, accuracy: 0.001)
    }

    func testSmartAlarmOnSimulatedNight() {
        // A night whose ground truth ends in light sleep with movements before the deadline.
        let night = NightSimulator.simulate(NightScenario(method: .motion, bedtime: start, timeInBed: 8 * 3600, restlessness: 0.6), seed: 5)
        let deadline = night.end.addingTimeInterval(-60)
        let occurrence = AlarmOccurrence(key: "k", deadline: deadline, windowStart: deadline.addingTimeInterval(-30 * 60))
        let estimator = OnlineSleepEstimator(method: .motion)
        var engine = SmartAlarmEngine()
        var wakeTime: Date?
        for epoch in night.epochs {
            let estimate = estimator.update(with: epoch)
            if case .wake = engine.evaluate(now: epoch.end, occurrence: occurrence, estimate: estimate) {
                wakeTime = epoch.end
                break
            }
        }
        let woke = try? XCTUnwrap(wakeTime)
        XCTAssertNotNil(woke)
        if let woke {
            XCTAssertGreaterThanOrEqual(woke, occurrence.windowStart)
            XCTAssertLessThanOrEqual(woke, deadline.addingTimeInterval(30), "Never later than the deadline")
        }
    }
}
