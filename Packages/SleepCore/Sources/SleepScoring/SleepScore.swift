import Foundation
import SleepModels

/// The factors that make up the Sleep Score.
public enum ScoreFactor: String, Codable, Sendable, CaseIterable, Hashable {
    case duration
    case efficiency
    case latency
    case interruptions
    case restlessness
    case consistency
}

/// Relative importance of each factor. Weights do not need to sum to 1; they are normalised.
public struct ScoreWeights: Codable, Sendable, Hashable {
    public var duration: Double
    public var efficiency: Double
    public var latency: Double
    public var interruptions: Double
    public var restlessness: Double
    public var consistency: Double

    public init(duration: Double = 0.30, efficiency: Double = 0.20, latency: Double = 0.10, interruptions: Double = 0.15, restlessness: Double = 0.10, consistency: Double = 0.15) {
        self.duration = duration
        self.efficiency = efficiency
        self.latency = latency
        self.interruptions = interruptions
        self.restlessness = restlessness
        self.consistency = consistency
    }

    public static let standard = ScoreWeights()

    public func weight(for factor: ScoreFactor) -> Double {
        switch factor {
        case .duration: return duration
        case .efficiency: return efficiency
        case .latency: return latency
        case .interruptions: return interruptions
        case .restlessness: return restlessness
        case .consistency: return consistency
        }
    }
}

/// Target ranges. Every factor scores 100 inside its target and falls linearly to 0 at its limit.
public struct ScoreTargets: Codable, Sendable, Hashable {
    /// Personal sleep goal.
    public var sleepGoal: TimeInterval
    /// Shortfall against the goal at which the duration factor reaches 0.
    public var maximumShortfall: TimeInterval = 3 * 3600
    /// Sleep longer than goal + this is mildly penalised.
    public var oversleepTolerance: TimeInterval = 90 * 60
    public var efficiencyTarget: Double = 0.90
    public var efficiencyFloor: Double = 0.65
    public var latencyTarget: TimeInterval = 15 * 60
    public var latencyLimit: TimeInterval = 60 * 60
    public var wakeAfterOnsetAllowance: TimeInterval = 10 * 60
    public var restlessnessTarget: Double = 0.10
    public var restlessnessLimit: Double = 0.45
    public var consistencyTargetMinutes: Double = 15
    public var consistencyLimitMinutes: Double = 120

    public init(sleepGoal: TimeInterval) {
        self.sleepGoal = max(sleepGoal, 3600)
    }
}

public struct ScoreComponent: Codable, Sendable, Hashable, Identifiable {
    public var factor: ScoreFactor
    /// 0...100
    public var score: Double
    /// Normalised weight actually used (0...1).
    public var weight: Double
    /// The measured value the score is based on (seconds, fraction, count or minutes, see factor).
    public var measuredValue: Double

    public init(factor: ScoreFactor, score: Double, weight: Double, measuredValue: Double) {
        self.factor = factor
        self.score = score
        self.weight = weight
        self.measuredValue = measuredValue
    }

    public var id: ScoreFactor { factor }
    /// Points this factor contributes to the total.
    public var contribution: Double { score * weight }
    /// Points lost compared with a perfect factor.
    public var pointsLost: Double { (100 - score) * weight }
}

public enum ScoreQuality: String, Codable, Sendable, CaseIterable {
    case excellent, good, fair, poor, bad

    public init(score: Int) {
        switch score {
        case 85...: self = .excellent
        case 70..<85: self = .good
        case 55..<70: self = .fair
        case 40..<55: self = .poor
        default: self = .bad
        }
    }
}

public struct SleepScore: Codable, Sendable, Hashable {
    public var value: Int
    public var components: [ScoreComponent]
    public var quality: ScoreQuality
    /// Set when too little of the night had sensor data for a reliable score.
    public var lowConfidence: Bool

