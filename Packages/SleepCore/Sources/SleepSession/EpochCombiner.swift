import Foundation
import SleepModels
import AudioAnalysis
import MotionAnalysis

/// Merges the acoustic and the motion summaries of the same epoch into `EpochFeatures`.
///
/// The pipelines finish epochs at slightly different times. An epoch is emitted when the primary
/// source (microphone or accelerometer, depending on the method) has delivered it and either the
/// secondary source has too, is not running, or is more than `maximumWait` epochs behind.
public struct EpochCombiner: Sendable {
    public let sessionStart: Date
    public let method: TrackingMethod
    public var secondaryExpected: Bool
    public var maximumWait: Int

    private var acoustic: [Int: AcousticEpochSummary] = [:]
    private var motion: [Int: MotionEpochSummary] = [:]
    private var emittedThrough = -1

    public init(sessionStart: Date, method: TrackingMethod, secondaryExpected: Bool, maximumWait: Int = 2) {
        self.sessionStart = sessionStart
        self.method = method
        self.secondaryExpected = secondaryExpected
        self.maximumWait = maximumWait
    }

    public var lastEmittedIndex: Int { emittedThrough }

    public mutating func add(_ summary: AcousticEpochSummary) -> [EpochFeatures] {
        guard summary.epochIndex > emittedThrough else { return [] }
        acoustic[summary.epochIndex] = summary
        return drain(force: false)
    }

    public mutating func add(_ summary: MotionEpochSummary) -> [EpochFeatures] {
        guard summary.epochIndex > emittedThrough else { return [] }
        motion[summary.epochIndex] = summary
        return drain(force: false)
    }

    /// Emits everything that is pending, for example when the session ends.
    public mutating func flush() -> [EpochFeatures] {
        drain(force: true)
    }

    private func hasPrimary(_ index: Int) -> Bool {
        method == .microphone ? acoustic[index] != nil : motion[index] != nil
    }

    private func hasSecondary(_ index: Int) -> Bool {
        method == .microphone ? motion[index] != nil : acoustic[index] != nil
    }

    private mutating func drain(force: Bool) -> [EpochFeatures] {
        let indices = Set(acoustic.keys).union(motion.keys).sorted()
        guard let latest = indices.last else { return [] }
        var output: [EpochFeatures] = []
        for index in indices where index > emittedThrough {
            let ready: Bool
            if force {
                ready = true
            } else if hasPrimary(index) {
                ready = !secondaryExpected || hasSecondary(index) || latest >= index + maximumWait
            } else {
                ready = latest >= index + maximumWait + 1
            }
            guard ready else { break }
            output.append(combine(index))
            acoustic[index] = nil
            motion[index] = nil
            emittedThrough = index
        }
        return output
    }

    func combine(_ index: Int) -> EpochFeatures {
        let a = acoustic[index]
        let m = motion[index]
        return EpochFeatures(
            index: index,
            start: sessionStart.addingTimeInterval(Double(index) * SleepConstants.epochLength),
            audioCoverage: min(1, (a?.coveredSeconds ?? 0) / SleepConstants.epochLength),
            motionCoverage: min(1, (m?.coveredSeconds ?? 0) / SleepConstants.epochLength),
            movementActivity: m?.activity ?? 0,
            movementEventCount: m?.movementCount ?? 0,
            largeMovementCount: m?.largeMovementCount ?? 0,
            soundActivity: a?.soundActivity ?? 0,
            meanDecibels: a?.meanDecibels,
            noiseFloorDecibels: a?.noiseFloorDecibels,
            maxDecibels: a?.maxDecibels,
            snoreSeconds: a?.snoreSeconds ?? 0,
            talkSeconds: a?.talkSeconds ?? 0,
            coughCount: a?.coughCount ?? 0,
            disturbanceCount: a?.disturbanceCount ?? 0,
            breathingRate: a?.breathingRate,
            breathingRegularity: a?.breathingRegularity ?? 0,
            pickup: m?.pickup ?? false,
            playbackMasked: a?.masked ?? false
        )
    }
}

public enum TrackingPhase: String, Codable, Sendable, CaseIterable {
    case idle
    case starting
    case tracking
    case alarmRinging
    case snoozing
    case finishing
    case finished
}

public enum TrackingTrigger: String, Codable, Sendable, CaseIterable {
    case start
    case started
    case failed
    case alarmFired
    case snooze
    case stop
    case finished
    case reset
    case recover
}

/// The session lifecycle as an explicit state machine, so invalid sequences (stopping twice,
/// snoozing without an alarm) are rejected instead of corrupting a night.
public struct TrackingLifecycle: Sendable, Equatable {
    public private(set) var phase: TrackingPhase

    public init(phase: TrackingPhase = .idle) {
        self.phase = phase
    }

    public var isActive: Bool {
        switch phase {
        case .tracking, .alarmRinging, .snoozing: return true
        case .idle, .starting, .finishing, .finished: return false
        }
    }

    public static func next(from phase: TrackingPhase, on trigger: TrackingTrigger) -> TrackingPhase? {
        switch (phase, trigger) {
        case (.idle, .start), (.finished, .start): return .starting
        case (.idle, .recover): return .tracking
        case (.starting, .started): return .tracking
        case (.starting, .failed): return .idle
        case (.tracking, .alarmFired), (.snoozing, .alarmFired): return .alarmRinging
        case (.alarmRinging, .snooze): return .snoozing
        case (.tracking, .stop), (.alarmRinging, .stop), (.snoozing, .stop): return .finishing
        case (.finishing, .finished): return .finished
        case (.finishing, .failed): return .finished
        case (.finished, .reset): return .idle
        default: return nil
        }
    }

    /// Applies the trigger. Returns `false` and keeps the phase when the transition is invalid.
    @discardableResult
    public mutating func handle(_ trigger: TrackingTrigger) -> Bool {
        guard let next = TrackingLifecycle.next(from: phase, on: trigger) else { return false }
        phase = next
        return true
    }
}
