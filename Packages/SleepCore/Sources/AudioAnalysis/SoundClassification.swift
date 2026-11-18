import Foundation
import SleepModels

/// Probability for each sound type. Values sum to 1.
public typealias SoundTypeDistribution = [SoundEventType: Double]

/// Anything that can turn event features into a distribution over sound types.
/// SleepFlow ships the transparent rule-based classifier below; an on-device model can be added
/// behind the same protocol without touching the rest of the pipeline.
public protocol SoundEventClassifying {
    mutating func classify(_ candidate: EventCandidate) -> SoundTypeDistribution
}

/// Feature-based classifier with explicit, documented rules.
///
/// Each class gets a score from smooth membership functions over physically motivated features
/// (spectral balance, onset sharpness, duration, envelope modulation, rhythm). Scores are turned
/// into probabilities with a softmax, so every decision carries a confidence. This is a heuristic
/// classifier, not machine learning. See ARCHITECTURE.md for the reasoning behind each rule.
public struct RuleBasedSoundClassifier: SoundEventClassifying, Sendable {
    public struct Configuration: Sendable {
        /// Softmax sharpness. Higher means more decisive probabilities.
        public var temperature: Double = 7
        /// Below this confidence the event is reported as `.unknown`.
        public var minimumConfidence: Double = 0.4
        public init() {}
    }

    public let configuration: Configuration
    /// Recent snore-like events (start time, centroid) for rhythm detection.
    private var recentSnoreLike: [(time: Date, centroid: Double)] = []
    private var recentBreathLike: [Date] = []

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public mutating func classify(_ candidate: EventCandidate) -> SoundTypeDistribution {
        let f = candidate.summary
        let lowShare = f.bandLow + f.bandLowMid
        let speechShare = f.bandLowMid + f.bandMid

        let rhythm = snoreRhythm(at: candidate.start, centroid: f.centroid)
        let breathRhythm = breathingRhythm(at: candidate.start)

        // Snoring: low-frequency, harmonic (low flatness), 0.3–3.5 s, repeating every breath.
        let snore = 0.28 * Stats.fall(f.centroid, 550, 1_100)
            + 0.24 * Stats.rise(lowShare, 0.55, 0.8)
            + 0.14 * Stats.fall(f.flatness, 0.22, 0.45)
            + 0.14 * Stats.band(f.duration, 0.25, 0.5, 2.5, 4.0)
            + 0.20 * rhythm

        // Coughing: explosive onset, short, broadband.
        let cough = 0.36 * Stats.rise(f.attack, 8, 16)
            + 0.24 * Stats.band(f.duration, 0.1, 0.18, 0.7, 1.2)
            + 0.20 * Stats.rise(f.flatness, 0.18, 0.38)
            + 0.20 * Stats.band(f.centroid, 400, 700, 2_500, 4_000)

        // Talking: longer, energy in the speech band, syllabic modulation 2.5–6.5 Hz.
        let syllabic = Stats.band(f.modulationRate, 1.5, 2.5, 6.5, 9) * Stats.rise(f.modulationDepth, 4, 8)
        let talk = 0.22 * Stats.rise(f.duration, 0.5, 1.2)
            + 0.24 * Stats.rise(speechShare, 0.5, 0.75)
            + 0.28 * syllabic
            + 0.14 * Stats.fall(f.flatness, 0.3, 0.5)
            + 0.12 * Stats.band(f.centroid, 300, 500, 2_500, 3_500)

        // Bedding rustle: noise-like, higher frequencies, soft onset, moderate level.
        let movement = 0.34 * Stats.rise(f.flatness, 0.3, 0.5)
            + 0.24 * Stats.rise(f.bandMid + f.bandHigh, 0.35, 0.6)
            + 0.22 * Stats.fall(f.attack, 10, 18)
            + 0.20 * Stats.fall(f.peakAboveFloor, 18, 28)

        // Environmental disturbance: very loud or long and not matching the sleeper's sounds;
        // low-frequency rumble (traffic, ventilation) also points here.
        let disturbance = 0.12
            + 0.40 * Stats.rise(f.peakAboveFloor, 25, 38)
            + 0.28 * Stats.rise(f.duration, 4, 8)
            + 0.12 * Stats.fall(f.centroid, 300, 600)

        // Audible breathing: soft, noise-like, 0.8–4 s, rhythmic.
        let breathing = 0.32 * Stats.fall(f.peakAboveFloor, 9, 13)
            + 0.22 * Stats.band(f.duration, 0.7, 1.1, 3, 4.5)
            + 0.22 * Stats.rise(f.flatness, 0.3, 0.5) * Stats.fall(f.centroid, 1_500, 3_000)
            + 0.24 * breathRhythm

        let scores: SoundTypeDistribution = [
            .snoring: snore,
            .coughing: cough,
            .talking: talk,
            .movement: movement,
            .disturbance: disturbance,
            .breathing: breathing
        ]
        let distribution = RuleBasedSoundClassifier.softmax(scores, temperature: configuration.temperature)

        let top = distribution.max { $0.value < $1.value }?.key
        if top == .snoring || snore > 0.55 {
            remember(snoreLikeAt: candidate.start, centroid: f.centroid)
        }
        if top == .breathing {
            recentBreathLike.append(candidate.start)
            if recentBreathLike.count > 6 { recentBreathLike.removeFirst(recentBreathLike.count - 6) }
        }
        return distribution
    }

