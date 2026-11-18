import Foundation
import SleepModels

/// Sound statistics for one 30-second epoch.
public struct AcousticEpochSummary: Codable, Sendable, Hashable {
    public var epochIndex: Int
    public var coveredSeconds: Double
    public var meanDecibels: Double
    public var maxDecibels: Double
    public var noiseFloorDecibels: Double
    public var snoreSeconds: Double
    public var talkSeconds: Double
    public var coughCount: Int
    public var disturbanceCount: Int
    public var movementSoundSeconds: Double
    /// dB·s/10 of sleeper-generated, arousal-like sounds (rustle, talk, cough, unclassified).
    public var soundActivity: Double
    public var eventCount: Int
    public var breathingRate: Double?
    public var breathingRegularity: Double
    public var masked: Bool

    public init(
        epochIndex: Int,
        coveredSeconds: Double = 0,
        meanDecibels: Double = Double(Decibels.floor),
        maxDecibels: Double = Double(Decibels.floor),
        noiseFloorDecibels: Double = Double(Decibels.floor),
        snoreSeconds: Double = 0,
        talkSeconds: Double = 0,
        coughCount: Int = 0,
        disturbanceCount: Int = 0,
        movementSoundSeconds: Double = 0,
        soundActivity: Double = 0,
        eventCount: Int = 0,
        breathingRate: Double? = nil,
        breathingRegularity: Double = 0,
        masked: Bool = false
    ) {
        self.epochIndex = epochIndex
        self.coveredSeconds = coveredSeconds
        self.meanDecibels = meanDecibels
        self.maxDecibels = maxDecibels
        self.noiseFloorDecibels = noiseFloorDecibels
        self.snoreSeconds = snoreSeconds
        self.talkSeconds = talkSeconds
        self.coughCount = coughCount
        self.disturbanceCount = disturbanceCount
        self.movementSoundSeconds = movementSoundSeconds
        self.soundActivity = soundActivity
        self.eventCount = eventCount
        self.breathingRate = breathingRate
        self.breathingRegularity = breathingRegularity
        self.masked = masked
    }
}

/// Live level for the night screen.
public struct LevelReading: Sendable, Hashable {
    public var time: Date
    public var decibels: Double
    public var noiseFloor: Double

    public init(time: Date, decibels: Double, noiseFloor: Double) {
        self.time = time
        self.decibels = decibels
        self.noiseFloor = noiseFloor
    }
}

public struct AudioAnalysisOutput: Sendable {
    public var epochs: [AcousticEpochSummary] = []
    public var events: [SoundEvent] = []
    /// Candidates belonging to `events` (same order), for clip saving and diagnostics.
    public var candidates: [EventCandidate] = []
    public var level: LevelReading?

    public init() {}

    public var isEmpty: Bool { epochs.isEmpty && events.isEmpty && level == nil }

    mutating func merge(_ other: AudioAnalysisOutput) {
        epochs.append(contentsOf: other.epochs)
        events.append(contentsOf: other.events)
        candidates.append(contentsOf: other.candidates)
        if let level = other.level { self.level = level }
    }
}

/// Optional second opinion from a trained model (Apple's on-device sound classifier in the app).
public protocol SoundEventRefining: AnyObject {
    /// Called synchronously on the analysis queue when an event closes.
    func modelDistribution(for candidate: EventCandidate) -> SoundTypeDistribution?
}

public struct AudioAnalysisConfiguration: Sendable {
    public var segmenter = EventSegmenter.Configuration()
    public var noiseFloor = NoiseFloorEstimator.Configuration()
    public var classifier = RuleBasedSoundClassifier.Configuration()
    /// Target frame length; the actual frame is the next power of two in samples.
    public var targetFrameDuration: Double = 0.064
    /// Overlap between consecutive frames (0.5 = 50 %).
    public var overlap: Double = 0.5
    public var levelReportInterval: TimeInterval = 1
    /// Gaps in the timestamps larger than this are treated as interruptions.
    public var gapTolerance: TimeInterval = 0.75

    public init() {}
}

/// The acoustic pipeline: framing → features → adaptive noise floor → event segmentation →
/// classification → per-epoch summaries. Not thread-safe; drive it from one serial queue.
public final class AudioAnalyzer {
    public let sampleRate: Double
    public let frameSize: Int
    public let hopSize: Int
    public let sessionStart: Date
    public let configuration: AudioAnalysisConfiguration
    public weak var refiner: (any SoundEventRefining)?
    /// Set while SleepFlow itself plays relaxation audio.
    public var isPlaybackMasked = false

    private let extractor: FrameFeatureExtractor
    private var floorEstimator: NoiseFloorEstimator
    private var segmenter: EventSegmenter
    private var classifier: RuleBasedSoundClassifier

    private var pending: [Float] = []
    private var pendingStartSample: Int64 = 0
    private var receivedSamples: Int64 = 0
    private var anchorTime: Date?
    private var anchorSample: Int64 = 0
    private var expectedNextTime: Date?

    private var accumulators: [Int: EpochAccumulator] = [:]
    private var currentFrameEpoch = -1
    private var lastLevelReport: Date?
    private var levelPowerSum: Double = 0
    private var levelFrames = 0
    private var currentFloor: Double = Double(Decibels.floor)

