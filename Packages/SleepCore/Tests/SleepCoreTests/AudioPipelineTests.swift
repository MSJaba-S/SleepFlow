import XCTest
@testable import AudioAnalysis
@testable import SleepModels
@testable import SleepSimulation

/// End-to-end tests of the acoustic pipeline on synthesised audio.
final class AudioPipelineTests: XCTestCase {
    let sampleRate = 48_000.0
    let start = Date(timeIntervalSince1970: 1_700_000_000)

    /// Feeds the signal in 100 ms chunks like the microphone tap does.
    func analyse(_ signal: [Float], analyzer: AudioAnalyzer) -> AudioAnalysisOutput {
        var output = AudioAnalysisOutput()
        let chunk = Int(sampleRate / 10)
        var offset = 0
        while offset < signal.count {
            let end = min(offset + chunk, signal.count)
            let time = start.addingTimeInterval(Double(offset) / sampleRate)
            let result = analyzer.process(Array(signal[offset..<end]), startingAt: time)
            output.epochs.append(contentsOf: result.epochs)
            output.events.append(contentsOf: result.events)
            output.candidates.append(contentsOf: result.candidates)
            offset = end
        }
        let final = analyzer.finish()
        output.epochs.append(contentsOf: final.epochs)
        output.events.append(contentsOf: final.events)
        output.candidates.append(contentsOf: final.candidates)
        return output
    }

    func describe(_ output: AudioAnalysisOutput) -> String {
        zip(output.events, output.candidates).map { event, candidate in
            let s = candidate.summary
            return String(
                format: "%@ conf=%.2f dur=%.2f above=%.1f attack=%.1f centroid=%.0f flat=%.2f low=%.2f lowMid=%.2f mid=%.2f high=%.2f mod=%.1fHz/%.1fdB",
                event.type.rawValue, event.confidence, s.duration, s.peakAboveFloor, s.attack, s.centroid, s.flatness,
                s.bandLow, s.bandLowMid, s.bandMid, s.bandHigh, s.modulationRate, s.modulationDepth
            )
        }.joined(separator: "\n")
    }

    func testSilenceProducesNoEvents() {
        var synth = SignalSynthesizer(sampleRate: sampleRate, seed: 1)
        let analyzer = AudioAnalyzer(sampleRate: sampleRate, sessionStart: start)
        let output = analyse(synth.background(duration: 40), analyzer: analyzer)
        XCTAssertTrue(output.events.isEmpty, describe(output))
        XCTAssertFalse(output.epochs.isEmpty)
        XCTAssertEqual(output.epochs.first?.epochIndex, 0)
        XCTAssertGreaterThan(output.epochs.first?.coveredSeconds ?? 0, 25)
    }

    func testFrameSizeAdaptsToSampleRate() {
        XCTAssertEqual(AudioAnalyzer(sampleRate: 48_000, sessionStart: start).frameSize, 4096)
        XCTAssertEqual(AudioAnalyzer(sampleRate: 44_100, sessionStart: start).frameSize, 4096)
        XCTAssertEqual(AudioAnalyzer(sampleRate: 16_000, sessionStart: start).frameSize, 1024)
    }

    func testSnoringIsDetectedAndClassified() {
        var synth = SignalSynthesizer(sampleRate: sampleRate, seed: 2)
        var signal = synth.background(duration: 45)
        for index in 0..<8 {
            synth.mix(synth.snore(), into: &signal, at: 4 + Double(index) * 4.2)
        }
        let output = analyse(signal, analyzer: AudioAnalyzer(sampleRate: sampleRate, sessionStart: start))
        let snores = output.events.filter { $0.type == .snoring }
        XCTAssertGreaterThanOrEqual(output.events.count, 6, describe(output))
        XCTAssertGreaterThanOrEqual(snores.count, 5, describe(output))
        let snoreSeconds = output.epochs.reduce(0) { $0 + $1.snoreSeconds }
        XCTAssertGreaterThan(snoreSeconds, 5)
    }

    func testCoughIsClassified() {
        var synth = SignalSynthesizer(sampleRate: sampleRate, seed: 3)
        var signal = synth.background(duration: 20)
        synth.mix(synth.cough(), into: &signal, at: 6)
        synth.mix(synth.cough(), into: &signal, at: 12)
        let output = analyse(signal, analyzer: AudioAnalyzer(sampleRate: sampleRate, sessionStart: start))
        XCTAssertEqual(output.events.count, 2, describe(output))
        XCTAssertTrue(output.events.allSatisfy { $0.type == .coughing }, describe(output))
        XCTAssertEqual(output.epochs.reduce(0) { $0 + $1.coughCount }, 2)
    }

