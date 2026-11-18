import Foundation
import SleepModels

/// Looks for a regular breathing rhythm in the quiet parts of an epoch.
///
/// Breathing near the phone modulates the level envelope with the respiratory rate
/// (typically 8–24 breaths per minute). The envelope of quiet frames is resampled to 4 Hz,
/// detrended and autocorrelated for lags of 2.5–7.5 s. A clear autocorrelation peak gives the
/// rate; its height is reported as "regularity". Very regular breathing is typical of deeper sleep.
public enum BreathingAnalyzer {
    public struct Result: Sendable, Hashable {
        public var breathsPerMinute: Double
        public var regularity: Double
    }

    /// - Parameters:
    ///   - levels: frame levels in dB, evenly spaced by `hopDuration`. Frames that belong to
    ///     sound events must already be excluded (pass `nil` for them).
    public static func analyse(levels: [Double?], hopDuration: Double) -> Result? {
        guard hopDuration > 0, levels.count > 10 else { return nil }
        let targetRate = 4.0
        let framesPerSample = max(1, Int((1.0 / targetRate / hopDuration).rounded()))
        var envelope: [Double] = []
        var index = 0
        var missing = 0
        while index < levels.count {
            let chunk = levels[index..<min(index + framesPerSample, levels.count)].compactMap { $0 }
            if chunk.isEmpty {
                missing += 1
                envelope.append(envelope.last ?? 0)
            } else {
                envelope.append(chunk.reduce(0, +) / Double(chunk.count))
            }
            index += framesPerSample
        }
        // Need at least ~20 s of mostly quiet signal.
        guard envelope.count >= 80, Double(missing) / Double(envelope.count) < 0.3 else { return nil }

        let mean = Stats.mean(envelope)
        let centered = envelope.map { $0 - mean }
        let deviation = Stats.standardDeviation(centered)
        // Envelope must actually move (≥ 0.25 dB) but not be dominated by large events.
        guard deviation >= 0.25, deviation <= 6 else { return nil }

        let sampleSpacing = Double(framesPerSample) * hopDuration
        let minLag = max(1, Int((2.5 / sampleSpacing).rounded()))
        let maxLag = min(centered.count / 2, Int((7.5 / sampleSpacing).rounded()))
        guard maxLag > minLag else { return nil }

        let energy = centered.reduce(0) { $0 + $1 * $1 }
        guard energy > 1e-9 else { return nil }

        var bestLag = 0
        var bestCorrelation = 0.0
        for lag in minLag...maxLag {
            var sum = 0.0
            for i in 0..<(centered.count - lag) {
                sum += centered[i] * centered[i + lag]
            }
            // Unbiased normalisation so longer lags are not penalised.
            let normalised = (sum / Double(centered.count - lag)) / (energy / Double(centered.count))
            if normalised > bestCorrelation {
                bestCorrelation = normalised
                bestLag = lag
            }
        }
        guard bestLag > 0, bestCorrelation >= 0.25 else { return nil }
        let period = Double(bestLag) * sampleSpacing
        return Result(breathsPerMinute: 60.0 / period, regularity: min(1, bestCorrelation))
    }
}
