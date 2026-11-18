import XCTest
@testable import SleepIntelligence
@testable import SleepModels
@testable import SleepSimulation

final class SleepMetricsTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_700_000_000)

    func hypnogram(_ stages: [SleepStage]) -> Hypnogram {
        Hypnogram(start: start, stages: stages, confidence: Array(repeating: 0.9, count: stages.count), hasData: Array(repeating: true, count: stages.count))
    }

    func epochs(_ count: Int) -> [EpochFeatures] {
        (0..<count).map { EpochFeatures(index: $0, start: start.addingTimeInterval(Double($0) * 30), audioCoverage: 1, motionCoverage: 1) }
    }

    func testDurationsOnsetAndInterruptions() {
        // 20 min awake, 3 h sleep, 6 min awake, 3 h sleep, 10 min awake at the end.
        var stages: [SleepStage] = Array(repeating: .awake, count: 40)
        stages += Array(repeating: .light, count: 200) + Array(repeating: .deep, count: 160)
        stages += Array(repeating: .awake, count: 12)
        stages += Array(repeating: .light, count: 360)
        stages += Array(repeating: .awake, count: 20)
        let end = start.addingTimeInterval(Double(stages.count) * 30)
        let metrics = SleepMetricsCalculator.metrics(hypnogram: hypnogram(stages), epochs: epochs(stages.count), soundEvents: [], movementEvents: [], sessionEnd: end)

        XCTAssertEqual(metrics.sleepOnset, start.addingTimeInterval(40 * 30))
        XCTAssertEqual(metrics.sleepLatency ?? 0, 20 * 60, accuracy: 0.1)
        XCTAssertEqual(metrics.totalSleep, 720 * 30, accuracy: 0.1)
        XCTAssertEqual(metrics.wakeAfterSleepOnset, 12 * 30, accuracy: 0.1)
        XCTAssertEqual(metrics.interruptions, 1)
        XCTAssertEqual(metrics.deepSleep, 160 * 30, accuracy: 0.1)
        XCTAssertEqual(metrics.lightSleep, 560 * 30, accuracy: 0.1)
        XCTAssertEqual(metrics.timeInBed, Double(stages.count) * 30, accuracy: 0.1)
        XCTAssertEqual(metrics.efficiency, 720.0 / Double(stages.count), accuracy: 0.001)
        XCTAssertEqual(metrics.finalAwakening, start.addingTimeInterval(Double(stages.count - 20) * 30))
        XCTAssertEqual(metrics.dataCoverage, 1, accuracy: 0.001)
    }

    func testBriefAwakeningIsNotAnInterruption() {
        var stages: [SleepStage] = Array(repeating: .light, count: 100)
        stages += Array(repeating: .awake, count: 3)
        stages += Array(repeating: .light, count: 100)
        let metrics = SleepMetricsCalculator.metrics(hypnogram: hypnogram(stages), epochs: epochs(stages.count), soundEvents: [], movementEvents: [], sessionEnd: start.addingTimeInterval(Double(stages.count) * 30))
        XCTAssertEqual(metrics.interruptions, 0)
        XCTAssertEqual(metrics.wakeAfterSleepOnset, 90, accuracy: 0.1)
    }

    func testNoSleep() {
        let stages = Array(repeating: SleepStage.awake, count: 120)
        let metrics = SleepMetricsCalculator.metrics(hypnogram: hypnogram(stages), epochs: epochs(120), soundEvents: [], movementEvents: [], sessionEnd: start.addingTimeInterval(3_600))
        XCTAssertNil(metrics.sleepOnset)
        XCTAssertEqual(metrics.totalSleep, 0)
        XCTAssertTrue(metrics.noSleepDetected)
        XCTAssertEqual(metrics.efficiency, 0)
    }

    func testOnsetRequiresSustainedSleep() {
        // Dozing for 3 minutes, awake again, then sustained sleep from epoch 30.
        var stages: [SleepStage] = Array(repeating: .awake, count: 10)
        stages += Array(repeating: .light, count: 6)
        stages += Array(repeating: .awake, count: 14)
        stages += Array(repeating: .light, count: 100)
        XCTAssertEqual(SleepMetricsCalculator.sleepOnsetIndex(stages), 30)
    }

    func testSoundEventCountsAndSnoring() {
        let stages = Array(repeating: SleepStage.light, count: 120)
        let sounds = [
            SoundEvent(start: start.addingTimeInterval(100), duration: 1.5, type: .snoring, confidence: 0.8, peakDecibels: -50, levelAboveFloor: 18),
            SoundEvent(start: start.addingTimeInterval(105), duration: 1.5, type: .snoring, confidence: 0.8, peakDecibels: -50, levelAboveFloor: 18),
            SoundEvent(start: start.addingTimeInterval(900), duration: 0.4, type: .coughing, confidence: 0.8, peakDecibels: -40, levelAboveFloor: 25)
        ]
        let metrics = SleepMetricsCalculator.metrics(hypnogram: hypnogram(stages), epochs: epochs(120), soundEvents: sounds, movementEvents: [], sessionEnd: start.addingTimeInterval(3_600))
        XCTAssertEqual(metrics.count(of: .snoring), 2)
        XCTAssertEqual(metrics.count(of: .coughing), 1)
        XCTAssertEqual(metrics.snoringDuration, 3, accuracy: 0.001)
    }
}

