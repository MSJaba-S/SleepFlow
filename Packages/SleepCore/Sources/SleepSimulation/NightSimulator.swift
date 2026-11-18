import Foundation
import SleepModels

/// Parameters of a simulated night.
public struct NightScenario: Sendable, Hashable {
    public var method: TrackingMethod
    public var bedtime: Date
    public var timeInBed: TimeInterval
    public var sleepLatency: TimeInterval
    public var awakenings: Int
    /// 0...1, how much of the sleep is accompanied by snoring.
    public var snoringPropensity: Double
    /// 0...1, how often the sleeper moves during light sleep.
    public var restlessness: Double
    public var talkingPropensity: Double
    /// 0...1, chance of environmental noise per epoch.
    public var noise: Double
    /// Offsets from bedtime during which no sensor data exists.
    public var gaps: [ClosedRange<TimeInterval>]

    public init(
        method: TrackingMethod = .microphone,
        bedtime: Date,
        timeInBed: TimeInterval = 8 * 3600,
        sleepLatency: TimeInterval = 15 * 60,
        awakenings: Int = 2,
        snoringPropensity: Double = 0.2,
        restlessness: Double = 0.3,
        talkingPropensity: Double = 0.03,
        noise: Double = 0.02,
        gaps: [ClosedRange<TimeInterval>] = []
    ) {
        self.method = method
        self.bedtime = bedtime
        self.timeInBed = timeInBed
        self.sleepLatency = sleepLatency
        self.awakenings = awakenings
        self.snoringPropensity = snoringPropensity
        self.restlessness = restlessness
        self.talkingPropensity = talkingPropensity
        self.noise = noise
        self.gaps = gaps
    }
}

/// A night produced by the simulator, with the ground-truth states used to generate it.
public struct SimulatedNight: Sendable {
    public var scenario: NightScenario
    public var groundTruth: [SleepStage]
    public var epochs: [EpochFeatures]
    public var soundEvents: [SoundEvent]
    public var movementEvents: [MovementEvent]

    public var start: Date { scenario.bedtime }
    public var end: Date { scenario.bedtime.addingTimeInterval(Double(groundTruth.count) * SleepConstants.epochLength) }
}

/// Generates realistic epoch-level sensor data for a night.
///
/// A ground-truth hypnogram is built from ~90-minute sleep cycles (deep sleep concentrated in the
/// first cycles, longer light/REM-like periods towards morning, brief awakenings), and sensor
/// observations are drawn from state-dependent distributions. The output has exactly the shape the
/// real pipeline produces, so it drives tests, the demo mode and UI tests without touching real data.
public enum NightSimulator {
    public static func simulate(_ scenario: NightScenario, seed: UInt64) -> SimulatedNight {
        var rng = SplitMix64(seed: seed)
        let truth = groundTruth(scenario, rng: &rng)
        var epochs: [EpochFeatures] = []
        var sounds: [SoundEvent] = []
        var movements: [MovementEvent] = []
        epochs.reserveCapacity(truth.count)

        for (index, stage) in truth.enumerated() {
            let start = scenario.bedtime.addingTimeInterval(Double(index) * SleepConstants.epochLength)
            let offset = Double(index) * SleepConstants.epochLength
            let inGap = scenario.gaps.contains { $0.contains(offset) }
            if inGap {
                epochs.append(EpochFeatures(index: index, start: start))
                continue
            }
            var epoch = EpochFeatures(index: index, start: start)
            let activity = activityLevel(stage: stage, restlessness: scenario.restlessness, rng: &rng)

            switch scenario.method {
            case .motion:
                epoch.motionCoverage = 1
                epoch.movementActivity = activity
                if activity > 1 {
                    epoch.movementEventCount = activity > 5 ? 2 : 1
                    let duration = Swift.min(25, 2 + activity * 1.5)
                    movements.append(MovementEvent(
                        start: start.addingTimeInterval(rng.uniform(0...max(0, 29 - duration))),
                        duration: duration,
                        intensity: 0.008 + activity * 0.006,
                        kind: activity > 4 ? .large : .small
                    ))
                }
                if activity > 4 { epoch.largeMovementCount = 1 }
                if stage == .awake && rng.chance(0.04) {
                    epoch.pickup = true
                    movements.append(MovementEvent(start: start.addingTimeInterval(10), duration: 4, intensity: 0.4, kind: .pickup))
                }
            case .microphone:
                epoch.audioCoverage = 1
                epoch.motionCoverage = 1
                epoch.soundActivity = activity * 0.9
                epoch.noiseFloorDecibels = -68 + rng.gaussian(sd: 1)
                epoch.meanDecibels = (epoch.noiseFloorDecibels ?? -68) + 2 + activity * 0.8
                epoch.maxDecibels = (epoch.noiseFloorDecibels ?? -68) + 6 + activity * 3
                if activity > 1 {
                    let duration = Swift.min(6, 1 + activity * 0.5)
                    sounds.append(SoundEvent(
                        start: start.addingTimeInterval(rng.uniform(0...20)),
                        duration: duration,
                        type: .movement,
                        confidence: rng.uniform(0.55...0.9),
                        peakDecibels: -60 + activity,
                        levelAboveFloor: 8 + activity
                    ))
                }
                if stage != .awake && rng.chance(scenario.snoringPropensity) {
                    let snoreCount = 3 + Int(rng.unit() * 4)
                    epoch.snoreSeconds = Double(snoreCount) * 1.4
                    for snore in 0..<snoreCount {
                        sounds.append(SoundEvent(
                            start: start.addingTimeInterval(Double(snore) * 4.2 + rng.uniform(0...0.6)),
                            duration: 1.4,
                            type: .snoring,
                            confidence: rng.uniform(0.6...0.95),
                            peakDecibels: -48 + rng.gaussian(sd: 2),
                            levelAboveFloor: 18 + rng.gaussian(sd: 2),
                            verifiedByModel: rng.chance(0.5)
                        ))
                    }
                }
                let talkChance = stage == .awake ? scenario.talkingPropensity * 3 : scenario.talkingPropensity * 0.3
                if rng.chance(talkChance) {
                    epoch.talkSeconds = rng.uniform(2...6)
                    sounds.append(SoundEvent(start: start.addingTimeInterval(5), duration: epoch.talkSeconds, type: .talking, confidence: rng.uniform(0.5...0.9), peakDecibels: -45, levelAboveFloor: 20))
                }
                if stage == .awake && rng.chance(0.03) {
                    epoch.coughCount = 1
                    sounds.append(SoundEvent(start: start.addingTimeInterval(12), duration: 0.4, type: .coughing, confidence: rng.uniform(0.55...0.9), peakDecibels: -38, levelAboveFloor: 28))
                }
                if rng.chance(scenario.noise) {
                    epoch.disturbanceCount = 1
                    sounds.append(SoundEvent(start: start.addingTimeInterval(18), duration: rng.uniform(1...6), type: .disturbance, confidence: rng.uniform(0.4...0.8), peakDecibels: -35, levelAboveFloor: 30))
                }
                switch stage {
                case .deep:
                    epoch.breathingRegularity = epoch.snoreSeconds > 0 ? rng.uniform(0.2...0.4) : rng.uniform(0.5...0.85)
                case .light:
                    epoch.breathingRegularity = rng.uniform(0.1...0.4)
                case .awake:
                    epoch.breathingRegularity = rng.uniform(0...0.2)
                }
                if epoch.breathingRegularity >= 0.25 {
                    epoch.breathingRate = rng.uniform(12...16)
                }
                if stage == .awake && rng.chance(0.03) {
                    epoch.pickup = true
                }
            }
            epochs.append(epoch)
        }
        return SimulatedNight(scenario: scenario, groundTruth: truth, epochs: epochs, soundEvents: sounds, movementEvents: movements)
    }

