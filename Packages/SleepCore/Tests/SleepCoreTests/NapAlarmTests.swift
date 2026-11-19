import XCTest
@testable import SleepModels
@testable import SmartAlarm
@testable import SleepIntelligence
@testable import SleepSimulation

final class NapPlanTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testBeforeOnsetTheLatestDeadlineIsUsed() {
        let plan = NapPlan.cycles(1)
        let occurrence = plan.occurrence(key: "nap", start: start, onset: nil)
        XCTAssertEqual(occurrence.deadline, start.addingTimeInterval(30 * 60 + 90 * 60))
        XCTAssertEqual(occurrence.deadline, plan.latestDeadline(start: start))
        XCTAssertEqual(occurrence.window, 20 * 60, accuracy: 0.001)
    }

    func testOnsetOnlyMovesTheDeadlineEarlier() {
        let plan = NapPlan.powerNap(minutes: 20)
        let latest = plan.latestDeadline(start: start)
        let early = plan.occurrence(key: "nap", start: start, onset: start.addingTimeInterval(6 * 60))
        XCTAssertEqual(early.deadline, start.addingTimeInterval(26 * 60))
        XCTAssertLessThan(early.deadline, latest)
        // An onset after the latest count start is capped, so the alarm is never later.
        let late = plan.occurrence(key: "nap", start: start, onset: start.addingTimeInterval(3 * 3600))
        XCTAssertEqual(late.deadline, latest)
        // An onset before the start is impossible and is clamped to the start.
        let before = plan.occurrence(key: "nap", start: start, onset: start.addingTimeInterval(-600))
        XCTAssertEqual(before.deadline, start.addingTimeInterval(20 * 60))
    }

    func testWindowNeverStartsBeforeOnset() {
        let plan = NapPlan(sleepDuration: 8 * 60, window: 20 * 60, maximumLatency: 10 * 60, wakesBeforeDeepSleep: true)
        let onset = start.addingTimeInterval(4 * 60)
        let occurrence = plan.occurrence(key: "nap", start: start, onset: onset)
        XCTAssertEqual(occurrence.windowStart, onset)
        XCTAssertEqual(occurrence.deadline, onset.addingTimeInterval(8 * 60))
    }

    func testPresets() {
        XCTAssertNil(NapPlan.powerNap(minutes: 20).cycleCount)
        XCTAssertEqual(NapPlan.cycles(3).cycleCount, 3)
        XCTAssertEqual(NapPlan.cycles(3).sleepDuration, 4.5 * 3600, accuracy: 0.001)
        XCTAssertTrue(NapPlan.powerNap(minutes: 30).wakesBeforeDeepSleep)
        XCTAssertFalse(NapPlan.cycles(1).wakesBeforeDeepSleep)
        XCTAssertTrue(NapPlan.key(start: start, calendar: Calendar(identifier: .gregorian)).hasPrefix("nap "))
    }

    func testPlanRoundTripsThroughJSON() throws {
        let plan = NapPlan.powerNap(minutes: 30)
        let decoded = try JSONDecoder().decode(NapPlan.self, from: JSONEncoder().encode(plan))
        XCTAssertEqual(decoded, plan)
    }
}

