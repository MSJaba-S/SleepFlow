import XCTest
@testable import AudioAnalysis
@testable import SleepModels

final class FFTTests: XCTestCase {
    func sine(frequency: Double, amplitude: Float, count: Int, sampleRate: Double) -> [Float] {
        (0..<count).map { Float(Double(amplitude) * sin(2 * Double.pi * frequency * Double($0) / sampleRate)) }
    }

    func testPortableFFTFindsBinCentredSine() {
        let n = 1024
        let sampleRate = 16_000.0
        let bin = 64
        let frequency = Double(bin) * sampleRate / Double(n)
        let fft = RealFFT(size: n, useAccelerate: false)
        let magnitudes = fft.magnitudes(sine(frequency: frequency, amplitude: 1, count: n, sampleRate: sampleRate))
        XCTAssertEqual(magnitudes.count, n / 2 + 1)
        let peak = magnitudes.enumerated().max { $0.element < $1.element }?.offset
        XCTAssertEqual(peak, bin)
        // A full-scale sine centred on a bin has magnitude N/2.
        XCTAssertEqual(magnitudes[bin], Float(n) / 2, accuracy: Float(n) * 0.01)
        XCTAssertLessThan(magnitudes[bin + 5], 1)
    }

    func testDCComponent() {
        let n = 256
        let fft = RealFFT(size: n, useAccelerate: false)
        let magnitudes = fft.magnitudes([Float](repeating: 0.5, count: n))
        XCTAssertEqual(magnitudes[0], 0.5 * Float(n), accuracy: 0.01)
        XCTAssertEqual(magnitudes[1], 0, accuracy: 0.01)
    }

    func testAcceleratedMatchesPortableWhenAvailable() {
        let n = 2048
        var input = [Float](repeating: 0, count: n)
        for index in 0..<n {
            let t = Double(index) / 48_000
            let a: Double = 0.3 * sin(2 * Double.pi * 440 * t)
            let b: Double = 0.1 * sin(2 * Double.pi * 3_100 * t)
            let c: Double = 0.05 * cos(2 * Double.pi * 90 * t)
            input[index] = Float(a + b + c)
        }
        let portable = RealFFT(size: n, useAccelerate: false).magnitudes(input)
        let accelerated = RealFFT(size: n, useAccelerate: true)
        let result = accelerated.magnitudes(input)
        XCTAssertEqual(result.count, portable.count)
        for index in 0..<portable.count {
            XCTAssertEqual(result[index], portable[index], accuracy: max(0.002, portable[index] * 0.002), "bin \(index)")
        }
    }
}

final class FrameFeatureTests: XCTestCase {
    let sampleRate = 48_000.0
    let frameSize = 4096

    func sine(_ frequency: Double, amplitude: Float = 0.5) -> [Float] {
        (0..<frameSize).map { Float(Double(amplitude) * sin(2 * Double.pi * frequency * Double($0) / sampleRate)) }
    }

    func testLevelOfSine() {
        let extractor = FrameFeatureExtractor(sampleRate: sampleRate, frameSize: frameSize)
        let features = extractor.features(of: sine(1_000, amplitude: 0.5))
        // RMS of a sine is A/√2 → 0.3536 → -9.03 dBFS
        XCTAssertEqual(features.rms, 0.3536, accuracy: 0.005)
        XCTAssertEqual(features.decibels, -9.03, accuracy: 0.2)
    }

    func testZeroCrossingRateOfSine() {
        let extractor = FrameFeatureExtractor(sampleRate: sampleRate, frameSize: frameSize)
        let features = extractor.features(of: sine(1_200))
        // Two crossings per period: 2 · 1200 / 48000 = 0.05
        XCTAssertEqual(features.zeroCrossingRate, 0.05, accuracy: 0.003)
    }

    func testSpectralCentroidAndBands() {
        let extractor = FrameFeatureExtractor(sampleRate: sampleRate, frameSize: frameSize)
        let low = extractor.features(of: sine(120))
        XCTAssertEqual(low.spectralCentroid, 120, accuracy: 40)
        XCTAssertGreaterThan(low.bandLow, 0.9)

        extractor.reset()
        let high = extractor.features(of: sine(4_000))
        XCTAssertEqual(high.spectralCentroid, 4_000, accuracy: 150)
        XCTAssertGreaterThan(high.bandHigh, 0.9)
    }