    static func activityLevel(stage: SleepStage, restlessness: Double, rng: inout SplitMix64) -> Double {
        switch stage {
        case .awake:
            return rng.chance(0.85) ? 2 + rng.exponential(mean: 6) : rng.exponential(mean: 0.6)
        case .light:
            let burst = 0.10 + 0.25 * Stats.clamp(restlessness, 0, 1)
            return rng.chance(burst) ? 1 + rng.exponential(mean: 3) : rng.exponential(mean: 0.15)
        case .deep:
            return rng.chance(0.015) ? rng.exponential(mean: 1.0) : rng.exponential(mean: 0.03)
        }
    }

    /// Builds the true state sequence from sleep cycles.
    public static func groundTruth(_ scenario: NightScenario, rng: inout SplitMix64) -> [SleepStage] {
        let total = max(1, Int(scenario.timeInBed / SleepConstants.epochLength))
        var stages = [SleepStage](repeating: .light, count: total)
        let latency = Int(max(0, scenario.sleepLatency + rng.gaussian(sd: 120)) / SleepConstants.epochLength)
        for index in 0..<min(latency, total) { stages[index] = .awake }

        var position = min(latency, total)
        var cycle = 0
        while position < total {
            let cycleEpochs = Int((90 + rng.gaussian(sd: 8)) * 2)
            let lightFirst = Int((16 + rng.gaussian(sd: 3)) * 2)
            let deepMinutes = max(0, 42 - 13 * Double(cycle) + rng.gaussian(sd: 4))
            let deepEpochs = Int(deepMinutes * 2)
            var index = position
            let cycleEnd = min(total, position + max(cycleEpochs, 60))
            while index < cycleEnd {
                let inCycle = index - position
                if inCycle >= lightFirst && inCycle < lightFirst + deepEpochs {
                    stages[index] = .deep
                } else {
                    stages[index] = .light
                }
                index += 1
            }
            position = cycleEnd
            cycle += 1
        }

        // Awakenings during the night (not inside deep sleep and not right after onset).
        if latency + 60 < total - 40 {
            for _ in 0..<max(0, scenario.awakenings) {
                let candidate = latency + 60 + Int(rng.unit() * Double(total - latency - 100))
                guard candidate >= 0, candidate < total else { continue }
                let length = 4 + Int(rng.unit() * 10)
                var start = candidate
                while start < total && stages[start] == .deep { start += 1 }
                for index in start..<min(total, start + length) { stages[index] = .awake }
            }
        }
        // Morning wake-up before getting up.
        let morning = 6 + Int(rng.unit() * 16)
        for index in max(0, total - morning)..<total { stages[index] = .awake }
        return stages
    }
}
