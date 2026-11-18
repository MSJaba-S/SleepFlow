import Foundation
import SleepModels

/// Three-state hidden Markov model (awake / light / deep) over 30-second epochs.
///
/// * Emissions: Gaussian likelihood of the smoothed activity per state, multiplied by
///   evidence factors (snoring implies sleep, phone pickups and vocal sounds suggest wakefulness,
///   very regular breathing suggests deeper sleep).
/// * Transitions: persistent states; deep sleep can only be entered from light sleep, and the
///   chance of entering it decays over the night (deep sleep concentrates in the first cycles).
/// * Decoding: forward–backward for posteriors (confidence) and Viterbi for the most likely path,
///   followed by minimum-duration rules so the timeline does not flicker.
///
/// These are consumer-level estimates, not polysomnography.
public struct SleepStager: Sendable {
    public let configuration: StagingConfiguration

    public init(configuration: StagingConfiguration = StagingConfiguration()) {
        self.configuration = configuration
    }

    public func stage(epochs: [EpochFeatures], method: TrackingMethod, sessionStart: Date) -> Hypnogram {
        guard !epochs.isEmpty else {
            return Hypnogram(start: sessionStart, stages: [], confidence: [], hasData: [])
        }
        let evidence = EvidenceBuilder.evidence(epochs: epochs, method: method, configuration: configuration)
        let emissions = evidence.map { emissionLikelihoods($0) }
        let transitions = (0..<epochs.count).map { transitionMatrix(epochIndex: $0) }

        let posteriors = forwardBackward(emissions: emissions, transitions: transitions)
        var path = viterbi(emissions: emissions, transitions: transitions)
        path = applyMinimumDurations(path, evidence: evidence)

        var confidence: [Double] = []
        confidence.reserveCapacity(path.count)
        for (index, stage) in path.enumerated() {
            let value = posteriors[index][stage.rawValue]
            confidence.append(evidence[index].hasData ? value : value * 0.5)
        }
        return Hypnogram(start: sessionStart, stages: path, confidence: confidence, hasData: evidence.map(\.hasData))
    }

    /// Posterior state probabilities for every epoch.
    public func posteriors(epochs: [EpochFeatures], method: TrackingMethod) -> [StageProbabilities] {
        let evidence = EvidenceBuilder.evidence(epochs: epochs, method: method, configuration: configuration)
        let emissions = evidence.map { emissionLikelihoods($0) }
        let transitions = (0..<epochs.count).map { transitionMatrix(epochIndex: $0) }
        return forwardBackward(emissions: emissions, transitions: transitions).map { StageProbabilities($0) }
    }

    // MARK: - Model

    public static let initialDistribution: [Double] = [0.75, 0.22, 0.03]

    func gaussian(_ x: Double, mean: Double, deviation: Double) -> Double {
        let z = (x - mean) / deviation
        return exp(-0.5 * z * z) / deviation
    }

    /// Likelihood of the evidence under awake, light and deep.
    public func emissionLikelihoods(_ evidence: EpochEvidence) -> [Double] {
        guard evidence.hasData else { return [1, 1, 1] }
        let c = configuration
        // Short-window activity (arousals) plus long-window burst density (deep vs light).
        let y = c.contextWeight * evidence.context + c.densityWeight * evidence.density
        var awake = gaussian(y, mean: c.awakeMean, deviation: c.awakeDeviation)
        var light = gaussian(y, mean: c.lightMean, deviation: c.lightDeviation)
        var deep = gaussian(y, mean: c.deepMean, deviation: c.deepDeviation)

        // Heavy tails so outliers never produce zero likelihood.
        awake += 1e-4
        light += 1e-4
        deep += 1e-4

        if evidence.pickup {
            awake *= 25
            deep *= 0.02
        }
        if evidence.snore {
            awake *= 0.15
            deep *= 0.9
        }
        if evidence.vocal {
            awake *= 2.2
            deep *= 0.3
        }
        if evidence.breathingRegularity >= 0.4 && !evidence.vocal && !evidence.pickup {
            let r = min(evidence.breathingRegularity, 1)
            deep *= 1 + 2 * r
            awake *= 0.7
        }
        if evidence.disturbance {
            awake *= 1.15
        }
        return [awake, light, deep]
    }

    /// Row-stochastic transition matrix for the step into `epochIndex`.
    public func transitionMatrix(epochIndex: Int) -> [[Double]] {
        let c = configuration
        let hours = Double(epochIndex) * SleepConstants.epochLength / 3600
        let decay = exp(-hours / max(c.deepDecayHours, 0.1))
        let lightToDeep = c.lightToDeepLate + (c.lightToDeepEarly - c.lightToDeepLate) * decay
        let awakeRow = [1 - c.awakeToLight - 0.0005, c.awakeToLight, 0.0005]
        let lightRow = [c.lightToAwake, 1 - c.lightToAwake - lightToDeep, lightToDeep]
        let deepRow = [c.deepToAwake, c.deepToLight, 1 - c.deepToAwake - c.deepToLight]
        return [awakeRow, lightRow, deepRow]
    }