    public init(sampleRate: Double, sessionStart: Date, configuration: AudioAnalysisConfiguration = AudioAnalysisConfiguration(), useAccelerate: Bool = true) {
        precondition(sampleRate >= 8_000, "Sample rate too low for analysis")
        self.sampleRate = sampleRate
        self.sessionStart = sessionStart
        self.configuration = configuration
        var size = 256
        while Double(size) < sampleRate * configuration.targetFrameDuration { size *= 2 }
        self.frameSize = size
        self.hopSize = max(1, Int(Double(size) * (1 - configuration.overlap)))
        self.extractor = FrameFeatureExtractor(sampleRate: sampleRate, frameSize: size, useAccelerate: useAccelerate)
        self.floorEstimator = NoiseFloorEstimator(configuration: configuration.noiseFloor)
        self.segmenter = EventSegmenter(
            frameDuration: Double(size) / sampleRate,
            hopDuration: Double(max(1, Int(Double(size) * (1 - configuration.overlap)))) / sampleRate,
            configuration: configuration.segmenter
        )
        self.classifier = RuleBasedSoundClassifier(configuration: configuration.classifier)
    }

    public var frameDuration: Double { Double(frameSize) / sampleRate }
    public var hopDuration: Double { Double(hopSize) / sampleRate }
    /// Absolute index of the next sample that `process` will receive.
    public var nextSampleIndex: Int64 { receivedSamples }
    public var noiseFloor: Double? { floorEstimator.floor }
    public var usesAccelerate: Bool { extractor.usesAccelerate }

    /// Wall-clock time of an absolute sample index.
    public func time(ofSample sample: Int64) -> Date {
        let anchor = anchorTime ?? sessionStart
        return anchor.addingTimeInterval(Double(sample - anchorSample) / sampleRate)
    }

    /// Feeds mono samples. `time` is the wall-clock time of the first sample.
    public func process(_ samples: [Float], startingAt time: Date) -> AudioAnalysisOutput {
        var output = AudioAnalysisOutput()
        guard !samples.isEmpty else { return output }

        if let expected = expectedNextTime, abs(time.timeIntervalSince(expected)) > configuration.gapTolerance {
            // Interruption: close what is open and restart framing at the new position.
            output.merge(closeOpenEvent())
            pending.removeAll()
            extractor.reset()
            anchorTime = time
            anchorSample = receivedSamples
            pendingStartSample = receivedSamples
        } else if anchorTime == nil {
            anchorTime = time
            anchorSample = receivedSamples
            pendingStartSample = receivedSamples
        }

        if pending.isEmpty {
            pendingStartSample = receivedSamples
        }
        pending.append(contentsOf: samples)
        receivedSamples += Int64(samples.count)
        expectedNextTime = time.addingTimeInterval(Double(samples.count) / sampleRate)

        while pending.count >= frameSize {
            let frame = Array(pending[0..<frameSize])
            output.merge(processFrame(frame, startSample: pendingStartSample))
            pending.removeFirst(hopSize)
            pendingStartSample += Int64(hopSize)
        }
        output.epochs.append(contentsOf: finalizeEpochs(force: false))
        return output
    }

    /// Ends the analysis: closes open events and emits all remaining epochs.
    public func finish() -> AudioAnalysisOutput {
        var output = closeOpenEvent()
        currentFrameEpoch += 1
        output.epochs.append(contentsOf: finalizeEpochs(force: true))
        return output
    }

    // MARK: - Frame processing

    private func processFrame(_ frame: [Float], startSample: Int64) -> AudioAnalysisOutput {
        var output = AudioAnalysisOutput()
        let frameTime = time(ofSample: startSample)
        let features = extractor.features(of: frame)
        let level = Double(features.decibels)
        let floor = floorEstimator.update(frameDecibels: level, frozen: segmenter.isEventOpen)
        currentFloor = floor

        let epochIndex = Int((frameTime.timeIntervalSince(sessionStart) / SleepConstants.epochLength).rounded(.down))
        if epochIndex > currentFrameEpoch { currentFrameEpoch = epochIndex }

        let extractor = self.extractor
        let candidate = segmenter.process(
            frame: features,
            time: frameTime,
            startSample: startSample,
            endSample: startSample + Int64(frameSize),
            floor: floor,
            mfcc: { extractor.mfccOfLastFrame() }
        )

        if epochIndex >= 0 {
            var accumulator = accumulators[epochIndex] ?? EpochAccumulator(index: epochIndex)
            accumulator.coveredSeconds += hopDuration
            let power = Double(features.rms) * Double(features.rms)
            accumulator.powerSum += power
            accumulator.frames += 1
            accumulator.maxDecibels = max(accumulator.maxDecibels, level)
            accumulator.floor = floor
            let quiet = !segmenter.isEventOpen && level - floor < configuration.segmenter.onsetMargin
            accumulator.quietLevels.append(quiet ? level : nil)
            if isPlaybackMasked { accumulator.masked = true }
            accumulators[epochIndex] = accumulator
        }

        if let candidate {
            output.merge(classifyAndRecord(candidate))
        }

        levelPowerSum += Double(features.rms) * Double(features.rms)
        levelFrames += 1
        if lastLevelReport == nil || frameTime.timeIntervalSince(lastLevelReport ?? frameTime) >= configuration.levelReportInterval {
            let meanPower = levelPowerSum / Double(max(levelFrames, 1))
            let decibels = meanPower > 1e-12 ? 10 * log10(meanPower) : Double(Decibels.floor)
            output.level = LevelReading(time: frameTime, decibels: decibels, noiseFloor: floor)
            lastLevelReport = frameTime
            levelPowerSum = 0
            levelFrames = 0
        }
        return output
    }