final class SleepOnsetDetectorTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    /// Unless stated otherwise, epochs that are probably awake also show an arousal (movement).
    func estimate(asleep: Double, hasData: Bool = true, arousal: Bool? = nil) -> OnlineEstimate {
        OnlineEstimate(epochIndex: 0, probabilities: StageProbabilities(awake: 1 - asleep, light: asleep, deep: 0), arousal: arousal ?? (asleep < 0.5), hasData: hasData, activity: 0)
    }

    func epochStart(_ index: Int) -> Date { start.addingTimeInterval(Double(index) * 30) }

    func testNeedsFourMinutesOfSleep() {
        var detector = SleepOnsetDetector()
        for index in 0..<4 { XCTAssertNil(detector.update(epochStart: epochStart(index), estimate: estimate(asleep: 0.1))) }
        for index in 4..<11 { XCTAssertNil(detector.update(epochStart: epochStart(index), estimate: estimate(asleep: 0.9)), "epoch \(index)") }
        XCTAssertEqual(detector.update(epochStart: epochStart(11), estimate: estimate(asleep: 0.9)), epochStart(4))
        XCTAssertEqual(detector.onset, epochStart(4))
        // Reported only once.
        XCTAssertNil(detector.update(epochStart: epochStart(12), estimate: estimate(asleep: 0.9)))
    }

    func testToleratesOneRestlessEpoch() {
        var detector = SleepOnsetDetector()
        var result: Date?
        for index in 0..<12 {
            let value = index == 5 ? 0.3 : 0.9
            result = detector.update(epochStart: epochStart(index), estimate: estimate(asleep: value)) ?? result
        }
        XCTAssertEqual(result, epochStart(0))
    }

    func testTwoRestlessEpochsInARowRestartTheRun() {
        var detector = SleepOnsetDetector()
        var result: Date?
        for index in 0..<30 {
            let value = (index == 3 || index == 4) ? 0.3 : 0.9
            result = detector.update(epochStart: epochStart(index), estimate: estimate(asleep: value)) ?? result
        }
        XCTAssertEqual(result, epochStart(5))
    }

    func testTooManyScatteredRestlessEpochsRestartTheRun() {
        var detector = SleepOnsetDetector()
        var result: Date?
        for index in 0..<30 {
            let value = [2, 4, 6].contains(index) ? 0.3 : 0.9
            result = detector.update(epochStart: epochStart(index), estimate: estimate(asleep: value)) ?? result
        }
        XCTAssertEqual(result, epochStart(7))
    }

    func testClearlyAwakeEpochRestartsTheRun() {
        var detector = SleepOnsetDetector()
        var result: Date?
        for index in 0..<30 {
            let value = index == 4 ? 0.05 : 0.9
            result = detector.update(epochStart: epochStart(index), estimate: estimate(asleep: value)) ?? result
        }
        XCTAssertEqual(result, epochStart(5))
    }

    func testOnsetIsDatedBackToTheDriftingOffPhase() {
        var detector = SleepOnsetDetector()
        var result: Date?
        for index in 0..<20 {
            // 0–3 awake and moving, 4–6 still but not yet confidently asleep, then asleep.
            let update: OnlineEstimate
            switch index {
            case 0..<4: update = estimate(asleep: 0.1, arousal: true)
            case 4..<7: update = estimate(asleep: 0.2, arousal: false)
            default: update = estimate(asleep: 0.9)
            }
            result = detector.update(epochStart: epochStart(index), estimate: update) ?? result
        }
        XCTAssertEqual(result, epochStart(4))
    }

    func testBackdatingStopsAtTheLastMovement() {
        var detector = SleepOnsetDetector()
        var result: Date?
        for index in 0..<30 {
            let update = index < 12 ? estimate(asleep: 0.1, arousal: index == 11 || index < 5) : estimate(asleep: 0.9)
            result = detector.update(epochStart: epochStart(index), estimate: update) ?? result
        }
        XCTAssertEqual(result, epochStart(12), "The movement at epoch 11 marks the end of being awake")
    }

    func testGapsNeitherConfirmNorBreak() {
        var detector = SleepOnsetDetector()
        var result: Date?
        for index in 0..<40 {
            let gap = (5..<25).contains(index)
            result = detector.update(epochStart: epochStart(index), estimate: estimate(asleep: 0.9, hasData: !gap)) ?? result
        }
        // Five epochs before the gap, five after it.
        XCTAssertEqual(result, epochStart(0))
    }
}

