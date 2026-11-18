import Foundation
import SleepModels

/// Causal (filter-only) version of `SleepStager` that updates once per epoch while tracking.
///
/// It uses the same emission and transition model, but only past epochs for context and a
/// personal activity scale that is learnt as the night progresses.
public final class OnlineSleepEstimator {
    public let method: TrackingMethod
    private let stager: SleepStager
    private var rawHistory: [Double] = []
    private var normalisedHistory: [Double?] = []
    private var forward: [Double] = SleepStager.initialDistribution
    private var nextIndex = 0
    public private(set) var latest: OnlineEstimate?

    public init(method: TrackingMethod, configuration: StagingConfiguration = StagingConfiguration()) {
        self.method = method
        self.stager = SleepStager(configuration: configuration)
    }

    public var epochsProcessed: Int { nextIndex }

    @discardableResult
    public func update(with epoch: EpochFeatures) -> OnlineEstimate {
        // Epochs without any record (app suspended) are propagated without evidence.
        while nextIndex < epoch.index {
            step(evidence: nil, index: nextIndex)
            normalisedHistory.append(nil)
            nextIndex += 1
        }

        let configuration = stager.configuration
        let hasData = epoch.hasData(for: method)
        var activity = 0.0
        if hasData {
            let raw = EvidenceBuilder.rawActivity(epoch, method: method)
            rawHistory.append(raw)
            let scale = Stats.clamp(
                Stats.percentile(rawHistory, configuration.scalePercentile),
                configuration.minimumScale(for: method),
                configuration.maximumScale
            )
            activity = log(1 + raw / scale)
        }
        normalisedHistory.append(hasData ? activity : nil)

        // Causal context: Cole–Kripke weights for t-4 ... t.
        let weights = Array(StagingConfiguration.coleKripkeWeights.prefix(5))
        var weighted = 0.0
        var weightSum = 0.0
        let current = normalisedHistory.count - 1
        for (offset, weight) in weights.enumerated() {
            let index = current - 4 + offset
            guard index >= 0, let value = normalisedHistory[index] else { continue }
            weighted += weight * value
            weightSum += weight
        }
        let context = weightSum > 0 ? weighted / weightSum : 0
        // Causal burst density over the last 2 × radius epochs (same span as the offline window).
        let windowStart = max(0, current - 2 * configuration.densityRadius)
        let density = EvidenceBuilder.burstDensity(normalisedHistory[windowStart...current], threshold: configuration.burstThreshold)
        let evidence = EvidenceBuilder.makeEvidence(epoch: epoch, method: method, activity: activity, context: context, density: density)
        step(evidence: evidence, index: epoch.index)
        nextIndex = epoch.index + 1

        let observed = normalisedHistory.compactMap { $0 }
        let reference = max(0.45, Stats.percentile(observed, 0.6))
        let arousal = hasData && (evidence.pickup || evidence.vocal || activity >= reference)
        let estimate = OnlineEstimate(
            epochIndex: epoch.index,
            probabilities: StageProbabilities(forward),
            arousal: arousal,
            hasData: hasData,
            activity: activity
        )
        latest = estimate
        return estimate
    }

    private func step(evidence: EpochEvidence?, index: Int) {
        let emission = evidence.map { stager.emissionLikelihoods($0) } ?? [1, 1, 1]
        var next = [0.0, 0.0, 0.0]
        if index == 0 {
            for s in 0..<3 { next[s] = SleepStager.initialDistribution[s] * emission[s] }
        } else {
            let matrix = stager.transitionMatrix(epochIndex: index)
            for s in 0..<3 {
                var sum = 0.0
                for r in 0..<3 { sum += forward[r] * matrix[r][s] }
                next[s] = sum * emission[s]
            }
        }
        let total = next.reduce(0, +)
        forward = total > 0 ? next.map { $0 / total } : [1.0 / 3, 1.0 / 3, 1.0 / 3]
    }
}