    private func closeOpenEvent() -> AudioAnalysisOutput {
        guard let candidate = segmenter.forceClose() else { return AudioAnalysisOutput() }
        return classifyAndRecord(candidate)
    }

    private func classifyAndRecord(_ candidate: EventCandidate) -> AudioAnalysisOutput {
        var output = AudioAnalysisOutput()
        let rule = classifier.classify(candidate)
        let model = refiner?.modelDistribution(for: candidate)
        let fused = ClassifierFusion.fuse(rule: rule, model: model)
        let decision = RuleBasedSoundClassifier.decide(fused, minimumConfidence: configuration.classifier.minimumConfidence)
        let summary = candidate.summary
        let event = SoundEvent(
            start: candidate.start,
            duration: summary.duration,
            type: decision.type,
            confidence: decision.confidence,
            peakDecibels: summary.peakDecibels,
            levelAboveFloor: summary.peakAboveFloor,
            verifiedByModel: model != nil
        )
        output.events.append(event)
        output.candidates.append(candidate)

        let index = Int((candidate.start.timeIntervalSince(sessionStart) / SleepConstants.epochLength).rounded(.down))
        guard index >= 0 else { return output }
        var accumulator = accumulators[index] ?? EpochAccumulator(index: index)
        let energy = max(0, summary.meanAboveFloor) * summary.duration / 10
        accumulator.eventCount += 1
        switch event.type {
        case .snoring:
            accumulator.snoreSeconds += summary.duration
        case .talking:
            accumulator.talkSeconds += summary.duration
            accumulator.soundActivity += 0.5 * energy
        case .coughing:
            accumulator.coughCount += 1
            accumulator.soundActivity += 0.5 * energy
        case .movement:
            accumulator.movementSoundSeconds += summary.duration
            accumulator.soundActivity += energy
        case .disturbance:
            accumulator.disturbanceCount += 1
        case .breathing:
            break
        case .unknown:
            accumulator.soundActivity += 0.5 * energy
        }
        accumulators[index] = accumulator
        return output
    }

    private func finalizeEpochs(force: Bool) -> [AcousticEpochSummary] {
        let openStart = segmenter.openEventStart
        let openEpoch = openStart.map { Int(($0.timeIntervalSince(sessionStart) / SleepConstants.epochLength).rounded(.down)) }
        var ready: [AcousticEpochSummary] = []
        for index in accumulators.keys.sorted() {
            guard force || index < currentFrameEpoch else { break }
            if !force, let openEpoch, openEpoch <= index { break }
            guard let accumulator = accumulators.removeValue(forKey: index) else { continue }
            ready.append(accumulator.summary(hopDuration: hopDuration))
        }
        return ready
    }
}

/// Running per-epoch statistics inside the analyzer.
struct EpochAccumulator {
    var index: Int
    var coveredSeconds: Double = 0
    var powerSum: Double = 0
    var frames = 0
    var maxDecibels: Double = Double(Decibels.floor)
    var floor: Double = Double(Decibels.floor)
    var snoreSeconds: Double = 0
    var talkSeconds: Double = 0
    var coughCount = 0
    var disturbanceCount = 0
    var movementSoundSeconds: Double = 0
    var soundActivity: Double = 0
    var eventCount = 0
    var quietLevels: [Double?] = []
    var masked = false

    init(index: Int) {
        self.index = index
    }

    func summary(hopDuration: Double) -> AcousticEpochSummary {
        let meanPower = frames > 0 ? powerSum / Double(frames) : 0
        let meanDecibels = meanPower > 1e-12 ? 10 * log10(meanPower) : Double(Decibels.floor)
        let breathing = BreathingAnalyzer.analyse(levels: quietLevels, hopDuration: hopDuration)
        return AcousticEpochSummary(
            epochIndex: index,
            coveredSeconds: min(coveredSeconds, SleepConstants.epochLength),
            meanDecibels: meanDecibels,
            maxDecibels: maxDecibels,
            noiseFloorDecibels: floor,
            snoreSeconds: snoreSeconds,
            talkSeconds: talkSeconds,
            coughCount: coughCount,
            disturbanceCount: disturbanceCount,
            movementSoundSeconds: movementSoundSeconds,
            soundActivity: soundActivity,
            eventCount: eventCount,
            breathingRate: breathing?.breathsPerMinute,
            breathingRegularity: breathing?.regularity ?? 0,
            masked: masked
        )
    }
}
