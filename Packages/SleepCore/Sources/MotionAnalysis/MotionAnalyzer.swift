import Foundation
import SleepModels

/// One accelerometer reading in g.
public struct AccelerometerSample: Sendable, Hashable {
    public var timestamp: Date
    public var x: Double
    public var y: Double
    public var z: Double

    public init(timestamp: Date, x: Double, y: Double, z: Double) {
        self.timestamp = timestamp
        self.x = x
        self.y = y
        self.z = z
    }
}

/// Movement statistics for one 30-second epoch.
public struct MotionEpochSummary: Codable, Sendable, Hashable {
    public var epochIndex: Int
    public var coveredSeconds: Double
    /// Sum of per-second activity (excess over the adaptive threshold, capped at 10 per second).
    public var activity: Double
    public var movementCount: Int
    public var largeMovementCount: Int
    /// Fraction of covered seconds without movement.
    public var stillnessFraction: Double
    /// Largest per-second RMS of gravity-free acceleration, in g.
    public var maxIntensity: Double
    public var pickup: Bool

    public init(
        epochIndex: Int,
        coveredSeconds: Double = 0,
        activity: Double = 0,
        movementCount: Int = 0,
        largeMovementCount: Int = 0,
        stillnessFraction: Double = 1,
        maxIntensity: Double = 0,
        pickup: Bool = false
    ) {
        self.epochIndex = epochIndex
        self.coveredSeconds = coveredSeconds
        self.activity = activity
        self.movementCount = movementCount
        self.largeMovementCount = largeMovementCount
        self.stillnessFraction = stillnessFraction
        self.maxIntensity = maxIntensity
        self.pickup = pickup
    }
}

public struct MotionAnalysisOutput: Sendable {
    public var epochs: [MotionEpochSummary] = []
    public var events: [MovementEvent] = []
    public init() {}

    mutating func merge(_ other: MotionAnalysisOutput) {
        epochs.append(contentsOf: other.epochs)
        events.append(contentsOf: other.events)
    }
}

public struct MotionAnalysisConfiguration: Sendable {
    /// Cut-off of the gravity low-pass filter.
    public var gravityCutoff: Double = 0.4
    /// Movement threshold relative to the adaptive sensor-noise baseline.
    public var thresholdFactor: Double = 3.0
    /// Absolute lower bound for the threshold in g (iPhone sensor noise is ≈ 0.002–0.004 g).
    public var minimumThreshold: Double = 0.006
    public var largeMovementRMS: Double = 0.05
    public var suddenMovementPeak: Double = 0.35
    /// Orientation change that counts as the phone being picked up or turned over.
    public var pickupAngleDegrees: Double = 40
    public var pickupPeak: Double = 0.8
    /// Inactive seconds allowed inside one movement event.
    public var mergeGapSeconds: Int = 2

    public init() {}
}

/// Accelerometer pipeline: gravity removal (one-pole low-pass per axis), per-second RMS,
/// adaptive noise baseline, thresholding with hysteresis-free merging, event typing and
/// pickup detection from orientation changes.
public final class MotionAnalyzer {
    public let sessionStart: Date
    public let expectedSampleRate: Double
    public let configuration: MotionAnalysisConfiguration

    private var gravity: (x: Double, y: Double, z: Double)?
    private var lastTimestamp: Date?
    private var secondIndex: Int?
    private var secondSumSquares = 0.0
    private var secondCount = 0
    private var secondPeak = 0.0
    private var secondGravity: (x: Double, y: Double, z: Double) = (0, 0, -1)

    private var baseline = 0.003
    private var referenceOrientation: (x: Double, y: Double, z: Double)?
    private var stillSeconds = 0
    private var pickupCooldown = 0

    private var openEvent: (startSecond: Int, lastActive: Int, maxRMS: Double, peak: Double, pickup: Bool)?
    private var inactiveRun = 0

    private var accumulators: [Int: MotionAccumulator] = [:]

    public init(sessionStart: Date, expectedSampleRate: Double, configuration: MotionAnalysisConfiguration = MotionAnalysisConfiguration()) {
        self.sessionStart = sessionStart
        self.expectedSampleRate = expectedSampleRate
        self.configuration = configuration
    }

    public var currentBaseline: Double { baseline }

    public func process(_ samples: [AccelerometerSample]) -> MotionAnalysisOutput {
        var output = MotionAnalysisOutput()
        for sample in samples {
            output.merge(process(sample))
        }
        return output
    }

