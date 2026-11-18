import Foundation
import SleepModels

public enum WakeReason: String, Codable, Sendable, CaseIterable {
    /// Light sleep together with movement or sound inside the window.
    case lightSleep
    /// The sleeper is already awake inside the window.
    case alreadyAwake
    /// Close to the deadline and not in deep sleep.
    case nearDeadline
    /// The deadline was reached. This is also what the system alarm guarantees.
    case deadline
}

public enum SmartAlarmDecision: Equatable, Sendable {
    case wait
    case wake(WakeReason)
}

/// Thresholds for the Smart Alarm.
public struct SmartAlarmPolicy: Sendable, Hashable {
    /// P(light) + P(awake) needed (together with an arousal) to wake early.
    public var lightSleepProbability: Double = 0.55
    /// P(awake) needed on consecutive epochs to treat the user as already awake.
    public var awakeProbability: Double = 0.6
    public var awakeConsecutiveEpochs: Int = 2
    /// In the last part of the window, wake as soon as deep sleep is unlikely.
    public var finalStretch: TimeInterval = 3 * 60
    public var finalStretchDeepLimit: Double = 0.5

    public init() {}
}

/// Decides, epoch by epoch, whether to wake the user now.
///
/// The decision can only ever bring the alarm *forward*: outside the window it waits, and at or
/// after the deadline it always wakes. Independently of this engine the app schedules a
/// system alarm at the deadline, so a crashed or suspended app can never postpone waking.
public struct SmartAlarmEngine: Sendable {
    public let policy: SmartAlarmPolicy
    private var awakeStreak = 0
    public private(set) var decided: WakeReason?

    public init(policy: SmartAlarmPolicy = SmartAlarmPolicy()) {
        self.policy = policy
    }

    public mutating func reset() {
        awakeStreak = 0
        decided = nil
    }

    public mutating func evaluate(now: Date, occurrence: AlarmOccurrence, estimate: OnlineEstimate?) -> SmartAlarmDecision {
        if let decided { return .wake(decided) }
        if now >= occurrence.deadline {
            return latch(.deadline)
        }
        guard now >= occurrence.windowStart else {
            awakeStreak = 0
            return .wait
        }
        guard let estimate, estimate.hasData else {
            // No sensor data: rely on the deadline alarm.
            return .wait
        }
        let p = estimate.probabilities
        if p.awake >= policy.awakeProbability {
            awakeStreak += 1
        } else {
            awakeStreak = 0
        }
        if awakeStreak >= policy.awakeConsecutiveEpochs {
            return latch(.alreadyAwake)
        }
        if estimate.arousal && (p.light + p.awake) >= policy.lightSleepProbability {
            return latch(.lightSleep)
        }
        if occurrence.deadline.timeIntervalSince(now) <= policy.finalStretch && p.deep < policy.finalStretchDeepLimit {
            return latch(.nearDeadline)
        }
        return .wait
    }

    private mutating func latch(_ reason: WakeReason) -> SmartAlarmDecision {
        decided = reason
        return .wake(reason)
    }
}
