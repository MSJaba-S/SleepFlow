import Foundation
import SleepModels

/// "Wake me after this much sleep": a power nap or whole sleep cycles, counted from the moment
/// the user is detected to be asleep instead of from when tracking started.
///
/// Safety: the alarm can only move *earlier*. Before sleep onset is known, the deadline is the
/// latest possible one (start + `maximumLatency` + `sleepDuration`), and that is what the system
/// alarm is scheduled for. Once onset is detected the deadline is recomputed from it, which is
/// never later.
public struct NapPlan: Codable, Sendable, Hashable {
    /// Sleep to get before waking, counted from sleep onset.
    public var sleepDuration: TimeInterval
    /// Smart Alarm window before the end, in which a light moment is used to wake.
    public var window: TimeInterval
    /// If no sleep has been detected after this long, counting starts anyway.
    public var maximumLatency: TimeInterval
    /// Short naps: wake as soon as deep sleep seems to begin, to avoid waking up groggy.
    public var wakesBeforeDeepSleep: Bool
    /// The deep-sleep guard only acts after this much sleep.
    public var minimumSleepBeforeGuard: TimeInterval
    /// P(deep) on consecutive epochs that counts as "deep sleep is starting".
    public var deepSleepProbability: Double
    public var deepSleepEpochs: Int

    public init(
        sleepDuration: TimeInterval,
        window: TimeInterval,
        maximumLatency: TimeInterval,
        wakesBeforeDeepSleep: Bool,
        minimumSleepBeforeGuard: TimeInterval = 10 * 60,
        deepSleepProbability: Double = 0.6,
        deepSleepEpochs: Int = 2
    ) {
        self.sleepDuration = max(60, sleepDuration)
        self.window = max(0, min(window, sleepDuration))
        self.maximumLatency = max(0, maximumLatency)
        self.wakesBeforeDeepSleep = wakesBeforeDeepSleep
        self.minimumSleepBeforeGuard = max(0, minimumSleepBeforeGuard)
        self.deepSleepProbability = deepSleepProbability
        self.deepSleepEpochs = max(1, deepSleepEpochs)
    }

    /// A short nap that avoids deep sleep (typically 20 or 30 minutes).
    public static func powerNap(minutes: Int) -> NapPlan {
        let minutes = max(5, minutes)
        return NapPlan(
            sleepDuration: TimeInterval(minutes * 60),
            window: TimeInterval((minutes <= 20 ? 5 : 10) * 60),
            maximumLatency: 20 * 60,
            wakesBeforeDeepSleep: true,
            minimumSleepBeforeGuard: TimeInterval(min(12, max(5, minutes / 2)) * 60)
        )
    }

    /// Whole sleep cycles of about 90 minutes; wakes in the light phase at the end of the last one.
    public static func cycles(_ count: Int) -> NapPlan {
        let count = max(1, count)
        return NapPlan(
            sleepDuration: TimeInterval(count * 90 * 60),
            window: TimeInterval((count == 1 ? 20 : 30) * 60),
            maximumLatency: 30 * 60,
            wakesBeforeDeepSleep: false,
            minimumSleepBeforeGuard: 0
        )
    }

    /// Number of 90-minute cycles, or nil for a power nap.
    public var cycleCount: Int? {
        guard !wakesBeforeDeepSleep else { return nil }
        return max(1, Int((sleepDuration / (90 * 60)).rounded()))
    }

    /// Counting starts at the latest here.
    public func latestCountStart(start: Date) -> Date {
        start.addingTimeInterval(maximumLatency)
    }

    /// The latest possible wake-up, used for the system alarm before sleep onset is known.
    public func latestDeadline(start: Date) -> Date {
        latestCountStart(start: start).addingTimeInterval(sleepDuration)
    }

    /// The wake-up for a nap that started at `start`. The window never begins before sleep onset.
    public func occurrence(key: String, start: Date, onset: Date?) -> AlarmOccurrence {
        let latest = latestCountStart(start: start)
        let countFrom = min(max(onset ?? latest, start), latest)
        let deadline = countFrom.addingTimeInterval(sleepDuration)
        let windowStart = max(countFrom, deadline.addingTimeInterval(-window))
        return AlarmOccurrence(key: key, deadline: deadline, windowStart: windowStart)
    }

    /// Stable key for a nap started at `start` (prefixed so it never clashes with clock alarms).
    public static func key(start: Date, calendar: Calendar) -> String {
        "nap " + AlarmOccurrencePlanner.key(for: start, calendar: calendar)
    }
}

