import XCTest
@testable import SleepScoring
@testable import SleepModels

final class SleepScoreTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Copenhagen") ?? TimeZone(secondsFromGMT: 3_600)!
        return calendar
    }

    func metrics(
        totalSleep: TimeInterval = 8 * 3600,
        timeInBed: TimeInterval = 8.5 * 3600,
        latency: TimeInterval? = 10 * 60,
        waso: TimeInterval = 5 * 60,
        interruptions: Int = 0,
        restlessness: Double = 0.05,
        coverage: Double = 1
    ) -> SleepMetrics {
        SleepMetrics(
            sessionStart: start,
            sessionEnd: start.addingTimeInterval(timeInBed),
            sleepOnset: latency.map { start.addingTimeInterval($0) },
            finalAwakening: start.addingTimeInterval(timeInBed - 300),
            timeInBed: timeInBed,
            totalSleep: totalSleep,
            sleepLatency: latency,
            wakeAfterSleepOnset: waso,
            awakeTime: timeInBed - totalSleep,
            efficiency: totalSleep / timeInBed,
            interruptions: interruptions,
            lightSleep: totalSleep * 0.75,
            deepSleep: totalSleep * 0.25,
            restlessness: restlessness,
            movementEventsPerHour: 4,
            dataCoverage: coverage,
            snoringDuration: 0,
            soundEventCounts: [:]
        )
    }

    func testExcellentNightScoresHigh() {
        let score = SleepScoreCalculator().score(metrics: metrics(), targets: ScoreTargets(sleepGoal: 8 * 3600), history: [])
        XCTAssertGreaterThanOrEqual(score.value, 95)
        XCTAssertEqual(score.quality, .excellent)
        XCTAssertNil(score.component(.consistency), "Consistency needs at least three earlier nights")
        let weightSum = score.components.reduce(0) { $0 + $1.weight }
        XCTAssertEqual(weightSum, 1, accuracy: 1e-9)
    }

    func testDurationIsRelativeToPersonalGoal() {
        let sixHours = metrics(totalSleep: 6 * 3600, timeInBed: 6.4 * 3600)
        let lowGoal = SleepScoreCalculator().score(metrics: sixHours, targets: ScoreTargets(sleepGoal: 6 * 3600), history: [])
        let highGoal = SleepScoreCalculator().score(metrics: sixHours, targets: ScoreTargets(sleepGoal: 8.5 * 3600), history: [])
        XCTAssertEqual(lowGoal.component(.duration)?.score, 100)
        XCTAssertLessThan(highGoal.component(.duration)?.score ?? 100, 30)
        XCTAssertGreaterThan(lowGoal.value, highGoal.value)
    }

    func testDurationFactorIsLinearInShortfall() {
        let targets = ScoreTargets(sleepGoal: 8 * 3600)
        XCTAssertEqual(SleepScoreCalculator.durationScore(8 * 3600, targets: targets), 100)
        XCTAssertEqual(SleepScoreCalculator.durationScore(7.75 * 3600, targets: targets), 100, "15 minutes short still counts")
        // Shortfall of 97.5 min is halfway between 15 and 180 min.
        XCTAssertEqual(SleepScoreCalculator.durationScore(8 * 3600 - 97.5 * 60, targets: targets), 50, accuracy: 0.01)
        XCTAssertEqual(SleepScoreCalculator.durationScore(4 * 3600, targets: targets), 0)
        XCTAssertGreaterThanOrEqual(SleepScoreCalculator.durationScore(12 * 3600, targets: targets), 70)
    }

    func testFactorFunctions() {
        XCTAssertEqual(SleepScoreCalculator.linear(0.9, best: 0.9, worst: 0.65), 100)
        XCTAssertEqual(SleepScoreCalculator.linear(0.775, best: 0.9, worst: 0.65), 50, accuracy: 0.001)
        XCTAssertEqual(SleepScoreCalculator.linear(0.5, best: 0.9, worst: 0.65), 0)
        // Works when lower is better (latency).
        XCTAssertEqual(SleepScoreCalculator.linear(37.5 * 60, best: 15 * 60, worst: 60 * 60), 50, accuracy: 0.001)
    }

    func testInterruptionsCostPoints() {
        let calm = SleepScoreCalculator.interruptionScore(metrics(waso: 5 * 60, interruptions: 1), targets: ScoreTargets(sleepGoal: 8 * 3600))
        let broken = SleepScoreCalculator.interruptionScore(metrics(waso: 40 * 60, interruptions: 4), targets: ScoreTargets(sleepGoal: 8 * 3600))
        XCTAssertEqual(calm, 100)
        // 3 extra interruptions (−45) and 30 extra minutes awake (−45) → 10
        XCTAssertEqual(broken, 10, accuracy: 0.001)
    }

    func testNoSleepScoresZero() {
        let none = SleepMetrics(
            sessionStart: start, sessionEnd: start.addingTimeInterval(3_600), sleepOnset: nil, finalAwakening: nil,
            timeInBed: 3_600, totalSleep: 0, sleepLatency: nil, wakeAfterSleepOnset: 0, awakeTime: 3_600, efficiency: 0,
            interruptions: 0, lightSleep: 0, deepSleep: 0, restlessness: 0, movementEventsPerHour: 0, dataCoverage: 1,
            snoringDuration: 0, soundEventCounts: [:]
        )
        let score = SleepScoreCalculator().score(metrics: none, targets: ScoreTargets(sleepGoal: 8 * 3600), history: [])
        XCTAssertEqual(score.value, 0)
        XCTAssertEqual(score.quality, .bad)
    }

    func testConsistencyUsesCircularClockTimes() {
        // Earlier nights: asleep around 23:50–00:10, awake around 07:30.
        let calendar = self.calendar
        func date(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
        }
        let history = [
            HistoricalNight(bedtime: date(10, 23, 50), wakeTime: date(11, 7, 30)),
            HistoricalNight(bedtime: date(12, 0, 10), wakeTime: date(12, 7, 30)),
            HistoricalNight(bedtime: date(12, 23, 55), wakeTime: date(13, 7, 25)),
            HistoricalNight(bedtime: date(14, 0, 5), wakeTime: date(14, 7, 35))
        ]
        var tonight = metrics()
        tonight.sleepOnset = date(15, 0, 0)
        tonight.finalAwakening = date(15, 7, 30)
        let deviation = SleepScoreCalculator.consistencyDeviation(metrics: tonight, history: history, calendar: calendar)
        XCTAssertNotNil(deviation)
        XCTAssertLessThan(deviation ?? 999, 5, "Midnight wrap-around must not create a 12-hour deviation")

        var late = tonight
        late.sleepOnset = date(15, 2, 0)
        late.finalAwakening = date(15, 9, 30)
        let lateDeviation = SleepScoreCalculator.consistencyDeviation(metrics: late, history: history, calendar: calendar) ?? 0
        XCTAssertEqual(lateDeviation, 120, accuracy: 5)

        let regular = SleepScoreCalculator().score(metrics: tonight, targets: ScoreTargets(sleepGoal: 8 * 3600), history: history, calendar: calendar)
        let irregular = SleepScoreCalculator().score(metrics: late, targets: ScoreTargets(sleepGoal: 8 * 3600), history: history, calendar: calendar)
        XCTAssertEqual(regular.component(.consistency)?.score, 100)
        XCTAssertEqual(irregular.component(.consistency)?.score, 0)
        XCTAssertGreaterThan(regular.value, irregular.value)
    }

    func testCustomWeights() {
        let poorLatency = metrics(latency: 60 * 60)
        let latencyHeavy = ScoreWeights(duration: 0, efficiency: 0, latency: 1, interruptions: 0, restlessness: 0, consistency: 0)
        let score = SleepScoreCalculator(weights: latencyHeavy).score(metrics: poorLatency, targets: ScoreTargets(sleepGoal: 8 * 3600), history: [])
        XCTAssertEqual(score.value, 0)
        XCTAssertEqual(score.component(.latency)?.weight ?? 0, 1, accuracy: 1e-9)
    }

    func testLowCoverageIsFlagged() {
        let score = SleepScoreCalculator().score(metrics: metrics(coverage: 0.4), targets: ScoreTargets(sleepGoal: 8 * 3600), history: [])
        XCTAssertTrue(score.lowConfidence)
    }

    func testScoreIsDeterministic() {
        let calculator = SleepScoreCalculator()
        let a = calculator.score(metrics: metrics(totalSleep: 7 * 3600), targets: ScoreTargets(sleepGoal: 8 * 3600), history: [])
        let b = calculator.score(metrics: metrics(totalSleep: 7 * 3600), targets: ScoreTargets(sleepGoal: 8 * 3600), history: [])
        XCTAssertEqual(a, b)
    }

    func testReweightingWithSameWeightsKeepsTheScore() {
        let night = metrics(totalSleep: 6.5 * 3600, timeInBed: 7.5 * 3600, latency: 35 * 60, interruptions: 3, restlessness: 0.25)
        let targets = ScoreTargets(sleepGoal: 8 * 3600)
        let original = SleepScoreCalculator().score(metrics: night, targets: targets, history: [])
        XCTAssertEqual(original.reweighted(.standard), original)
    }

    func testReweightingMatchesAFreshCalculation() {
        let night = metrics(totalSleep: 6 * 3600, timeInBed: 7 * 3600, latency: 40 * 60, interruptions: 4, restlessness: 0.3)
        let targets = ScoreTargets(sleepGoal: 8 * 3600)
        let custom = ScoreWeights(duration: 0.5, efficiency: 0.1, latency: 0.2, interruptions: 0.1, restlessness: 0.1, consistency: 0.4)
        let fresh = SleepScoreCalculator(weights: custom).score(metrics: night, targets: targets, history: [])
        let reweighted = SleepScoreCalculator().score(metrics: night, targets: targets, history: []).reweighted(custom)
        XCTAssertEqual(reweighted.value, fresh.value)
        XCTAssertEqual(reweighted.quality, fresh.quality)
        for component in fresh.components {
            XCTAssertEqual(reweighted.component(component.factor)?.weight ?? -1, component.weight, accuracy: 1e-9)
        }
    }

    func testWeightHelpers() {
        let weights = ScoreWeights.standard.setting(.latency, to: 2)
        XCTAssertEqual(weights.latency, 1, "Weights are clamped to 0...1")
        let none = ScoreWeights(duration: 0, efficiency: 0, latency: 0, interruptions: 0, restlessness: 0, consistency: 0)
        XCTAssertTrue(none.isEmpty)
        XCTAssertFalse(ScoreWeights.standard.isEmpty)
        let shares = ScoreFactor.allCases.map { ScoreWeights.standard.share(of: $0) }
        XCTAssertEqual(shares.reduce(0, +), 1, accuracy: 1e-9)
    }

    func testQualityBands() {
        XCTAssertEqual(ScoreQuality(score: 90), .excellent)
        XCTAssertEqual(ScoreQuality(score: 75), .good)
        XCTAssertEqual(ScoreQuality(score: 60), .fair)
        XCTAssertEqual(ScoreQuality(score: 45), .poor)
        XCTAssertEqual(ScoreQuality(score: 10), .bad)
    }
}

