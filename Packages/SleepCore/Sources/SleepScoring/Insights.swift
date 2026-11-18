import Foundation
import SleepModels

/// Something notable about a night. The app turns these into localised sentences.
public enum InsightKind: String, Codable, Sendable, CaseIterable {
    case goalReached
    case shortSleep
    case longLatency
    case quickOnset
    case fragmentedSleep
    case restless
    case calm
    case irregularSchedule
    case regularSchedule
    case highEfficiency
    case snoring
    case noisyRoom
    case lowCoverage
    case betterThanPrevious
    case worseThanPrevious
}

public struct SleepInsight: Codable, Sendable, Hashable, Identifiable {
    public var kind: InsightKind
    public var isPositive: Bool
    /// Supporting number (minutes, percentage points, count …) depending on `kind`.
    public var value: Double

    public init(kind: InsightKind, isPositive: Bool, value: Double) {
        self.kind = kind
        self.isPositive = isPositive
        self.value = value
    }

    public var id: InsightKind { kind }
}

/// Concrete habit suggestions, ordered by expected benefit for this night.
public enum SuggestionKind: String, Codable, Sendable, CaseIterable {
    case keepRoutine
    case earlierBedtime
    case windDown
    case consistentSchedule
    case limitCaffeine
    case quieterRoom
    case snoringPosition
    case checkPlacement
    case limitScreens
    case morningLight
}

public enum InsightEngine {
    public static func insights(score: SleepScore, metrics: SleepMetrics, targets: ScoreTargets, previousScore: Int?, noisyEpochFraction: Double) -> [SleepInsight] {
        var result: [SleepInsight] = []
        let shortfall = targets.sleepGoal - metrics.totalSleep

        if metrics.dataCoverage < 0.6 {
            result.append(SleepInsight(kind: .lowCoverage, isPositive: false, value: metrics.dataCoverage * 100))
        }
        if shortfall <= 15 * 60 {
            result.append(SleepInsight(kind: .goalReached, isPositive: true, value: metrics.totalSleep / 60))
        } else if shortfall >= 45 * 60 {
            result.append(SleepInsight(kind: .shortSleep, isPositive: false, value: shortfall / 60))
        }
        if let latency = metrics.sleepLatency {
            if latency > 30 * 60 {
                result.append(SleepInsight(kind: .longLatency, isPositive: false, value: latency / 60))
            } else if latency <= 15 * 60 {
                result.append(SleepInsight(kind: .quickOnset, isPositive: true, value: latency / 60))
            }
        }
        if metrics.interruptions >= 3 || metrics.wakeAfterSleepOnset > 30 * 60 {
            result.append(SleepInsight(kind: .fragmentedSleep, isPositive: false, value: Double(metrics.interruptions)))
        }
        if metrics.restlessness >= 0.3 {
            result.append(SleepInsight(kind: .restless, isPositive: false, value: metrics.restlessness * 100))
        } else if metrics.restlessness <= 0.1 && !metrics.noSleepDetected {
            result.append(SleepInsight(kind: .calm, isPositive: true, value: metrics.restlessness * 100))
        }
        if let consistency = score.component(.consistency) {
            if consistency.measuredValue > 60 {
                result.append(SleepInsight(kind: .irregularSchedule, isPositive: false, value: consistency.measuredValue))
            } else if consistency.measuredValue <= 20 {
                result.append(SleepInsight(kind: .regularSchedule, isPositive: true, value: consistency.measuredValue))
            }
        }
        if metrics.efficiency >= 0.9 {
            result.append(SleepInsight(kind: .highEfficiency, isPositive: true, value: metrics.efficiency * 100))
        }
        if metrics.snoringDuration >= 20 * 60 {
            result.append(SleepInsight(kind: .snoring, isPositive: false, value: metrics.snoringDuration / 60))
        }
        if noisyEpochFraction >= 0.1 {
            result.append(SleepInsight(kind: .noisyRoom, isPositive: false, value: noisyEpochFraction * 100))
        }
        if let previousScore {
            let change = score.value - previousScore
            if change >= 5 {
                result.append(SleepInsight(kind: .betterThanPrevious, isPositive: true, value: Double(change)))
            } else if change <= -5 {
                result.append(SleepInsight(kind: .worseThanPrevious, isPositive: false, value: Double(-change)))
            }
        }
        // Negative findings first: they explain where points were lost.
        return result.sorted { !$0.isPositive && $1.isPositive }
    }

    /// Factors sorted by the points they cost tonight (largest first).
    public static func mainContributors(_ score: SleepScore) -> [ScoreComponent] {
        score.components.sorted { $0.pointsLost > $1.pointsLost }
    }

    public static func suggestions(score: SleepScore, metrics: SleepMetrics, targets: ScoreTargets, noisyEpochFraction: Double) -> [SuggestionKind] {
        var result: [SuggestionKind] = []
        if metrics.dataCoverage < 0.6 {
            result.append(.checkPlacement)
        }
        for component in mainContributors(score) where component.pointsLost >= 3 {
            switch component.factor {
            case .duration:
                result.append(.earlierBedtime)
            case .latency:
                result.append(.windDown)
                result.append(.limitScreens)
            case .efficiency, .interruptions:
                result.append(.limitCaffeine)
            case .restlessness:
                result.append(.windDown)
            case .consistency:
                result.append(.consistentSchedule)
                result.append(.morningLight)
            }
        }
        if metrics.snoringDuration >= 20 * 60 {
            result.append(.snoringPosition)
        }
        if noisyEpochFraction >= 0.1 {
            result.append(.quieterRoom)
        }
        if result.isEmpty {
            result.append(.keepRoutine)
        }
        // Remove duplicates while keeping order, and keep the list short.
        var seen = Set<SuggestionKind>()
        return Array(result.filter { seen.insert($0).inserted }.prefix(3))
    }
}