    public init(value: Int, components: [ScoreComponent], quality: ScoreQuality, lowConfidence: Bool) {
        self.value = value
        self.components = components
        self.quality = quality
        self.lowConfidence = lowConfidence
    }

    public func component(_ factor: ScoreFactor) -> ScoreComponent? {
        components.first { $0.factor == factor }
    }
}

/// Bed and wake time of an earlier night, used for the consistency factor.
public struct HistoricalNight: Codable, Sendable, Hashable {
    public var bedtime: Date
    public var wakeTime: Date

    public init(bedtime: Date, wakeTime: Date) {
        self.bedtime = bedtime
        self.wakeTime = wakeTime
    }
}

/// Transparent, testable Sleep Score.
///
/// score = Σ weightᵢ · factorᵢ / Σ weightᵢ over the factors that can be computed.
/// Each factor is a piecewise-linear function of one measured value (see `ScoreTargets`).
public struct SleepScoreCalculator: Sendable {
    public var weights: ScoreWeights
    public var minimumHistoryForConsistency = 3

    public init(weights: ScoreWeights = .standard) {
        self.weights = weights
    }

    public func score(metrics: SleepMetrics, targets: ScoreTargets, history: [HistoricalNight], calendar: Calendar = .current) -> SleepScore {
        var raw: [(ScoreFactor, Double, Double)] = []

        raw.append((.duration, SleepScoreCalculator.durationScore(metrics.totalSleep, targets: targets), metrics.totalSleep))
        raw.append((.efficiency, SleepScoreCalculator.linear(metrics.efficiency, best: targets.efficiencyTarget, worst: targets.efficiencyFloor), metrics.efficiency))
        let latency = metrics.sleepLatency ?? targets.latencyLimit
        raw.append((.latency, SleepScoreCalculator.linear(latency, best: targets.latencyTarget, worst: targets.latencyLimit), latency))
        raw.append((.interruptions, SleepScoreCalculator.interruptionScore(metrics, targets: targets), Double(metrics.interruptions)))
        raw.append((.restlessness, SleepScoreCalculator.linear(metrics.restlessness, best: targets.restlessnessTarget, worst: targets.restlessnessLimit), metrics.restlessness))
        if history.count >= minimumHistoryForConsistency, let deviation = SleepScoreCalculator.consistencyDeviation(metrics: metrics, history: history, calendar: calendar) {
            raw.append((.consistency, SleepScoreCalculator.linear(deviation, best: targets.consistencyTargetMinutes, worst: targets.consistencyLimitMinutes), deviation))
        }

        if metrics.noSleepDetected {
            // Without detected sleep no factor can be "good": an empty night scores 0.
            raw = raw.map { entry in (entry.0, 0.0, entry.2) }
        }

        let weightSum = raw.reduce(0) { $0 + weights.weight(for: $1.0) }
        let components = raw.map { factor, score, measured in
            ScoreComponent(
                factor: factor,
                score: score.rounded(),
                weight: weightSum > 0 ? weights.weight(for: factor) / weightSum : 0,
                measuredValue: measured
            )
        }
        let total = components.reduce(0) { $0 + $1.score * $1.weight }
        let value = Int(Stats.clamp(total, 0, 100).rounded())
        return SleepScore(
            value: value,
            components: components,
            quality: ScoreQuality(score: value),
            lowConfidence: metrics.dataCoverage < 0.6
        )
    }

    // MARK: - Factor functions

    /// 100 at `best`, 0 at `worst`, linear in between. Works for both directions.
    public static func linear(_ value: Double, best: Double, worst: Double) -> Double {
        guard best != worst else { return value == best ? 100 : 0 }
        let t = (value - worst) / (best - worst)
        return Stats.clamp(t, 0, 1) * 100
    }