final class InsightTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_700_000_000)

    func testShortNightProducesShortSleepInsightAndBedtimeSuggestion() {
        let metrics = SleepMetrics(
            sessionStart: start, sessionEnd: start.addingTimeInterval(6 * 3600), sleepOnset: start.addingTimeInterval(45 * 60),
            finalAwakening: start.addingTimeInterval(6 * 3600), timeInBed: 6 * 3600, totalSleep: 5 * 3600, sleepLatency: 45 * 60,
            wakeAfterSleepOnset: 15 * 60, awakeTime: 3_600, efficiency: 5.0 / 6.0, interruptions: 1, lightSleep: 4 * 3600,
            deepSleep: 3_600, restlessness: 0.2, movementEventsPerHour: 6, dataCoverage: 1, snoringDuration: 0, soundEventCounts: [:]
        )
        let targets = ScoreTargets(sleepGoal: 8 * 3600)
        let score = SleepScoreCalculator().score(metrics: metrics, targets: targets, history: [])
        let insights = InsightEngine.insights(score: score, metrics: metrics, targets: targets, previousScore: score.value + 12, noisyEpochFraction: 0)
        XCTAssertTrue(insights.contains { $0.kind == .shortSleep })
        XCTAssertTrue(insights.contains { $0.kind == .longLatency })
        XCTAssertTrue(insights.contains { $0.kind == .worseThanPrevious })
        XCTAssertFalse(insights.first?.isPositive ?? true, "Negative findings come first")
        let suggestions = InsightEngine.suggestions(score: score, metrics: metrics, targets: targets, noisyEpochFraction: 0)
        XCTAssertEqual(suggestions.first, .earlierBedtime)
        XCTAssertLessThanOrEqual(suggestions.count, 3)
        XCTAssertEqual(Set(suggestions).count, suggestions.count)
    }

    func testMainContributorsAreSortedByPointsLost() {
        let score = SleepScore(value: 70, components: [
            ScoreComponent(factor: .duration, score: 50, weight: 0.3, measuredValue: 0),
            ScoreComponent(factor: .latency, score: 90, weight: 0.1, measuredValue: 0),
            ScoreComponent(factor: .efficiency, score: 60, weight: 0.6, measuredValue: 0)
        ], quality: .good, lowConfidence: false)
        XCTAssertEqual(InsightEngine.mainContributors(score).map(\.factor), [.efficiency, .duration, .latency])
    }
}