    func testSpeechIsClassified() {
        var synth = SignalSynthesizer(sampleRate: sampleRate, seed: 4)
        var signal = synth.background(duration: 20)
        synth.mix(synth.speech(duration: 2.6), into: &signal, at: 5)
        synth.mix(synth.speech(duration: 2.2), into: &signal, at: 12)
        let output = analyse(signal, analyzer: AudioAnalyzer(sampleRate: sampleRate, sessionStart: start))
        let talking = output.events.filter { $0.type == .talking }
        XCTAssertGreaterThanOrEqual(talking.count, 1, describe(output))
        XCTAssertGreaterThan(output.epochs.reduce(0) { $0 + $1.talkSeconds }, 1.5, describe(output))
    }

    func testRustleIsMovement() {
        var synth = SignalSynthesizer(sampleRate: sampleRate, seed: 5)
        var signal = synth.background(duration: 20)
        synth.mix(synth.rustle(), into: &signal, at: 5)
        synth.mix(synth.rustle(duration: 2.0), into: &signal, at: 11)
        let output = analyse(signal, analyzer: AudioAnalyzer(sampleRate: sampleRate, sessionStart: start))
        XCTAssertGreaterThanOrEqual(output.events.count, 1, describe(output))
        XCTAssertTrue(output.events.allSatisfy { $0.type == .movement }, describe(output))
        XCTAssertGreaterThan(output.epochs.reduce(0) { $0 + $1.soundActivity }, 0)
    }

    func testGapInTimestampsClosesEventsAndKeepsEpochTiming() {
        var synth = SignalSynthesizer(sampleRate: sampleRate, seed: 6)
        let analyzer = AudioAnalyzer(sampleRate: sampleRate, sessionStart: start)
        let first = synth.background(duration: 10)
        _ = analyzer.process(first, startingAt: start)
        // Next audio arrives 100 s later (e.g. after a phone call): it must land in epoch 3.
        let later = synth.background(duration: 40)
        var epochs: [AcousticEpochSummary] = []
        epochs.append(contentsOf: analyzer.process(later, startingAt: start.addingTimeInterval(110)).epochs)
        epochs.append(contentsOf: analyzer.finish().epochs)
        XCTAssertTrue(epochs.contains { $0.epochIndex == 0 })
        XCTAssertTrue(epochs.contains { $0.epochIndex == 3 })
        XCTAssertFalse(epochs.contains { $0.epochIndex == 1 }, "No audio was recorded during epoch 1")
    }

    func testRefinerIsConsulted() {
        final class FakeModel: SoundEventRefining {
            var calls = 0
            func modelDistribution(for candidate: EventCandidate) -> SoundTypeDistribution? {
                calls += 1
                return [.coughing: 0.95]
            }
        }
        var synth = SignalSynthesizer(sampleRate: sampleRate, seed: 8)
        var signal = synth.background(duration: 15)
        synth.mix(synth.rustle(), into: &signal, at: 5)
        let analyzer = AudioAnalyzer(sampleRate: sampleRate, sessionStart: start)
        let model = FakeModel()
        analyzer.refiner = model
        let output = analyse(signal, analyzer: analyzer)
        XCTAssertGreaterThan(model.calls, 0)
        XCTAssertTrue(output.events.allSatisfy { $0.verifiedByModel })
    }

    func testLevelReadingsAreThrottled() {
        var synth = SignalSynthesizer(sampleRate: sampleRate, seed: 9)
        let analyzer = AudioAnalyzer(sampleRate: sampleRate, sessionStart: start)
        let signal = synth.background(duration: 5)
        var readings = 0
        var offset = 0
        let chunk = 4_800
        while offset + chunk <= signal.count {
            if analyzer.process(Array(signal[offset..<(offset + chunk)]), startingAt: start.addingTimeInterval(Double(offset) / sampleRate)).level != nil {
                readings += 1
            }
            offset += chunk
        }
        XCTAssertGreaterThanOrEqual(readings, 3)
        XCTAssertLessThanOrEqual(readings, 6)
    }
}