final class SleepStagerTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_700_000_000)

    func agreement(_ a: [SleepStage], _ b: [SleepStage]) -> Double {
        Double(zip(a, b).filter { $0 == $1 }.count) / Double(min(a.count, b.count))
    }

    func sleepWakeAgreement(_ a: [SleepStage], _ b: [SleepStage]) -> Double {
        Double(zip(a, b).filter { $0.isAsleep == $1.isAsleep }.count) / Double(min(a.count, b.count))
    }

    func testRecoversSimulatedMotionNights() {
        var threeClass: [Double] = []
        var sleepWake: [Double] = []
        for seed in 1...6 {
            let night = NightSimulator.simulate(NightScenario(method: .motion, bedtime: start), seed: UInt64(seed))
            let hypnogram = SleepStager().stage(epochs: night.epochs, method: .motion, sessionStart: start)
            XCTAssertEqual(hypnogram.count, night.groundTruth.count)
            threeClass.append(agreement(hypnogram.stages, night.groundTruth))
            sleepWake.append(sleepWakeAgreement(hypnogram.stages, night.groundTruth))
        }
        XCTAssertGreaterThan(Stats.mean(threeClass), 0.75, "3-class agreement \(threeClass)")
        XCTAssertGreaterThan(Stats.mean(sleepWake), 0.88, "sleep/wake agreement \(sleepWake)")
    }

    func testRecoversSimulatedMicrophoneNights() {
        var threeClass: [Double] = []
        for seed in 21...26 {
            let night = NightSimulator.simulate(NightScenario(method: .microphone, bedtime: start, snoringPropensity: 0.3), seed: UInt64(seed))
            let hypnogram = SleepStager().stage(epochs: night.epochs, method: .microphone, sessionStart: start)
            threeClass.append(agreement(hypnogram.stages, night.groundTruth))
        }
        XCTAssertGreaterThan(Stats.mean(threeClass), 0.7, "3-class agreement \(threeClass)")
    }

    func testNoFlickeringDeepBouts() {
        let night = NightSimulator.simulate(NightScenario(method: .motion, bedtime: start, restlessness: 0.8), seed: 99)
        let hypnogram = SleepStager().stage(epochs: night.epochs, method: .motion, sessionStart: start)
        for segment in hypnogram.segments where segment.stage == .deep {
            XCTAssertGreaterThanOrEqual(segment.duration, 10 * 30 - 0.1, "deep bout of \(segment.duration) s")
        }
    }

    func testConfidenceIsAProbability() {
        let night = NightSimulator.simulate(NightScenario(method: .microphone, bedtime: start), seed: 5)
        let hypnogram = SleepStager().stage(epochs: night.epochs, method: .microphone, sessionStart: start)
        XCTAssertTrue(hypnogram.confidence.allSatisfy { $0 >= 0 && $0 <= 1 })
        let posteriors = SleepStager().posteriors(epochs: night.epochs, method: .microphone)
        for p in posteriors {
            XCTAssertEqual(p.awake + p.light + p.deep, 1, accuracy: 1e-9)
        }
    }

    func testGapsAreMarkedAndFilled() {
        let scenario = NightScenario(method: .motion, bedtime: start, gaps: [(2 * 3600)...(2.5 * 3600)])
        let night = NightSimulator.simulate(scenario, seed: 3)
        let hypnogram = SleepStager().stage(epochs: night.epochs, method: .motion, sessionStart: start)
        let gapEpochs = hypnogram.hasData.enumerated().filter { !$0.element }.map(\.offset)
        XCTAssertGreaterThanOrEqual(gapEpochs.count, 58)
        // Epochs without data still get a state (inferred from neighbours).
        XCTAssertEqual(hypnogram.stages.count, night.groundTruth.count)
    }

    func testCompletelyStillNightIsMostlyAsleep() {
        let epochs = (0..<600).map { index in
            EpochFeatures(index: index, start: start.addingTimeInterval(Double(index) * 30), motionCoverage: 1, movementActivity: index < 20 ? 6 : 0)
        }
        let hypnogram = SleepStager().stage(epochs: epochs, method: .motion, sessionStart: start)
        let asleep = hypnogram.stages.filter(\.isAsleep).count
        XCTAssertGreaterThan(Double(asleep) / 600, 0.9)
        XCTAssertEqual(hypnogram.stages.first, .awake)
    }

    func testPickupForcesAwake() {
        var epochs = (0..<200).map { index in
            EpochFeatures(index: index, start: start.addingTimeInterval(Double(index) * 30), motionCoverage: 1, movementActivity: 0.05)
        }
        for index in 100...103 {
            epochs[index].pickup = true
            epochs[index].movementActivity = 12
        }
        let hypnogram = SleepStager().stage(epochs: epochs, method: .motion, sessionStart: start)
        XCTAssertTrue((100...103).contains { hypnogram.stages[$0] == .awake })
    }
}