    // MARK: - Inference

    func forwardBackward(emissions: [[Double]], transitions: [[[Double]]]) -> [[Double]] {
        let n = emissions.count
        guard n > 0 else { return [] }
        var alpha = [[Double]](repeating: [0, 0, 0], count: n)
        var scales = [Double](repeating: 1, count: n)

        for s in 0..<3 { alpha[0][s] = SleepStager.initialDistribution[s] * emissions[0][s] }
        scales[0] = max(alpha[0].reduce(0, +), 1e-300)
        alpha[0] = alpha[0].map { $0 / scales[0] }

        if n > 1 {
            for t in 1..<n {
                let matrix = transitions[t]
                for s in 0..<3 {
                    var sum = 0.0
                    for r in 0..<3 { sum += alpha[t - 1][r] * matrix[r][s] }
                    alpha[t][s] = sum * emissions[t][s]
                }
                scales[t] = max(alpha[t].reduce(0, +), 1e-300)
                alpha[t] = alpha[t].map { $0 / scales[t] }
            }
        }

        var beta = [[Double]](repeating: [1, 1, 1], count: n)
        if n > 1 {
            for t in stride(from: n - 2, through: 0, by: -1) {
                let matrix = transitions[t + 1]
                for r in 0..<3 {
                    var sum = 0.0
                    for s in 0..<3 { sum += matrix[r][s] * emissions[t + 1][s] * beta[t + 1][s] }
                    beta[t][r] = sum / scales[t + 1]
                }
            }
        }

        return (0..<n).map { t in
            let raw = (0..<3).map { alpha[t][$0] * beta[t][$0] }
            let total = raw.reduce(0, +)
            return total > 0 ? raw.map { $0 / total } : [1.0 / 3, 1.0 / 3, 1.0 / 3]
        }
    }

    func viterbi(emissions: [[Double]], transitions: [[[Double]]]) -> [SleepStage] {
        let n = emissions.count
        guard n > 0 else { return [] }
        func safeLog(_ x: Double) -> Double { log(max(x, 1e-300)) }
        var score = [[Double]](repeating: [0, 0, 0], count: n)
        var back = [[Int]](repeating: [0, 0, 0], count: n)
        for s in 0..<3 {
            score[0][s] = safeLog(SleepStager.initialDistribution[s]) + safeLog(emissions[0][s])
        }
        if n > 1 {
            for t in 1..<n {
                let matrix = transitions[t]
                for s in 0..<3 {
                    var best = -Double.infinity
                    var bestIndex = 0
                    for r in 0..<3 {
                        let candidate = score[t - 1][r] + safeLog(matrix[r][s])
                        if candidate > best {
                            best = candidate
                            bestIndex = r
                        }
                    }
                    score[t][s] = best + safeLog(emissions[t][s])
                    back[t][s] = bestIndex
                }
            }
        }
        var state = 0
        var bestFinal = -Double.infinity
        for s in 0..<3 where score[n - 1][s] > bestFinal {
            bestFinal = score[n - 1][s]
            state = s
        }
        var path = [Int](repeating: 0, count: n)
        path[n - 1] = state
        if n > 1 {
            for t in stride(from: n - 1, to: 0, by: -1) {
                state = back[t][state]
                path[t - 1] = state
            }
        }
        return path.map { SleepStage(rawValue: $0) ?? .light }
    }

    // MARK: - Post-processing

    func applyMinimumDurations(_ input: [SleepStage], evidence: [EpochEvidence]) -> [SleepStage] {
        var stages = input
        let firstSleep = stages.firstIndex { $0 != .awake } ?? stages.count

        // 1. Short deep bouts are absorbed into light sleep.
        for run in SleepStager.runs(stages) where run.stage == .deep && run.length < configuration.minimumDeepEpochs {
            for index in run.range { stages[index] = .light }
        }
        // 2. Very short awakenings after sleep onset (no pickup) count as brief arousals within light sleep.
        for run in SleepStager.runs(stages) where run.stage == .awake && run.range.lowerBound > firstSleep && run.length < configuration.minimumAwakeEpochs {
            let hasPickup = run.range.contains { evidence[$0].pickup }
            let isTrailing = run.range.upperBound >= stages.count
            if !hasPickup && !isTrailing {
                for index in run.range { stages[index] = .light }
            }
        }
        // 3. A single light epoch between two deep runs is part of the deep run.
        if stages.count >= 3 {
            for index in 1..<(stages.count - 1) where stages[index] == .light && stages[index - 1] == .deep && stages[index + 1] == .deep {
                stages[index] = .deep
            }
        }
        return stages
    }

    struct Run {
        var stage: SleepStage
        var range: Range<Int>
        var length: Int { range.count }
    }

    static func runs(_ stages: [SleepStage]) -> [Run] {
        guard !stages.isEmpty else { return [] }
        var result: [Run] = []
        var start = 0
        for index in 1...stages.count where index == stages.count || stages[index] != stages[start] {
            result.append(Run(stage: stages[start], range: start..<index))
            start = index
        }
        return result
    }
}