/// Finds the moment of falling asleep while tracking, from the online stage estimate.
///
/// Sleep onset is the start of the first run of `confirmationEpochs` epochs (5 minutes by default)
/// that are probably asleep. People often move a few times while drifting off, so single restless
/// epochs are tolerated; two restless epochs in a row, more than `toleratedBreaks` in total, or one
/// clearly awake epoch start the search again. Epochs without sensor data neither confirm nor break
/// a run.
public struct SleepOnsetDetector: Sendable, Hashable {
    public var asleepProbability: Double
    public var confirmationEpochs: Int
    public var toleratedBreaks: Int
    public var clearlyAwakeProbability: Double

    public private(set) var onset: Date?
    private var runStart: Date?
    private var runEpochs = 0
    private var breaks = 0
    private var consecutiveBreaks = 0

    public init(asleepProbability: Double = 0.7, confirmationEpochs: Int = 10, toleratedBreaks: Int = 2, clearlyAwakeProbability: Double = 0.85) {
        self.asleepProbability = asleepProbability
        self.confirmationEpochs = max(1, confirmationEpochs)
        self.toleratedBreaks = max(0, toleratedBreaks)
        self.clearlyAwakeProbability = clearlyAwakeProbability
    }

    /// Returns the onset once, on the epoch that confirms it.
    public mutating func update(epochStart: Date, estimate: OnlineEstimate) -> Date? {
        guard onset == nil, estimate.hasData else { return nil }
        let p = estimate.probabilities
        if p.light + p.deep >= asleepProbability {
            if runStart == nil {
                runStart = epochStart
                runEpochs = 0
                breaks = 0
            }
            runEpochs += 1
            consecutiveBreaks = 0
        } else if runStart != nil {
            breaks += 1
            consecutiveBreaks += 1
            if consecutiveBreaks > 1 || breaks > toleratedBreaks || p.awake >= clearlyAwakeProbability {
                restart()
            }
        }
        if let start = runStart, runEpochs >= confirmationEpochs {
            onset = start
            return start
        }
        return nil
    }

    private mutating func restart() {
        runStart = nil
        runEpochs = 0
        breaks = 0
        consecutiveBreaks = 0
    }
}

/// Follows a nap while it is tracked: detects sleep onset, moves the wake-up accordingly and, for
/// power naps, asks to wake before deep sleep sets in.
public struct NapTracker: Sendable, Hashable {
    public enum Update: Equatable, Sendable {
        case none
        /// Counting has started – from the detected sleep onset, or at the latest count start when
        /// no sleep was detected in time. The wake-up moved to `occurrence`, which is never later.
        case countingStarted(at: Date, sleepDetected: Bool, occurrence: AlarmOccurrence)
        /// A power nap is about to enter deep sleep: wake now.
        case wakeBeforeDeepSleep
    }

    public let plan: NapPlan
    public let key: String
    public let start: Date
    /// When counting started (sleep onset, or the latest count start).
    public private(set) var countStart: Date?
    public private(set) var sleepDetected = false
    private var detector: SleepOnsetDetector
    private var deepStreak = 0
    private var guardFired = false

    /// - Parameters:
    ///   - countStart: restores a tracker whose counting had already started (resumed sessions).
    public init(plan: NapPlan, key: String, start: Date, countStart: Date? = nil, sleepDetected: Bool = false, detector: SleepOnsetDetector = SleepOnsetDetector()) {
        self.plan = plan
        self.key = key
        self.start = start
        self.countStart = countStart.map { min(max($0, start), plan.latestCountStart(start: start)) }
        self.sleepDetected = countStart != nil && sleepDetected
        self.detector = detector
    }

    public var occurrence: AlarmOccurrence {
        plan.occurrence(key: key, start: start, onset: countStart)
    }

    public mutating func update(epochStart: Date, estimate: OnlineEstimate) -> Update {
        let latest = plan.latestCountStart(start: start)
        guard let countStart else {
            if let detected = detector.update(epochStart: epochStart, estimate: estimate) {
                let begin = min(detected, latest)
                self.countStart = begin
                sleepDetected = true
                return .countingStarted(at: begin, sleepDetected: true, occurrence: occurrence)
            }
            if epochStart.addingTimeInterval(SleepConstants.epochLength) >= latest {
                self.countStart = latest
                return .countingStarted(at: latest, sleepDetected: false, occurrence: occurrence)
            }
            return .none
        }
        guard plan.wakesBeforeDeepSleep, !guardFired, estimate.hasData else { return .none }
        if estimate.probabilities.deep >= plan.deepSleepProbability {
            deepStreak += 1
        } else {
            deepStreak = 0
        }
        let asleepFor = epochStart.addingTimeInterval(SleepConstants.epochLength).timeIntervalSince(countStart)
        if asleepFor >= plan.minimumSleepBeforeGuard && deepStreak >= plan.deepSleepEpochs {
            guardFired = true
            return .wakeBeforeDeepSleep
        }
        return .none
    }
}
