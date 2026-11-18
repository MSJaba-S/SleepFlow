import Foundation
import SleepModels

/// Aggregated features of one detected sound event, the input for classification.
public struct EventFeatureSummary: Sendable, Hashable {
    public var duration: Double
    public var peakDecibels: Double
    public var peakAboveFloor: Double
    public var meanAboveFloor: Double
    /// Largest frame-to-frame level increase at the onset, in dB.
    public var attack: Double
    public var centroid: Double
    public var rolloff: Double
    public var flatness: Double
    public var zeroCrossingRate: Double
    public var bandLow: Double
    public var bandLowMid: Double
    public var bandMid: Double
    public var bandHigh: Double
    public var fluxMean: Double
    public var fluxDeviation: Double
    /// Dominant amplitude-modulation rate of the level envelope in Hz (syllable rate for speech).
    public var modulationRate: Double
    /// Peak-to-trough depth of the level envelope in dB.
    public var modulationDepth: Double
    /// Mean MFCC vector (13 coefficients). Stored for future model-based classification.
    public var mfcc: [Double]

    public init(
        duration: Double, peakDecibels: Double, peakAboveFloor: Double, meanAboveFloor: Double, attack: Double,
        centroid: Double, rolloff: Double, flatness: Double, zeroCrossingRate: Double,
        bandLow: Double, bandLowMid: Double, bandMid: Double, bandHigh: Double,
        fluxMean: Double, fluxDeviation: Double, modulationRate: Double, modulationDepth: Double, mfcc: [Double]
    ) {
        self.duration = duration
        self.peakDecibels = peakDecibels
        self.peakAboveFloor = peakAboveFloor
        self.meanAboveFloor = meanAboveFloor
        self.attack = attack
        self.centroid = centroid
        self.rolloff = rolloff
        self.flatness = flatness
        self.zeroCrossingRate = zeroCrossingRate
        self.bandLow = bandLow
        self.bandLowMid = bandLowMid
        self.bandMid = bandMid
        self.bandHigh = bandHigh
        self.fluxMean = fluxMean
        self.fluxDeviation = fluxDeviation
        self.modulationRate = modulationRate
        self.modulationDepth = modulationDepth
        self.mfcc = mfcc
    }
}

/// A sound event whose boundaries are known but which is not yet classified.
public struct EventCandidate: Sendable {
    public var start: Date
    public var summary: EventFeatureSummary
    /// Sample positions in the analyzer's continuous sample counter (start inclusive, end exclusive).
    public var startSample: Int64
    public var endSample: Int64

    public init(start: Date, summary: EventFeatureSummary, startSample: Int64, endSample: Int64) {
        self.start = start
        self.summary = summary
        self.startSample = startSample
        self.endSample = endSample
    }
}

/// Detects the start and end of sound events relative to the adaptive noise floor.
///
/// Uses hysteresis (separate onset and release thresholds), a minimum number of frames
/// above the onset threshold, a short hangover and a maximum duration after which long
/// sounds are split. Frame features are accumulated while an event is open.
public struct EventSegmenter: Sendable {
    public struct Configuration: Sendable {
        public var onsetMargin: Double = 6
        public var releaseMargin: Double = 3.5
        public var minimumOnsetFrames: Int = 2
        public var hangoverFrames: Int = 3
        public var maximumDuration: Double = 15
        public init() {}
    }

    struct OpenEvent: Sendable {
        var start: Date
        var startSample: Int64
        var frames: [FrameFeatures] = []
        var floorAtStart: Double
        var preOnsetLevel: Double
        var mfccSum: [Double] = Array(repeating: 0, count: 13)
        var mfccCount = 0
        var lastActiveSampleEnd: Int64
        var belowCount = 0
    }

    public let configuration: Configuration
    public let frameDuration: Double
    public let hopDuration: Double
    private var pendingOnset: [(time: Date, sample: Int64, features: FrameFeatures)] = []
    private var open: OpenEvent?
    private var lastQuietLevel: Double = -120

    public init(frameDuration: Double, hopDuration: Double, configuration: Configuration = Configuration()) {
        self.frameDuration = frameDuration
        self.hopDuration = hopDuration
        self.configuration = configuration
    }

    public var isEventOpen: Bool { open != nil }
    public var openEventStart: Date? { open?.start ?? pendingOnset.first?.time }

    /// Feeds one frame. Returns a finished candidate when an event closes.
    /// - Parameter mfcc: closure computing MFCCs of the current frame; only called while an event is open.
    public mutating func process(
        frame: FrameFeatures,
        time: Date,
        startSample: Int64,
        endSample: Int64,
        floor: Double,
        mfcc: () -> [Float]
    ) -> EventCandidate? {
        let level = Double(frame.decibels)
        let above = level - floor

        if var current = open {
            if above >= configuration.releaseMargin {
                current.frames.append(frame)
                current.belowCount = 0
                current.lastActiveSampleEnd = endSample
                addMFCC(mfcc(), to: &current)
            } else {
                current.belowCount += 1
                if current.belowCount <= configuration.hangoverFrames {
                    current.frames.append(frame)
                }
            }
            let elapsed = time.timeIntervalSince(current.start) + frameDuration
            if current.belowCount > configuration.hangoverFrames || elapsed >= configuration.maximumDuration {
                open = nil
                return finish(current)
            }
            open = current
            return nil
        }

        if above >= configuration.onsetMargin {
            pendingOnset.append((time: time, sample: startSample, features: frame))
            if pendingOnset.count >= configuration.minimumOnsetFrames, let first = pendingOnset.first {
                var event = OpenEvent(
                    start: first.time,
                    startSample: first.sample,
                    floorAtStart: floor,
                    preOnsetLevel: lastQuietLevel,
                    lastActiveSampleEnd: endSample
                )
                for pending in pendingOnset {
                    event.frames.append(pending.features)
                }
                addMFCC(mfcc(), to: &event)
                open = event
                pendingOnset.removeAll()
            }
        } else {
            pendingOnset.removeAll()
            lastQuietLevel = level
        }
        return nil
    }