final class NapTrackerTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    /// Awake epochs come with movement (an arousal), sleeping ones without.
    func estimate(awake: Double, light: Double, deep: Double, hasData: Bool = true) -> OnlineEstimate {
        OnlineEstimate(epochIndex: 0, probabilities: StageProbabilities(awake: awake, light: light, deep: deep), arousal: awake >= 0.5, hasData: hasData, activity: 0)
    }

    func epochStart(_ index: Int) -> Date { start.addingTimeInterval(Double(index) * 30) }

    func testCountingStartsAtSleepOnset() {
        var tracker = NapTracker(plan: .powerNap(minutes: 20), key: "nap", start: start)
        var update = NapTracker.Update.none
        var index = 0
        while index < 200 {
            let asleep = index >= 10
            update = tracker.update(epochStart: epochStart(index), estimate: asleep ? estimate(awake: 0.1, light: 0.85, deep: 0.05) : estimate(awake: 0.9, light: 0.1, deep: 0))
            if case .countingStarted = update { break }
            index += 1
        }
        guard case .countingStarted(let at, let detected, let occurrence) = update else {
            return XCTFail("Counting never started")
        }
        XCTAssertTrue(detected)
        XCTAssertEqual(at, epochStart(10))
        XCTAssertEqual(occurrence.deadline, epochStart(10).addingTimeInterval(20 * 60))
        XCTAssertEqual(tracker.occurrence, occurrence)
    }

    func testCountingStartsAnywayWhenNoSleepIsDetected() {
        let plan = NapPlan.powerNap(minutes: 20)
        var tracker = NapTracker(plan: plan, key: "nap", start: start)
        var result: NapTracker.Update = .none
        for index in 0..<100 {
            let update = tracker.update(epochStart: epochStart(index), estimate: estimate(awake: 0.95, light: 0.05, deep: 0))
            if case .countingStarted = update {
                result = update
                break
            }
        }
        XCTAssertEqual(result, .countingStarted(at: plan.latestCountStart(start: start), sleepDetected: false, occurrence: plan.occurrence(key: "nap", start: start, onset: nil)))
        XCTAssertFalse(tracker.sleepDetected)
    }

    func testPowerNapWakesWhenDeepSleepBegins() {
        let plan = NapPlan.powerNap(minutes: 30)
        var tracker = NapTracker(plan: plan, key: "nap", start: start)
        var woke: Int?
        for index in 0..<120 {
            let probabilities: OnlineEstimate
            switch index {
            case 0..<6: probabilities = estimate(awake: 0.9, light: 0.1, deep: 0)
            case 6..<40: probabilities = estimate(awake: 0.05, light: 0.9, deep: 0.05)
            default: probabilities = estimate(awake: 0.02, light: 0.18, deep: 0.8)
            }
            if tracker.update(epochStart: epochStart(index), estimate: probabilities) == .wakeBeforeDeepSleep {
                woke = index
                break
            }
        }
        // Deep sleep from epoch 40; two epochs confirm it.
        XCTAssertEqual(woke, 41)
    }

    func testDeepSleepGuardWaitsForMinimumSleep() {
        let plan = NapPlan.powerNap(minutes: 30)
        var tracker = NapTracker(plan: plan, key: "nap", start: start)
        var woke: Int?
        for index in 0..<120 {
            let probabilities = index < 2 ? estimate(awake: 0.9, light: 0.1, deep: 0) : estimate(awake: 0.02, light: 0.3, deep: 0.68)
            if tracker.update(epochStart: epochStart(index), estimate: probabilities) == .wakeBeforeDeepSleep {
                woke = index
                break
            }
        }
        guard let woke, let countStart = tracker.countStart else { return XCTFail("Guard never fired") }
        XCTAssertGreaterThanOrEqual(epochStart(woke + 1).timeIntervalSince(countStart), plan.minimumSleepBeforeGuard)
    }

    func testRestoredTrackerKeepsItsCountStart() {
        let plan = NapPlan.cycles(2)
        let onset = start.addingTimeInterval(11 * 60)
        let tracker = NapTracker(plan: plan, key: "nap", start: start, countStart: onset, sleepDetected: true)
        XCTAssertEqual(tracker.countStart, onset)
        XCTAssertTrue(tracker.sleepDetected)
        XCTAssertEqual(tracker.occurrence.deadline, onset.addingTimeInterval(3 * 3600))
        // A stored count start after the latest possible one is capped.
        let capped = NapTracker(plan: plan, key: "nap", start: start, countStart: start.addingTimeInterval(5 * 3600))
        XCTAssertEqual(capped.occurrence.deadline, plan.latestDeadline(start: start))
    }

    func testCycleNapsHaveNoDeepSleepGuard() {
        var tracker = NapTracker(plan: .cycles(1), key: "nap", start: start)
        for index in 0..<400 {
            let update = tracker.update(epochStart: epochStart(index), estimate: estimate(awake: 0.02, light: 0.1, deep: 0.88))
            XCTAssertNotEqual(update, .wakeBeforeDeepSleep)
        }
    }
}

