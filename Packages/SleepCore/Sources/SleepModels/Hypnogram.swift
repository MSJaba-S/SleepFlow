import Foundation

/// The estimated sleep state for every epoch of a night.
public struct Hypnogram: Codable, Sendable, Hashable {
    public var start: Date
    public var epochLength: TimeInterval
    public var stages: [SleepStage]
    /// Posterior probability of the chosen state (0...1) per epoch.
    public var confidence: [Double]
    /// Whether sensor data existed for the epoch. Epochs without data are inferred from neighbours.
    public var hasData: [Bool]

    public init(start: Date, epochLength: TimeInterval = SleepConstants.epochLength, stages: [SleepStage], confidence: [Double], hasData: [Bool]) {
        precondition(stages.count == confidence.count && stages.count == hasData.count, "Hypnogram arrays must have equal length")
        self.start = start
        self.epochLength = epochLength
        self.stages = stages
        self.confidence = confidence
        self.hasData = hasData
    }

    public var count: Int { stages.count }
    public var end: Date { start.addingTimeInterval(Double(stages.count) * epochLength) }

    public func epochStart(_ index: Int) -> Date { start.addingTimeInterval(Double(index) * epochLength) }

    public func duration(of stage: SleepStage) -> TimeInterval {
        Double(stages.filter { $0 == stage }.count) * epochLength
    }

    public func stage(at date: Date) -> SleepStage? {
        let offset = date.timeIntervalSince(start)
        guard offset >= 0 else { return nil }
        let index = Int(offset / epochLength)
        return index < stages.count ? stages[index] : nil
    }

    /// Consecutive runs of the same state, suitable for drawing a timeline.
    public var segments: [StageSegment] {
        guard !stages.isEmpty else { return [] }
        var result: [StageSegment] = []
        var runStart = 0
        for index in 1...stages.count {
            if index == stages.count || stages[index] != stages[runStart] || hasData[index] != hasData[runStart] {
                let slice = confidence[runStart..<index]
                let meanConfidence = slice.reduce(0, +) / Double(slice.count)
                result.append(StageSegment(
                    stage: stages[runStart],
                    start: epochStart(runStart),
                    end: epochStart(index),
                    meanConfidence: meanConfidence,
                    hasData: hasData[runStart]
                ))
                runStart = index
            }
        }
        return result
    }
}

public struct StageSegment: Codable, Sendable, Hashable, Identifiable {
    public var stage: SleepStage
    public var start: Date
    public var end: Date
    public var meanConfidence: Double
    public var hasData: Bool

    public init(stage: SleepStage, start: Date, end: Date, meanConfidence: Double, hasData: Bool) {
        self.stage = stage
        self.start = start
        self.end = end
        self.meanConfidence = meanConfidence
        self.hasData = hasData
    }

    public var id: Date { start }
    public var duration: TimeInterval { end.timeIntervalSince(start) }
}

/// Summary statistics for one night, derived from the hypnogram and events.
public struct SleepMetrics: Codable, Sendable, Hashable {
    public var sessionStart: Date
    public var sessionEnd: Date
    public var sleepOnset: Date?
    public var finalAwakening: Date?
    public var timeInBed: TimeInterval
    public var totalSleep: TimeInterval
    public var sleepLatency: TimeInterval?
    /// Awake time between sleep onset and the final awakening.
    public var wakeAfterSleepOnset: TimeInterval
    /// All awake time in bed, including before falling asleep and after the final awakening.
    public var awakeTime: TimeInterval
    /// Total sleep divided by time in bed (0...1).
    public var efficiency: Double
    /// Awakenings of at least two minutes after sleep onset.
    public var interruptions: Int
    public var lightSleep: TimeInterval
    public var deepSleep: TimeInterval
    /// Fraction of sleep epochs with notable movement (0...1).
    public var restlessness: Double
    public var movementEventsPerHour: Double
    /// Fraction of the night with usable sensor data (0...1).
    public var dataCoverage: Double
    public var snoringDuration: TimeInterval
    /// Number of sound events per `SoundEventType.rawValue`.
    public var soundEventCounts: [String: Int]

    public init(
        sessionStart: Date,
        sessionEnd: Date,
        sleepOnset: Date?,
        finalAwakening: Date?,
        timeInBed: TimeInterval,
        totalSleep: TimeInterval,
        sleepLatency: TimeInterval?,
        wakeAfterSleepOnset: TimeInterval,
        awakeTime: TimeInterval,
        efficiency: Double,
        interruptions: Int,
        lightSleep: TimeInterval,
        deepSleep: TimeInterval,
        restlessness: Double,
        movementEventsPerHour: Double,
        dataCoverage: Double,
        snoringDuration: TimeInterval,
        soundEventCounts: [String: Int]
    ) {
        self.sessionStart = sessionStart
        self.sessionEnd = sessionEnd
        self.sleepOnset = sleepOnset
        self.finalAwakening = finalAwakening
        self.timeInBed = timeInBed
        self.totalSleep = totalSleep
        self.sleepLatency = sleepLatency
        self.wakeAfterSleepOnset = wakeAfterSleepOnset
        self.awakeTime = awakeTime
        self.efficiency = efficiency
        self.interruptions = interruptions
        self.lightSleep = lightSleep
        self.deepSleep = deepSleep
        self.restlessness = restlessness
        self.movementEventsPerHour = movementEventsPerHour
        self.dataCoverage = dataCoverage
        self.snoringDuration = snoringDuration
        self.soundEventCounts = soundEventCounts
    }

    public func count(of type: SoundEventType) -> Int { soundEventCounts[type.rawValue] ?? 0 }

    /// The night had essentially no sleep detected.
    public var noSleepDetected: Bool { sleepOnset == nil || totalSleep < 15 * 60 }
}