    func testFlatnessSeparatesToneFromNoise() {
        let extractor = FrameFeatureExtractor(sampleRate: sampleRate, frameSize: frameSize)
        let tone = extractor.features(of: sine(700))
        var rng = SplitMix64(seed: 3)
        let noise = (0..<frameSize).map { _ in Float(rng.gaussian(sd: 0.1)) }
        let noisy = extractor.features(of: noise)
        XCTAssertLessThan(tone.spectralFlatness, 0.1)
        XCTAssertGreaterThan(noisy.spectralFlatness, 0.4)
    }

    func testSilenceIsAtFloor() {
        let extractor = FrameFeatureExtractor(sampleRate: sampleRate, frameSize: frameSize)
        let silent = extractor.features(of: [Float](repeating: 0, count: frameSize))
        XCTAssertEqual(silent.decibels, Decibels.floor)
        XCTAssertEqual(silent.spectralCentroid, 0)
    }

    func testMFCCShape() {
        let extractor = FrameFeatureExtractor(sampleRate: sampleRate, frameSize: frameSize)
        _ = extractor.features(of: sine(300))
        let mfcc = extractor.mfccOfLastFrame()
        XCTAssertEqual(mfcc.count, 13)
        XCTAssertTrue(mfcc.allSatisfy { $0.isFinite })
    }
}

final class NoiseFloorTests: XCTestCase {
    func testConvergesToAmbientLevel() {
        var estimator = NoiseFloorEstimator()
        var floor = 0.0
        for _ in 0..<400 { floor = estimator.update(frameDecibels: -62) }
        XCTAssertEqual(floor, -62, accuracy: 0.5)
    }

    func testShortEventsBarelyMoveTheFloor() {
        var estimator = NoiseFloorEstimator()
        for _ in 0..<200 { estimator.update(frameDecibels: -65) }
        var floor = 0.0
        for _ in 0..<20 { floor = estimator.update(frameDecibels: -35) }
        XCTAssertLessThan(floor, -62, "A 1 s loud event must not lift the floor by more than a few dB")
    }

    func testFollowsQuieterRoomQuickly() {
        var estimator = NoiseFloorEstimator()
        for _ in 0..<200 { estimator.update(frameDecibels: -50) }
        var floor = 0.0
        for _ in 0..<60 { floor = estimator.update(frameDecibels: -70) }
        XCTAssertLessThan(floor, -68)
    }

    func testFrozenFloorDoesNotMove() {
        var estimator = NoiseFloorEstimator()
        for _ in 0..<100 { estimator.update(frameDecibels: -60) }
        let before = estimator.floor ?? 0
        for _ in 0..<50 { estimator.update(frameDecibels: -20, frozen: true) }
        XCTAssertEqual(estimator.floor ?? 0, before, accuracy: 0.0001)
    }
}

final class BreathingTests: XCTestCase {
    func testDetectsFifteenBreathsPerMinute() {
        let hop = 0.0427
        let count = Int(30 / hop)
        let levels: [Double?] = (0..<count).map { index in
            let t = Double(index) * hop
            return -66 + 1.2 * sin(2 * Double.pi * t / 4.0)
        }
        let result = BreathingAnalyzer.analyse(levels: levels, hopDuration: hop)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.breathsPerMinute ?? 0, 15, accuracy: 1.5)
        XCTAssertGreaterThan(result?.regularity ?? 0, 0.6)
    }

    func testFlatEnvelopeHasNoRhythm() {
        let levels: [Double?] = Array(repeating: -70, count: 700)
        XCTAssertNil(BreathingAnalyzer.analyse(levels: levels, hopDuration: 0.0427))
    }

    func testMostlyMissingDataIsRejected() {
        let levels: [Double?] = (0..<700).map { $0 % 3 == 0 ? -66 : nil }
        XCTAssertNil(BreathingAnalyzer.analyse(levels: levels, hopDuration: 0.0427))
    }
}

final class ClassifierUnitTests: XCTestCase {
    func summary(
        duration: Double, peakAbove: Double, attack: Double, centroid: Double, flatness: Double,
        low: Double, lowMid: Double, mid: Double, high: Double, modulationRate: Double = 0, modulationDepth: Double = 0
    ) -> EventFeatureSummary {
        EventFeatureSummary(
            duration: duration, peakDecibels: -60 + peakAbove, peakAboveFloor: peakAbove, meanAboveFloor: peakAbove * 0.6,
            attack: attack, centroid: centroid, rolloff: centroid * 2, flatness: flatness, zeroCrossingRate: 0.05,
            bandLow: low, bandLowMid: lowMid, bandMid: mid, bandHigh: high, fluxMean: 0.1, fluxDeviation: 0.05,
            modulationRate: modulationRate, modulationDepth: modulationDepth, mfcc: Array(repeating: 0, count: 13)
        )
    }