final class OnlineEstimatorTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_700_000_000)

    func testTracksAwakeAndSleep() {
        let estimator = OnlineSleepEstimator(method: .motion)
        var last: OnlineEstimate?
        for index in 0..<40 {
            last = estimator.update(with: EpochFeatures(index: index, start: start.addingTimeInterval(Double(index) * 30), motionCoverage: 1, movementActivity: 8))
        }
        XCTAssertGreaterThan(last?.probabilities.awake ?? 0, 0.8)
        for index in 40..<200 {
            last = estimator.update(with: EpochFeatures(index: index, start: start.addingTimeInterval(Double(index) * 30), motionCoverage: 1, movementActivity: 0.02))
        }
        XCTAssertLessThan(last?.probabilities.awake ?? 1, 0.2)
        XCTAssertFalse(last?.arousal ?? true)
    }

    func testArousalAfterStillness() {
        let estimator = OnlineSleepEstimator(method: .motion)
        for index in 0..<120 {
            estimator.update(with: EpochFeatures(index: index, start: start.addingTimeInterval(Double(index) * 30), motionCoverage: 1, movementActivity: index % 9 == 0 ? 2 : 0.05))
        }
        let estimate = estimator.update(with: EpochFeatures(index: 120, start: start.addingTimeInterval(120 * 30), motionCoverage: 1, movementActivity: 5))
        XCTAssertTrue(estimate.arousal)
        XCTAssertGreaterThan(estimate.probabilities.light + estimate.probabilities.awake, 0.5)
    }

    func testMissingEpochsArePropagated() {
        let estimator = OnlineSleepEstimator(method: .microphone)
        estimator.update(with: EpochFeatures(index: 0, start: start, audioCoverage: 1))
        let estimate = estimator.update(with: EpochFeatures(index: 10, start: start.addingTimeInterval(300), audioCoverage: 1))
        XCTAssertEqual(estimate.epochIndex, 10)
        XCTAssertEqual(estimator.epochsProcessed, 11)
    }

    func testNoDataEpochReportsNoData() {
        let estimator = OnlineSleepEstimator(method: .microphone)
        let estimate = estimator.update(with: EpochFeatures(index: 0, start: start, audioCoverage: 0.1))
        XCTAssertFalse(estimate.hasData)
        XCTAssertFalse(estimate.arousal)
    }
}