    public func finish() -> MotionAnalysisOutput {
        var output = MotionAnalysisOutput()
        output.merge(closeSecond())
        if let event = closeEvent() { output.events.append(event) }
        for index in accumulators.keys.sorted() {
            if let accumulator = accumulators.removeValue(forKey: index) {
                output.epochs.append(accumulator.summary)
            }
        }
        return output
    }

    private func process(_ sample: AccelerometerSample) -> MotionAnalysisOutput {
        var output = MotionAnalysisOutput()
        if let last = lastTimestamp, sample.timestamp.timeIntervalSince(last) > 2.0 {
            // Data gap: close the current second and any open movement.
            output.merge(closeSecond())
            if let event = closeEvent() { output.events.append(event) }
            gravity = nil
        }
        lastTimestamp = sample.timestamp

        let dt = 1.0 / max(expectedSampleRate, 1)
        let alpha = 1 - exp(-2 * Double.pi * configuration.gravityCutoff * dt)
        if var g = gravity {
            g.x += alpha * (sample.x - g.x)
            g.y += alpha * (sample.y - g.y)
            g.z += alpha * (sample.z - g.z)
            gravity = g
        } else {
            gravity = (sample.x, sample.y, sample.z)
        }
        let g = gravity ?? (sample.x, sample.y, sample.z)
        let dx = sample.x - g.x
        let dy = sample.y - g.y
        let dz = sample.z - g.z
        let dynamic = (dx * dx + dy * dy + dz * dz).squareRoot()

        let second = Int(sample.timestamp.timeIntervalSince(sessionStart).rounded(.down))
        if let current = secondIndex, second != current {
            output.merge(closeSecond())
        }
        if secondIndex == nil { secondIndex = second }
        secondSumSquares += dynamic * dynamic
        secondCount += 1
        secondPeak = max(secondPeak, dynamic)
        secondGravity = g
        return output
    }

    /// Finalises the current one-second bin.
    private func closeSecond() -> MotionAnalysisOutput {
        var output = MotionAnalysisOutput()
        guard let second = secondIndex, secondCount > 0 else {
            secondIndex = nil
            return output
        }
        let rms = (secondSumSquares / Double(secondCount)).squareRoot()
        let peak = secondPeak
        let coverage = min(1, Double(secondCount) / max(expectedSampleRate * 0.5, 1))
        let orientation = secondGravity
        secondIndex = nil
        secondSumSquares = 0
        secondCount = 0
        secondPeak = 0

        let threshold = max(baseline * configuration.thresholdFactor, configuration.minimumThreshold)
        let active = rms > threshold
        // Fast-falling, slow-rising baseline of sensor noise.
        if rms < baseline {
            baseline += (rms - baseline) * 0.2
        } else if !active {
            baseline += (rms - baseline) * 0.01
        }
        baseline = max(baseline, 0.0005)

        // Pickup: large orientation change against the still reference, or a very large jolt.
        var pickup = false
        if pickupCooldown > 0 { pickupCooldown -= 1 }
        if let reference = referenceOrientation {
            let angle = MotionAnalyzer.angleDegrees(reference, orientation)
            if pickupCooldown == 0 && (angle >= configuration.pickupAngleDegrees || peak >= configuration.pickupPeak) {
                pickup = true
                pickupCooldown = 30
                referenceOrientation = orientation
            }
        }
        if active {
            stillSeconds = 0
        } else {
            stillSeconds += 1
            if stillSeconds >= 10 { referenceOrientation = orientation }
        }
        if referenceOrientation == nil { referenceOrientation = orientation }

        let epochIndex = second / Int(SleepConstants.epochLength)
        if epochIndex >= 0 {
            var accumulator = accumulators[epochIndex] ?? MotionAccumulator(index: epochIndex)
            accumulator.coveredSeconds += coverage
            accumulator.coveredBins += 1
            if active {
                accumulator.activity += min(10, (rms - threshold) / threshold)
                accumulator.activeBins += 1
            }
            accumulator.maxIntensity = max(accumulator.maxIntensity, rms)
            if pickup { accumulator.pickup = true }
            accumulators[epochIndex] = accumulator
        }

        // Event bookkeeping.
        if active || pickup {
            if var event = openEvent {
                event.lastActive = second
                event.maxRMS = max(event.maxRMS, rms)
                event.peak = max(event.peak, peak)
                event.pickup = event.pickup || pickup
                openEvent = event
            } else {
                openEvent = (startSecond: second, lastActive: second, maxRMS: rms, peak: peak, pickup: pickup)
            }
            inactiveRun = 0
        } else if openEvent != nil {
            inactiveRun += 1
            if inactiveRun > configuration.mergeGapSeconds, let event = closeEvent() {
                output.events.append(event)
            }
        }

        // Epochs that can no longer change are emitted.
        let completedBefore = epochIndex
        for index in accumulators.keys.sorted() where index < completedBefore {
            if let openEvent, openEvent.startSecond / Int(SleepConstants.epochLength) <= index { break }
            if let accumulator = accumulators.removeValue(forKey: index) {
                output.epochs.append(accumulator.summary)
            }
        }
        return output
    }

