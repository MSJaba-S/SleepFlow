import XCTest
@testable import MotionAnalysis
@testable import SleepModels
@testable import SleepSimulation

final class MotionAnalyzerTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_700_000_000)

    func run(_ samples: [AccelerometerSample]) -> MotionAnalysisOutput {
        let analyzer = MotionAnalyzer(sessionStart: start, expectedSampleRate: 20)
        var output = MotionAnalysisOutput()
        // Deliver in 1-second batches like CoreMotion's queue does.
        var index = 0
        while index < samples.count {
            let end = min(index + 20, samples.count)
            let result = analyzer.process(Array(samples[index..<end]))
            output.epochs.append(contentsOf: result.epochs)
            output.events.append(contentsOf: result.events)
            index = end
        }
        let final = analyzer.finish()
        output.epochs.append(contentsOf: final.epochs)
        output.events.append(contentsOf: final.events)
        return output
    }

    func testStillPhoneHasNoMovement() {
        var synth = SignalSynthesizer(seed: 11)
        let output = run(synth.accelerometer(start: start, duration: 95))
        XCTAssertTrue(output.events.isEmpty, "\(output.events)")
        XCTAssertEqual(output.epochs.map(\.epochIndex), [0, 1, 2, 3])
        for epoch in output.epochs where epoch.coveredSeconds > 20 {
            XCTAssertEqual(epoch.activity, 0, accuracy: 0.001)
            XCTAssertEqual(epoch.stillnessFraction, 1, accuracy: 0.001)
            XCTAssertFalse(epoch.pickup)
        }
    }

    func testMovementsAreDetectedAndTyped() {
        var synth = SignalSynthesizer(seed: 12)
        let samples = synth.accelerometer(start: start, duration: 95, movements: [
            .init(offset: 40, duration: 4, magnitude: 0.15),
            .init(offset: 70, duration: 3, magnitude: 0.03)
        ])
        let output = run(samples)
        XCTAssertEqual(output.events.count, 2, "\(output.events)")
        XCTAssertEqual(output.events.first?.kind, .large)
        XCTAssertEqual(output.events.last?.kind, .small)
        let epoch1 = output.epochs.first { $0.epochIndex == 1 }
        XCTAssertGreaterThan(epoch1?.activity ?? 0, 0)
        XCTAssertEqual(epoch1?.movementCount, 1)
        XCTAssertEqual(epoch1?.largeMovementCount, 1)
        XCTAssertLessThan(epoch1?.stillnessFraction ?? 1, 1)
        let start0 = output.events.first?.start.timeIntervalSince(start) ?? 0
        XCTAssertEqual(start0, 40, accuracy: 2)
    }

    func testTurningThePhoneOverIsAPickup() {
        var synth = SignalSynthesizer(seed: 13)
        let output = run(synth.accelerometer(start: start, duration: 95, flipAt: 50))
        XCTAssertTrue(output.events.contains { $0.kind == .pickup }, "\(output.events)")
        XCTAssertTrue(output.epochs.contains { $0.pickup })
    }

    func testGapClosesOpenMovement() {
        var synth = SignalSynthesizer(seed: 14)
        var samples = synth.accelerometer(start: start, duration: 30, movements: [.init(offset: 27, duration: 3, magnitude: 0.2)])
        samples += synth.accelerometer(start: start.addingTimeInterval(120), duration: 30)
        let output = run(samples)
        XCTAssertEqual(output.events.count, 1)
        XCTAssertFalse(output.epochs.contains { $0.epochIndex == 2 }, "No samples were recorded in epoch 2")
    }
}

final class MovementPatternTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_700_000_000)

    func testRegularMovementsFormAPattern() {
        let events = (0..<7).map { MovementEvent(start: start.addingTimeInterval(Double($0) * 30 + Double($0 % 2)), duration: 2, intensity: 0.02, kind: .small) }
        let patterns = MovementPatternDetector.detect(events: events)
        XCTAssertEqual(patterns.count, 1)
        XCTAssertEqual(patterns.first?.count, 7)
        XCTAssertEqual(patterns.first?.meanInterval ?? 0, 30, accuracy: 1.5)
    }

    func testIrregularMovementsDoNotFormAPattern() {
        let offsets: [Double] = [0, 200, 230, 900, 1_400, 1_420]
        let events = offsets.map { MovementEvent(start: start.addingTimeInterval($0), duration: 2, intensity: 0.02, kind: .small) }
        XCTAssertTrue(MovementPatternDetector.detect(events: events).isEmpty)
    }

    func testPickupsAreIgnored() {
        let events = (0..<6).map { MovementEvent(start: start.addingTimeInterval(Double($0) * 30), duration: 2, intensity: 0.5, kind: .pickup) }
        XCTAssertTrue(MovementPatternDetector.detect(events: events).isEmpty)
    }
}