    /// 0...1: how well recent snore-like events form a breathing rhythm (2.5–7.5 s apart, similar timbre).
    private func snoreRhythm(at time: Date, centroid: Double) -> Double {
        let similar = recentSnoreLike.filter { abs($0.centroid - centroid) <= max(150, centroid * 0.45) }
        guard let last = similar.last else { return 0 }
        let gap = time.timeIntervalSince(last.time)
        guard gap > 0 else { return 0 }
        var score = Stats.band(gap, 2.0, 2.8, 7.0, 9.0)
        if similar.count >= 2 {
            let previousGap = last.time.timeIntervalSince(similar[similar.count - 2].time)
            let consistency = 1 - min(1, abs(previousGap - gap) / max(gap, 1))
            score = min(1, score * (0.7 + 0.5 * consistency))
        }
        return score
    }

    private func breathingRhythm(at time: Date) -> Double {
        guard let last = recentBreathLike.last else { return 0 }
        return Stats.band(time.timeIntervalSince(last), 2.0, 2.8, 7.0, 9.0)
    }

    private mutating func remember(snoreLikeAt time: Date, centroid: Double) {
        recentSnoreLike.append((time: time, centroid: centroid))
        recentSnoreLike.removeAll { time.timeIntervalSince($0.time) > 60 }
        if recentSnoreLike.count > 8 { recentSnoreLike.removeFirst(recentSnoreLike.count - 8) }
    }

    public static func softmax(_ scores: SoundTypeDistribution, temperature: Double) -> SoundTypeDistribution {
        guard let maxScore = scores.values.max() else { return [:] }
        var exponentials: SoundTypeDistribution = [:]
        var sum = 0.0
        for (type, score) in scores {
            let value = exp((score - maxScore) * temperature)
            exponentials[type] = value
            sum += value
        }
        guard sum > 0 else { return scores }
        return exponentials.mapValues { $0 / sum }
    }

    /// Picks the final label. Low-confidence results become `.unknown`.
    public static func decide(_ distribution: SoundTypeDistribution, minimumConfidence: Double) -> (type: SoundEventType, confidence: Double) {
        guard let best = distribution.max(by: { $0.value < $1.value }) else { return (.unknown, 0) }
        if best.value < minimumConfidence {
            return (.unknown, best.value)
        }
        return (best.key, best.value)
    }
}

/// Combines the rule-based distribution with probabilities from a trained on-device model
/// (Apple's built-in SoundAnalysis classifier in the app). The model only knows some of
/// SleepFlow's classes; probability mass it assigns to "anything else" is distributed over
/// the remaining classes in proportion to the rule-based result.
public enum ClassifierFusion {
    public static let modelCoveredTypes: Set<SoundEventType> = [.snoring, .coughing, .talking, .breathing]

    public static func fuse(
        rule: SoundTypeDistribution,
        model: SoundTypeDistribution?,
        modelWeight: Double = 0.65
    ) -> SoundTypeDistribution {
        guard let model, !model.isEmpty else { return rule }
        let covered = model.filter { modelCoveredTypes.contains($0.key) }
        let coveredMass = min(1, covered.values.reduce(0, +))
        let remaining = max(0, 1 - coveredMass)

        let uncoveredRule = rule.filter { !modelCoveredTypes.contains($0.key) }
        let uncoveredRuleMass = uncoveredRule.values.reduce(0, +)

        var modelFull: SoundTypeDistribution = covered
        for (type, value) in uncoveredRule {
            let share = uncoveredRuleMass > 0 ? value / uncoveredRuleMass : 1.0 / Double(max(uncoveredRule.count, 1))
            modelFull[type, default: 0] += remaining * share
        }

        var fused: SoundTypeDistribution = [:]
        let allTypes = Set(rule.keys).union(modelFull.keys)
        for type in allTypes {
            fused[type] = (1 - modelWeight) * (rule[type] ?? 0) + modelWeight * (modelFull[type] ?? 0)
        }
        let total = fused.values.reduce(0, +)
        guard total > 0 else { return rule }
        return fused.mapValues { $0 / total }
    }
}