    private func closeEvent() -> MovementEvent? {
        guard let event = openEvent else { return nil }
        openEvent = nil
        inactiveRun = 0
        let kind: MovementKind
        if event.pickup {
            kind = .pickup
        } else if event.peak >= configuration.suddenMovementPeak {
            kind = .sudden
        } else if event.maxRMS >= configuration.largeMovementRMS {
            kind = .large
        } else {
            kind = .small
        }
        let start = sessionStart.addingTimeInterval(Double(event.startSecond))
        let duration = Double(event.lastActive - event.startSecond + 1)
        let epochIndex = event.startSecond / Int(SleepConstants.epochLength)
        var accumulator = accumulators[epochIndex] ?? MotionAccumulator(index: epochIndex)
        accumulator.movementCount += 1
        if kind == .large || kind == .sudden { accumulator.largeMovementCount += 1 }
        accumulators[epochIndex] = accumulator
        return MovementEvent(start: start, duration: duration, intensity: event.maxRMS, kind: kind)
    }

    static func angleDegrees(_ a: (x: Double, y: Double, z: Double), _ b: (x: Double, y: Double, z: Double)) -> Double {
        let dot = a.x * b.x + a.y * b.y + a.z * b.z
        let na = (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot()
        let nb = (b.x * b.x + b.y * b.y + b.z * b.z).squareRoot()
        guard na > 1e-6, nb > 1e-6 else { return 0 }
        let cosine = max(-1, min(1, dot / (na * nb)))
        return acos(cosine) * 180 / Double.pi
    }
}

struct MotionAccumulator {
    var index: Int
    var coveredSeconds: Double = 0
    var coveredBins = 0
    var activeBins = 0
    var activity: Double = 0
    var movementCount = 0
    var largeMovementCount = 0
    var maxIntensity: Double = 0
    var pickup = false

    init(index: Int) {
        self.index = index
    }

    var summary: MotionEpochSummary {
        MotionEpochSummary(
            epochIndex: index,
            coveredSeconds: min(coveredSeconds, SleepConstants.epochLength),
            activity: activity,
            movementCount: movementCount,
            largeMovementCount: largeMovementCount,
            stillnessFraction: coveredBins > 0 ? 1 - Double(activeBins) / Double(coveredBins) : 1,
            maxIntensity: maxIntensity,
            pickup: pickup
        )
    }
}

/// Finds runs of regularly repeating movements in a night's movement events.
public enum MovementPatternDetector {
    public static func detect(
        events: [MovementEvent],
        minimumCount: Int = 4,
        intervalRange: ClosedRange<Double> = 15...90,
        maximumVariation: Double = 0.35
    ) -> [RepeatedMovementPattern] {
        let candidates = events.filter { $0.kind != .pickup }.sorted { $0.start < $1.start }
        guard candidates.count >= minimumCount else { return [] }
        var patterns: [RepeatedMovementPattern] = []
        var runStart = 0
        var intervals: [Double] = []

        func closeRun(endIndex: Int) {
            let count = endIndex - runStart + 1
            if count >= minimumCount, !intervals.isEmpty {
                let mean = Stats.mean(intervals)
                let variation = mean > 0 ? Stats.standardDeviation(intervals) / mean : 1
                if variation <= maximumVariation {
                    patterns.append(RepeatedMovementPattern(
                        start: candidates[runStart].start,
                        end: candidates[endIndex].end,
                        count: count,
                        meanInterval: mean
                    ))
                }
            }
        }

        for index in 1..<candidates.count {
            let gap = candidates[index].start.timeIntervalSince(candidates[index - 1].start)
            let fitsRange = intervalRange.contains(gap)
            let fitsRhythm: Bool
            if let last = intervals.last {
                fitsRhythm = abs(gap - last) <= max(8, last * 0.5)
            } else {
                fitsRhythm = true
            }
            if fitsRange && fitsRhythm {
                intervals.append(gap)
            } else {
                closeRun(endIndex: index - 1)
                runStart = fitsRange ? index - 1 : index
                intervals = fitsRange ? [gap] : []
            }
        }
        closeRun(endIndex: candidates.count - 1)
        return patterns
    }
}