    func candidate(_ summary: EventFeatureSummary, at seconds: Double) -> EventCandidate {
        EventCandidate(start: Date(timeIntervalSince1970: 1_000 + seconds), summary: summary, startSample: 0, endSample: 1)
    }

    func top(_ distribution: SoundTypeDistribution) -> SoundEventType? {
        distribution.max { $0.value < $1.value }?.key
    }

    func testProbabilitiesSumToOne() {
        var classifier = RuleBasedSoundClassifier()
        let distribution = classifier.classify(candidate(summary(duration: 1, peakAbove: 12, attack: 6, centroid: 800, flatness: 0.3, low: 0.2, lowMid: 0.3, mid: 0.3, high: 0.2), at: 0))
        XCTAssertEqual(distribution.values.reduce(0, +), 1, accuracy: 1e-9)
    }

    func testRhythmicLowFrequencyEventsAreSnoring() {
        var classifier = RuleBasedSoundClassifier()
        let snore = summary(duration: 1.3, peakAbove: 16, attack: 5, centroid: 260, flatness: 0.08, low: 0.75, lowMid: 0.2, mid: 0.04, high: 0.01)
        var last: SoundTypeDistribution = [:]
        for index in 0..<5 {
            last = classifier.classify(candidate(snore, at: Double(index) * 4.1))
        }
        XCTAssertEqual(top(last), .snoring)
    }

    func testExplosiveBroadbandBurstIsCough() {
        var classifier = RuleBasedSoundClassifier()
        let cough = summary(duration: 0.35, peakAbove: 26, attack: 22, centroid: 1_600, flatness: 0.42, low: 0.05, lowMid: 0.3, mid: 0.45, high: 0.2)
        XCTAssertEqual(top(classifier.classify(candidate(cough, at: 0))), .coughing)
    }

    func testModulatedSpeechBandIsTalking() {
        var classifier = RuleBasedSoundClassifier()
        let talk = summary(duration: 2.4, peakAbove: 18, attack: 7, centroid: 950, flatness: 0.12, low: 0.1, lowMid: 0.5, mid: 0.35, high: 0.05, modulationRate: 4, modulationDepth: 12)
        XCTAssertEqual(top(classifier.classify(candidate(talk, at: 0))), .talking)
    }

    func testSoftNoiseLikeSoundIsMovement() {
        var classifier = RuleBasedSoundClassifier()
        let rustle = summary(duration: 1.6, peakAbove: 11, attack: 4, centroid: 3_400, flatness: 0.62, low: 0.02, lowMid: 0.08, mid: 0.4, high: 0.5)
        XCTAssertEqual(top(classifier.classify(candidate(rustle, at: 0))), .movement)
    }

    func testVeryLoudLongSoundIsDisturbance() {
        var classifier = RuleBasedSoundClassifier()
        let truck = summary(duration: 9, peakAbove: 34, attack: 9, centroid: 600, flatness: 0.35, low: 0.4, lowMid: 0.3, mid: 0.2, high: 0.1)
        XCTAssertEqual(top(classifier.classify(candidate(truck, at: 0))), .disturbance)
    }

    func testLowConfidenceBecomesUnknown() {
        let flat: SoundTypeDistribution = [.snoring: 0.2, .talking: 0.2, .movement: 0.2, .coughing: 0.2, .disturbance: 0.2]
        let decision = RuleBasedSoundClassifier.decide(flat, minimumConfidence: 0.4)
        XCTAssertEqual(decision.type, .unknown)
    }

    func testFusionRespectsModelAndKeepsUncoveredClasses() {
        let rule: SoundTypeDistribution = [.snoring: 0.3, .talking: 0.1, .movement: 0.5, .coughing: 0.05, .disturbance: 0.05]
        let model: SoundTypeDistribution = [.snoring: 0.9]
        let fused = ClassifierFusion.fuse(rule: rule, model: model)
        XCTAssertEqual(fused.values.reduce(0, +), 1, accuracy: 1e-9)
        XCTAssertEqual(fused.max { $0.value < $1.value }?.key, .snoring)
        XCTAssertGreaterThan(fused[.movement] ?? 0, 0)
        XCTAssertEqual(ClassifierFusion.fuse(rule: rule, model: nil), rule)
    }
}