/// End-to-end: simulated naps through the online estimator, the nap tracker and the Smart Alarm.
final class NapSimulationTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    struct Outcome {
        var wake: Date?
        var reason: WakeReason?
        var countStart: Date?
        var sleepDetected: Bool
        var deadline: Date
        var truth: [SleepStage]
        var trueOnset: Date?
        var trueDeepStart: Date?

        func truthStage(at date: Date, start: Date) -> SleepStage? {
            let index = Int(date.timeIntervalSince(start) / SleepConstants.epochLength) - 1
            return truth.indices.contains(index) ? truth[index] : nil
        }
    }

    func run(_ plan: NapPlan, method: TrackingMethod, seed: UInt64, latency: TimeInterval = 12 * 60) -> Outcome {
        let length = plan.latestDeadline(start: start).timeIntervalSince(start) + 20 * 60
        let scenario = NightScenario(method: method, bedtime: start, timeInBed: length, sleepLatency: latency, awakenings: 0, snoringPropensity: 0.15, restlessness: 0.3)
        let night = NightSimulator.simulate(scenario, seed: seed)
        let estimator = OnlineSleepEstimator(method: method)
        var tracker = NapTracker(plan: plan, key: "nap", start: start)
        var engine = SmartAlarmEngine()
        let onsetIndex = night.groundTruth.firstIndex { $0 != .awake }
        let deepIndex = night.groundTruth.firstIndex { $0 == .deep }
        var outcome = Outcome(
            wake: nil,
            reason: nil,
            countStart: nil,
            sleepDetected: false,
            deadline: plan.latestDeadline(start: start),
            truth: night.groundTruth,
            trueOnset: onsetIndex.map { start.addingTimeInterval(Double($0) * SleepConstants.epochLength) },
            trueDeepStart: deepIndex.map { start.addingTimeInterval(Double($0) * SleepConstants.epochLength) }
        )
        for epoch in night.epochs {
            let estimate = estimator.update(with: epoch)
            let now = epoch.end
            let update = tracker.update(epochStart: epoch.start, estimate: estimate)
            if case .countingStarted(let at, let detected, let occurrence) = update {
                outcome.countStart = at
                outcome.sleepDetected = detected
                XCTAssertLessThanOrEqual(occurrence.deadline, plan.latestDeadline(start: start), "The deadline may only move earlier")
                outcome.deadline = occurrence.deadline
            }
            if update == .wakeBeforeDeepSleep {
                outcome.wake = now
                outcome.reason = .beforeDeepSleep
                return outcome
            }
            if case .wake(let reason) = engine.evaluate(now: now, occurrence: tracker.occurrence, estimate: estimate) {
                outcome.wake = now
                outcome.reason = reason
                return outcome
            }
        }
        return outcome
    }

    func testSleepOnsetIsFoundWithinMinutes() {
        for method in [TrackingMethod.microphone, .motion] {
            var errors: [Double] = []
            for seed in UInt64(1)...12 {
                let outcome = run(.cycles(1), method: method, seed: seed)
                guard let countStart = outcome.countStart, let trueOnset = outcome.trueOnset else { continue }
                XCTAssertTrue(outcome.sleepDetected, "\(method) seed \(seed): sleep was not detected")
                errors.append(countStart.timeIntervalSince(trueOnset) / 60)
            }
            let summary = errors.map { String(format: "%.1f", $0) }.joined(separator: ", ")
            print("Onset error (\(method.rawValue)) in minutes: \(summary)")
            XCTAssertEqual(errors.count, 12)
            let close = errors.filter { abs($0) <= 4 }.count
            XCTAssertGreaterThanOrEqual(close, 10, "\(method): onset error too large: \(summary)")
            let mean = errors.reduce(0, +) / Double(max(1, errors.count))
            XCTAssertLessThanOrEqual(abs(mean), 3, "\(method): onset is biased by \(mean) min")
        }
    }

    func testPowerNapNeverRunsLateAndStopsDeepSleepEarly() {
        for method in [TrackingMethod.microphone, .motion] {
            var lines: [String] = []
            var intoDeep: [Double] = []
            for seed in UInt64(20)...31 {
                let plan = NapPlan.powerNap(minutes: 30)
                let outcome = run(plan, method: method, seed: seed)
                guard let wake = outcome.wake else { return XCTFail("\(method) seed \(seed): never woke") }
                XCTAssertLessThanOrEqual(wake, outcome.deadline.addingTimeInterval(SleepConstants.epochLength), "Never later than the deadline")
                XCTAssertLessThanOrEqual(wake, plan.latestDeadline(start: start).addingTimeInterval(SleepConstants.epochLength))
                if let deep = outcome.trueDeepStart, wake > deep {
                    intoDeep.append(wake.timeIntervalSince(deep) / 60)
                }
                let reason: String = outcome.reason?.rawValue ?? "-"
                let minute: Int = Int(wake.timeIntervalSince(start) / 60)
                let truth: String = outcome.truthStage(at: wake, start: start).map { String(describing: $0) } ?? "?"
                let onsetMinute: Double = (outcome.trueOnset?.timeIntervalSince(start) ?? -60) / 60
                let deepMinute: Double = (outcome.trueDeepStart?.timeIntervalSince(start) ?? -60) / 60
                let countMinute: Double = (outcome.countStart?.timeIntervalSince(start) ?? -60) / 60
                lines.append("seed \(seed): \(reason) at \(minute) min, truth \(truth); onset \(onsetMinute), counted from \(countMinute), deep from \(deepMinute)")
            }
            print("Power nap (\(method.rawValue)):\n" + lines.joined(separator: "\n"))
            // Woken at most a few minutes into deep sleep, never deep into it.
            let sorted = intoDeep.sorted()
            print("Minutes into deep sleep (\(method.rawValue)): \(sorted)")
            for minutes in sorted {
                XCTAssertLessThanOrEqual(minutes, 8, "\(method): woke \(minutes) min into deep sleep\n" + lines.joined(separator: "\n"))
            }
            if !sorted.isEmpty {
                XCTAssertLessThanOrEqual(sorted[sorted.count / 2], 4, "\(method): median too far into deep sleep")
            }
        }
    }

    func testOneCycleWakesInLightSleepInsideTheWindow() {
        for method in [TrackingMethod.microphone, .motion] {
            var lines: [String] = []
            var good = 0
            for seed in UInt64(40)...51 {
                let plan = NapPlan.cycles(1)
                let outcome = run(plan, method: method, seed: seed)
                guard let wake = outcome.wake else { return XCTFail("\(method) seed \(seed): never woke") }
                XCTAssertLessThanOrEqual(wake, outcome.deadline.addingTimeInterval(SleepConstants.epochLength), "Never later than the deadline")
                let stage = outcome.truthStage(at: wake, start: start)
                if stage != .deep { good += 1 }
                let reason: String = outcome.reason?.rawValue ?? "-"
                let minute: Int = Int(wake.timeIntervalSince(start) / 60)
                let deadlineMinute: Int = Int(outcome.deadline.timeIntervalSince(start) / 60)
                let truth: String = stage.map { String(describing: $0) } ?? "?"
                lines.append("seed \(seed): \(reason) at \(minute) min (deadline \(deadlineMinute)), truth \(truth)")
            }
            print("One cycle (\(method.rawValue)):\n" + lines.joined(separator: "\n"))
            XCTAssertGreaterThanOrEqual(good, 10, "\(method): woke from deep sleep too often\n" + lines.joined(separator: "\n"))
        }
    }

    func testNoSleepStillWakesAtTheLatestDeadline() {
        // Sleep latency longer than the whole session: the person never falls asleep.
        let plan = NapPlan.powerNap(minutes: 20)
        let outcome = run(plan, method: .motion, seed: 77, latency: 3 * 3600)
        guard let wake = outcome.wake else { return XCTFail("Never woke") }
        XCTAssertLessThanOrEqual(wake, plan.latestDeadline(start: start).addingTimeInterval(SleepConstants.epochLength))
    }
}
