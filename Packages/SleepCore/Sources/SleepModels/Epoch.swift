import Foundation

/// Everything the engine knows about one 30-second epoch of the night.
///
/// Epochs are produced by combining the acoustic and the motion pipeline and are the
/// input for sleep-state estimation. They are also what is persisted while tracking,
/// so a session can be recovered after the app is terminated.
public struct EpochFeatures: Codable, Sendable, Hashable {
    public var index: Int
    public var start: Date
    /// Fraction of the epoch covered by microphone data (0...1).
    public var audioCoverage: Double
    /// Fraction of the epoch covered by accelerometer data (0...1).
    public var motionCoverage: Double
    /// Accelerometer activity in activity units (sum of per-second excess over the adaptive threshold).
    public var movementActivity: Double
    /// Number of accelerometer movement events that started in this epoch.
    public var movementEventCount: Int
    /// Number of large or sudden accelerometer movements.
    public var largeMovementCount: Int
    /// Sound-based activity: dB·seconds of movement-like sounds above the noise floor.
    public var soundActivity: Double
    public var meanDecibels: Double?
    public var noiseFloorDecibels: Double?
    public var maxDecibels: Double?
    public var snoreSeconds: Double
    public var talkSeconds: Double
    public var coughCount: Int
    public var disturbanceCount: Int
    /// Breaths per minute when a regular breathing rhythm was detectable.
    public var breathingRate: Double?
    /// 0...1 autocorrelation strength of the breathing rhythm.
    public var breathingRegularity: Double
    /// The phone was picked up or turned over during this epoch.
    public var pickup: Bool
    /// SleepFlow was playing a relaxation sound, so sound events are less reliable.
    public var playbackMasked: Bool

    public init(
        index: Int,
        start: Date,
        audioCoverage: Double = 0,
        motionCoverage: Double = 0,
        movementActivity: Double = 0,
        movementEventCount: Int = 0,
        largeMovementCount: Int = 0,
        soundActivity: Double = 0,
        meanDecibels: Double? = nil,
        noiseFloorDecibels: Double? = nil,
        maxDecibels: Double? = nil,
        snoreSeconds: Double = 0,
        talkSeconds: Double = 0,
        coughCount: Int = 0,
        disturbanceCount: Int = 0,
        breathingRate: Double? = nil,
        breathingRegularity: Double = 0,
        pickup: Bool = false,
        playbackMasked: Bool = false
    ) {
        self.index = index
        self.start = start
        self.audioCoverage = audioCoverage
        self.motionCoverage = motionCoverage
        self.movementActivity = movementActivity
        self.movementEventCount = movementEventCount
        self.largeMovementCount = largeMovementCount
        self.soundActivity = soundActivity
        self.meanDecibels = meanDecibels
        self.noiseFloorDecibels = noiseFloorDecibels
        self.maxDecibels = maxDecibels
        self.snoreSeconds = snoreSeconds
        self.talkSeconds = talkSeconds
        self.coughCount = coughCount
        self.disturbanceCount = disturbanceCount
        self.breathingRate = breathingRate
        self.breathingRegularity = breathingRegularity
        self.pickup = pickup
        self.playbackMasked = playbackMasked
    }

    /// An epoch for which no sensor delivered data (app suspended, interruption).
    public static func empty(index: Int, sessionStart: Date) -> EpochFeatures {
        EpochFeatures(index: index, start: sessionStart.addingTimeInterval(Double(index) * SleepConstants.epochLength))
    }

    public var end: Date { start.addingTimeInterval(SleepConstants.epochLength) }

    /// Coverage of the sensor that is primary for the given method.
    public func coverage(for method: TrackingMethod) -> Double {
        switch method {
        case .microphone: return audioCoverage
        case .motion: return motionCoverage
        }
    }

    public func hasData(for method: TrackingMethod) -> Bool {
        coverage(for: method) >= 0.5
    }
}

public extension Array where Element == EpochFeatures {
    /// Returns a gap-free, index-ordered epoch list from `0` to the last index (or `count`),
    /// inserting empty epochs where no data was recorded.
    func filledGaps(sessionStart: Date, count requiredCount: Int? = nil) -> [EpochFeatures] {
        var byIndex: [Int: EpochFeatures] = [:]
        for epoch in self where epoch.index >= 0 {
            byIndex[epoch.index] = epoch
        }
        let lastIndex = (byIndex.keys.max() ?? -1)
        let total = Swift.max(requiredCount ?? 0, lastIndex + 1)
        guard total > 0 else { return [] }
        return (0..<total).map { index in
            byIndex[index] ?? EpochFeatures.empty(index: index, sessionStart: sessionStart)
        }
    }
}