    public static func durationScore(_ totalSleep: TimeInterval, targets: ScoreTargets) -> Double {
        let goal = targets.sleepGoal
        if totalSleep >= goal {
            let excess = totalSleep - goal - targets.oversleepTolerance
            guard excess > 0 else { return 100 }
            // -5 points per extra half hour, never below 70: long sleep is rarely the problem.
            return max(70, 100 - excess / 1800 * 5)
        }
        let shortfall = goal - totalSleep
        // A short tolerance of 15 minutes still counts as reaching the goal.
        guard shortfall > 15 * 60 else { return 100 }
        return linear(shortfall, best: 15 * 60, worst: targets.maximumShortfall)
    }

    public static func interruptionScore(_ metrics: SleepMetrics, targets: ScoreTargets) -> Double {
        let extraInterruptions = max(0, metrics.interruptions - 1)
        let extraWake = max(0, metrics.wakeAfterSleepOnset - targets.wakeAfterOnsetAllowance) / 60
        return Stats.clamp(100 - 15 * Double(extraInterruptions) - 1.5 * extraWake, 0, 100)
    }

    /// Average distance (minutes) of tonight's bed and wake time from the personal circular means.
    public static func consistencyDeviation(metrics: SleepMetrics, history: [HistoricalNight], calendar: Calendar) -> Double? {
        let bed = metrics.sleepOnset ?? metrics.sessionStart
        let wake = metrics.finalAwakening ?? metrics.sessionEnd
        let recent = history.sorted { $0.bedtime > $1.bedtime }.prefix(7)
        let bedMinutes = recent.map { ClockTime.minutesSinceMidnight($0.bedtime, calendar: calendar) }
        let wakeMinutes = recent.map { ClockTime.minutesSinceMidnight($0.wakeTime, calendar: calendar) }
        guard let bedMean = ClockTime.circularMean(minutes: Array(bedMinutes)),
              let wakeMean = ClockTime.circularMean(minutes: Array(wakeMinutes)) else { return nil }
        let bedDeviation = ClockTime.circularDistance(ClockTime.minutesSinceMidnight(bed, calendar: calendar), bedMean)
        let wakeDeviation = ClockTime.circularDistance(ClockTime.minutesSinceMidnight(wake, calendar: calendar), wakeMean)
        return (bedDeviation + wakeDeviation) / 2
    }
}

public extension SleepScore {
    /// The same night scored with other weights. Factor scores do not depend on the weights, so a
    /// stored night can be re-weighted exactly without the raw data.
    func reweighted(_ weights: ScoreWeights) -> SleepScore {
        let weightSum = components.reduce(0) { $0 + weights.weight(for: $1.factor) }
        let reweighted = components.map { component in
            ScoreComponent(
                factor: component.factor,
                score: component.score,
                weight: weightSum > 0 ? weights.weight(for: component.factor) / weightSum : 0,
                measuredValue: component.measuredValue
            )
        }
        let total = reweighted.reduce(0) { $0 + $1.score * $1.weight }
        let value = Int(Stats.clamp(total, 0, 100).rounded())
        return SleepScore(value: value, components: reweighted, quality: ScoreQuality(score: value), lowConfidence: lowConfidence)
    }
}

public extension ScoreWeights {
    /// Normalised share of one factor, given which factors take part.
    func share(of factor: ScoreFactor, among factors: [ScoreFactor] = ScoreFactor.allCases) -> Double {
        let sum = factors.reduce(0) { $0 + weight(for: $1) }
        return sum > 0 ? weight(for: factor) / sum : 0
    }

    func setting(_ factor: ScoreFactor, to value: Double) -> ScoreWeights {
        var copy = self
        let clamped = Stats.clamp(value, 0, 1)
        switch factor {
        case .duration: copy.duration = clamped
        case .efficiency: copy.efficiency = clamped
        case .latency: copy.latency = clamped
        case .interruptions: copy.interruptions = clamped
        case .restlessness: copy.restlessness = clamped
        case .consistency: copy.consistency = clamped
        }
        return copy
    }

    /// True when every weight is zero (the score would be undefined).
    var isEmpty: Bool { ScoreFactor.allCases.allSatisfy { weight(for: $0) <= 0 } }
}