    /// Closes an open event, for example at the end of a session or after a data gap.
    public mutating func forceClose() -> EventCandidate? {
        pendingOnset.removeAll()
        guard let current = open else { return nil }
        open = nil
        return finish(current)
    }

    private func addMFCC(_ values: [Float], to event: inout OpenEvent) {
        guard values.count == event.mfccSum.count else { return }
        for index in 0..<values.count {
            event.mfccSum[index] += Double(values[index])
        }
        event.mfccCount += 1
    }

    private func finish(_ event: OpenEvent) -> EventCandidate? {
        // Drop trailing hangover frames that were below the release threshold.
        var frames = event.frames
        var trailing = min(event.belowCount, configuration.hangoverFrames)
        while trailing > 0 && frames.count > 1 {
            frames.removeLast()
            trailing -= 1
        }
        guard !frames.isEmpty else { return nil }
        let summary = EventSegmenter.summarise(
            frames: frames,
            floor: event.floorAtStart,
            preOnsetLevel: event.preOnsetLevel,
            hopDuration: hopDuration,
            frameDuration: frameDuration,
            mfccSum: event.mfccSum,
            mfccCount: event.mfccCount
        )
        return EventCandidate(start: event.start, summary: summary, startSample: event.startSample, endSample: event.lastActiveSampleEnd)
    }

    static func summarise(
        frames: [FrameFeatures],
        floor: Double,
        preOnsetLevel: Double,
        hopDuration: Double,
        frameDuration: Double,
        mfccSum: [Double],
        mfccCount: Int
    ) -> EventFeatureSummary {
        let levels = frames.map { Double($0.decibels) }
        let peak = levels.max() ?? floor
        let meanAbove = Stats.mean(levels.map { $0 - floor })

        var attack = 0.0
        var previous = preOnsetLevel
        for level in levels.prefix(3) {
            attack = Swift.max(attack, level - previous)
            previous = level
        }
        attack = Swift.max(attack, (levels.first ?? floor) - floor)

        // Energy weighting so loud frames dominate the spectral description.
        let weights = frames.map { Double($0.rms * $0.rms) + 1e-12 }
        let weightSum = weights.reduce(0, +)
        func weighted(_ value: (FrameFeatures) -> Float) -> Double {
            var sum = 0.0
            for (index, frame) in frames.enumerated() {
                sum += Double(value(frame)) * weights[index]
            }
            return sum / weightSum
        }

        let fluxes = frames.map { Double($0.spectralFlux) }
        let (modulationRate, modulationDepth) = EventSegmenter.modulation(levels: levels, hopDuration: hopDuration)
        let mfcc = mfccCount > 0 ? mfccSum.map { $0 / Double(mfccCount) } : mfccSum

        let duration = Double(max(frames.count - 1, 0)) * hopDuration + frameDuration
        return EventFeatureSummary(
            duration: duration,
            peakDecibels: peak,
            peakAboveFloor: peak - floor,
            meanAboveFloor: meanAbove,
            attack: attack,
            centroid: weighted { $0.spectralCentroid },
            rolloff: weighted { $0.spectralRolloff },
            flatness: weighted { $0.spectralFlatness },
            zeroCrossingRate: weighted { $0.zeroCrossingRate },
            bandLow: weighted { $0.bandLow },
            bandLowMid: weighted { $0.bandLowMid },
            bandMid: weighted { $0.bandMid },
            bandHigh: weighted { $0.bandHigh },
            fluxMean: Stats.mean(fluxes),
            fluxDeviation: Stats.standardDeviation(fluxes),
            modulationRate: modulationRate,
            modulationDepth: modulationDepth,
            mfcc: mfcc
        )
    }

    /// Estimates the dominant modulation of the level envelope by counting prominent peaks.
    static func modulation(levels: [Double], hopDuration: Double) -> (rate: Double, depth: Double) {
        guard levels.count >= 5 else { return (0, 0) }
        // Light smoothing (3-point) to suppress frame noise.
        var smoothed = levels
        for index in 1..<(levels.count - 1) {
            smoothed[index] = (levels[index - 1] + levels[index] + levels[index + 1]) / 3
        }
        let depth = (smoothed.max() ?? 0) - (smoothed.min() ?? 0)
        var peaks = 0
        var lastPeak = -10
        let prominence = 2.0
        for index in 1..<(smoothed.count - 1) {
            let isPeak = smoothed[index] > smoothed[index - 1] && smoothed[index] >= smoothed[index + 1]
            guard isPeak, index - lastPeak >= 2 else { continue }
            let windowStart = Swift.max(0, index - 4)
            let windowEnd = Swift.min(smoothed.count - 1, index + 4)
            let localMin = smoothed[windowStart...windowEnd].min() ?? smoothed[index]
            if smoothed[index] - localMin >= prominence {
                peaks += 1
                lastPeak = index
            }
        }
        let duration = Double(levels.count) * hopDuration
        guard duration > 0 else { return (0, depth) }
        return (Double(peaks) / duration, depth)
    }
}
