import Foundation
import SleepModels
import SleepScoring
import SmartAlarm
import MotionAnalysis

/// Written once when a session starts.
public struct SessionHeader: Codable, Sendable, Hashable {
    public var id: UUID
    public var start: Date
    public var method: TrackingMethod
    public var alarm: AlarmOccurrence?
    public var smartAlarmEnabled: Bool
    public var sleepGoal: TimeInterval
    /// Produced by the simulator (tests, demo) rather than real sensors.
    public var isSimulated: Bool
    public var algorithmVersion: String
    public var appVersion: String
    public var timeZoneIdentifier: String
    /// Set when the user chose "wake after sleep" (power nap or sleep cycles) for this session.
    public var napPlan: NapPlan?

    public init(
        id: UUID = UUID(),
        start: Date,
        method: TrackingMethod,
        alarm: AlarmOccurrence?,
        smartAlarmEnabled: Bool,
        sleepGoal: TimeInterval,
        isSimulated: Bool,
        algorithmVersion: String = SleepConstants.algorithmVersion,
        appVersion: String,
        timeZoneIdentifier: String,
        napPlan: NapPlan? = nil
    ) {
        self.id = id
        self.start = start
        self.method = method
        self.alarm = alarm
        self.smartAlarmEnabled = smartAlarmEnabled
        self.sleepGoal = sleepGoal
        self.isSimulated = isSimulated
        self.algorithmVersion = algorithmVersion
        self.appVersion = appVersion
        self.timeZoneIdentifier = timeZoneIdentifier
        self.napPlan = napPlan
    }
}

public enum MarkerKind: String, Codable, Sendable, CaseIterable {
    case trackingInterrupted
    case trackingResumed
    case playbackStarted
    case playbackStopped
    case smartAlarmTriggered
    case alarmRang
    case alarmStopped
    case snoozed
    case thermalWarning
    case lowBattery
    case batteryLevel
    case recovered
    case microphoneUnavailable
    case ended
    /// Nap: counting started at this time (detail "sleep" when sleep onset was detected,
    /// "latest" when no sleep was detected in time).
    case napCountingStarted
}

/// Something that happened to the tracking process itself (not to the sleeper).
public struct SessionMarker: Codable, Sendable, Hashable {
    public var time: Date
    public var kind: MarkerKind
    public var detail: String?

    public init(time: Date, kind: MarkerKind, detail: String? = nil) {
        self.time = time
        self.kind = kind
        self.detail = detail
    }
}

/// A period without sensor data.
public struct TrackingGap: Codable, Sendable, Hashable {
    public var start: Date
    public var end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }
}

/// Wake-up information of a finished session.
public struct WakeUpRecord: Codable, Sendable, Hashable {
    public var deadline: Date?
    public var windowStart: Date?
    public var alarmTime: Date?
    public var reason: WakeReason?
    public var snoozeCount: Int
    /// Nap: when counting started (sleep onset, or the latest count start).
    public var countedFrom: Date?
    /// Nap: true when counting started from detected sleep.
    public var sleepDetected: Bool?

    public init(deadline: Date?, windowStart: Date?, alarmTime: Date?, reason: WakeReason?, snoozeCount: Int, countedFrom: Date? = nil, sleepDetected: Bool? = nil) {
        self.deadline = deadline
        self.windowStart = windowStart
        self.alarmTime = alarmTime
        self.reason = reason
        self.snoozeCount = snoozeCount
        self.countedFrom = countedFrom
        self.sleepDetected = sleepDetected
    }

    /// Nap: sleep between the start of counting and the alarm.
    public var napSleep: TimeInterval? {
        guard let countedFrom, let alarmTime else { return nil }
        return max(0, alarmTime.timeIntervalSince(countedFrom))
    }

    /// Minutes the Smart Alarm woke the user before the deadline.
    public var minutesBeforeDeadline: Double? {
        guard let deadline, let alarmTime else { return nil }
        return max(0, deadline.timeIntervalSince(alarmTime) / 60)
    }
}

/// A fully analysed night, ready to be stored.
public struct CompletedSession: Codable, Sendable, Hashable, Identifiable {
    public var header: SessionHeader
    public var end: Date
    public var epochs: [EpochFeatures]
    public var hypnogram: Hypnogram
    public var metrics: SleepMetrics
    public var score: SleepScore
    public var insights: [SleepInsight]
    public var suggestions: [SuggestionKind]
    public var soundEvents: [SoundEvent]
    public var movementEvents: [MovementEvent]
    public var movementPatterns: [RepeatedMovementPattern]
    public var markers: [SessionMarker]
    public var gaps: [TrackingGap]
    public var wakeUp: WakeUpRecord
    public var previousScore: Int?
    /// Fraction of epochs with loud environmental disturbances.
    public var noisyEpochFraction: Double

    public init(
        header: SessionHeader,
        end: Date,
        epochs: [EpochFeatures],
        hypnogram: Hypnogram,
        metrics: SleepMetrics,
        score: SleepScore,
        insights: [SleepInsight],
        suggestions: [SuggestionKind],
        soundEvents: [SoundEvent],
        movementEvents: [MovementEvent],
        movementPatterns: [RepeatedMovementPattern],
        markers: [SessionMarker],
        gaps: [TrackingGap],
        wakeUp: WakeUpRecord,
        previousScore: Int?,
        noisyEpochFraction: Double
    ) {
        self.header = header
        self.end = end
        self.epochs = epochs
        self.hypnogram = hypnogram
        self.metrics = metrics
        self.score = score
        self.insights = insights
        self.suggestions = suggestions
        self.soundEvents = soundEvents
        self.movementEvents = movementEvents
        self.movementPatterns = movementPatterns
        self.markers = markers
        self.gaps = gaps
        self.wakeUp = wakeUp
        self.previousScore = previousScore
        self.noisyEpochFraction = noisyEpochFraction
    }

    public var id: UUID { header.id }
}
