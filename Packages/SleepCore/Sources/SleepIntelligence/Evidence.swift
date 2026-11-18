import Foundation
import SleepModels

/// Per-epoch evidence used by the sleep-state model, derived from `EpochFeatures`.
public struct EpochEvidence: Sendable, Hashable {
    /// Activity on a normalised log scale: `log(1 + raw / personalScale)`.
    public var activity: Double
    /// Smoothed activity over neighbouring epochs (Cole–Kripke style window).
    public var context: Double
    /// Fraction of epochs within ±5 minutes that contain a movement burst (0...1).
    /// Long movement-free stretches are the main marker of deep sleep in actigraphy.
    public var density: Double
    public var snore: Bool
    public var vocal: Bool
    public var pickup: Bool
    public var breathingRegularity: Double
    public var disturbance: Bool
    public var hasData: Bool
    public var masked: Bool

    public init(activity: Double, context: Double, density: Double, snore: Bool, vocal: Bool, pickup: Bool, breathingRegularity: Double, disturbance: Bool, hasData: Bool, masked: Bool) {
        self.activity = activity
        self.context = context
        self.density = density
        self.snore = snore
        self.vocal = vocal
        self.pickup = pickup
        self.breathingRegularity = breathingRegularity
        self.disturbance = disturbance
        self.hasData = hasData
        self.masked = masked
    }
}

public struct StagingConfiguration: Sendable, Hashable {
    /// Minimum personal activity scale per method, so very still nights are not over-normalised.
    public var minimumScaleMotion: Double = 2.0
    public var minimumScaleMicrophone: Double = 2.5
    public var maximumScale: Double = 40
    /// Percentile of the night's activity used as personal scale.
    public var scalePercentile: Double = 0.75

    /// Normalised activity from which an epoch counts as a movement burst.
    public var burstThreshold: Double = 0.3
    /// Half-width of the burst-density window in epochs (10 = ±5 minutes).
    public var densityRadius: Int = 10
    /// Combined evidence y = contextWeight · context + densityWeight · density.
    public var contextWeight: Double = 0.6
    public var densityWeight: Double = 1.0

    /// Gaussian emission parameters on the combined evidence scale.
    public var awakeMean: Double = 1.1
    public var awakeDeviation: Double = 0.5
    public var lightMean: Double = 0.25
    public var lightDeviation: Double = 0.18
    public var deepMean: Double = 0.02
    public var deepDeviation: Double = 0.06

    /// Per-epoch transition probabilities.
    public var awakeToLight: Double = 0.08
    public var lightToAwake: Double = 0.025
    public var lightToDeepEarly: Double = 0.04
    public var lightToDeepLate: Double = 0.008
    /// Hours over which deep-sleep entry decays from early to late (deep sleep dominates the first cycles).
    public var deepDecayHours: Double = 3.5
    public var deepToLight: Double = 0.045
    public var deepToAwake: Double = 0.004

    /// Post-processing: shortest deep bout kept (epochs) and shortest awakening kept after onset.
    public var minimumDeepEpochs: Int = 10
    public var minimumAwakeEpochs: Int = 2

    public init() {}

    /// Cole–Kripke weights for epochs t-4 ... t+2 (Cole et al., 1992), normalised.
    public static let coleKripkeWeights: [Double] = {
        let raw = [404.0, 598.0, 326.0, 441.0, 1408.0, 508.0, 350.0]
        let sum = raw.reduce(0, +)
        return raw.map { $0 / sum }
    }()

    public func minimumScale(for method: TrackingMethod) -> Double {
        method == .motion ? minimumScaleMotion : minimumScaleMicrophone
    }
}

public enum EvidenceBuilder {
    /// Raw, un-normalised activity of an epoch for the given tracking method.
    public static func rawActivity(_ epoch: EpochFeatures, method: TrackingMethod) -> Double {
        switch method {
        case .motion:
            return epoch.movementActivity + (epoch.pickup ? 8 : 0)
        case .microphone:
            // Bedding rustle and vocal sounds are produced by the sleeper; accelerometer data from a
            // phone on the bedside table is mostly zero but captures pickups.
            return epoch.soundActivity + 0.5 * epoch.movementActivity + (epoch.pickup ? 8 : 0)
        }
    }

    public static func personalScale(epochs: [EpochFeatures], method: TrackingMethod, configuration: StagingConfiguration) -> Double {
        let values = epochs.filter { $0.hasData(for: method) }.map { rawActivity($0, method: method) }
        let percentile = Stats.percentile(values, configuration.scalePercentile)
        return Stats.clamp(percentile, configuration.minimumScale(for: method), configuration.maximumScale)
    }

    /// Builds evidence with a centred context window (offline analysis of a finished night).
    public static func evidence(epochs: [EpochFeatures], method: TrackingMethod, configuration: StagingConfiguration) -> [EpochEvidence] {
        let scale = personalScale(epochs: epochs, method: method, configuration: configuration)
        let activities = epochs.map { epoch -> Double? in
            guard epoch.hasData(for: method) else { return nil }
            return log(1 + rawActivity(epoch, method: method) / scale)
        }
        let weights = StagingConfiguration.coleKripkeWeights
        var result: [EpochEvidence] = []
        result.reserveCapacity(epochs.count)
        for (index, epoch) in epochs.enumerated() {
            var weighted = 0.0
            var weightSum = 0.0
            for (offset, weight) in weights.enumerated() {
                let neighbour = index + offset - 4
                guard neighbour >= 0, neighbour < activities.count, let value = activities[neighbour] else { continue }
                weighted += weight * value
                weightSum += weight
            }
            let context = weightSum > 0 ? weighted / weightSum : 0
            let lower = Swift.max(0, index - configuration.densityRadius)
            let upper = Swift.min(activities.count - 1, index + configuration.densityRadius)
            let density = burstDensity(activities[lower...upper], threshold: configuration.burstThreshold)
            result.append(makeEvidence(epoch: epoch, method: method, activity: activities[index] ?? 0, context: context, density: density))
        }
        return result
    }

    /// Fraction of epochs with data whose activity reaches the burst threshold.
    static func burstDensity(_ values: ArraySlice<Double?>, threshold: Double) -> Double {
        let observed = values.compactMap { $0 }
        guard !observed.isEmpty else { return 0 }
        return Double(observed.filter { $0 >= threshold }.count) / Double(observed.count)
    }

    static func makeEvidence(epoch: EpochFeatures, method: TrackingMethod, activity: Double, context: Double, density: Double) -> EpochEvidence {
        let hasData = epoch.hasData(for: method)
        let soundTrusted = method == .microphone && !epoch.playbackMasked
        return EpochEvidence(
            activity: activity,
            context: context,
            density: density,
            snore: soundTrusted && epoch.snoreSeconds >= 3,
            vocal: soundTrusted && (epoch.talkSeconds >= 2 || epoch.coughCount > 0),
            pickup: epoch.pickup,
            breathingRegularity: soundTrusted ? epoch.breathingRegularity : 0,
            disturbance: epoch.disturbanceCount > 0,
            hasData: hasData,
            masked: epoch.playbackMasked
        )
    }
}
