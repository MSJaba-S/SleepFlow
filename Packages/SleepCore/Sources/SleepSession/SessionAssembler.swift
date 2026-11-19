import Foundation
import SleepModels
import SleepIntelligence
import SleepScoring
import SmartAlarm
import MotionAnalysis

public struct SessionAssemblyInput: Sendable {
    public var header: SessionHeader
    public var end: Date
    public var epochs: [EpochFeatures]
    public var soundEvents: [SoundEvent]
    public var movementEvents: [MovementEvent]
    public var markers: [SessionMarker]
    public var history: [HistoricalNight]
    public var previousScore: Int?
    public var weights: ScoreWeights
    public var calendar: Calendar

    public init(
        header: SessionHeader,
        end: Date,
        epochs: [EpochFeatures],
        soundEvents: [SoundEvent],
        movementEvents: [MovementEvent],
        markers: [SessionMarker],
        history: [HistoricalNight] = [],
        previousScore: Int? = nil,
        weights: ScoreWeights = .standard,
        calendar: Calendar = .current
    ) {
        self.header = header
        self.end = end
        self.epochs = epochs
        self.soundEvents = soundEvents
        self.movementEvents = movementEvents
        self.markers = markers
        self.history = history
        self.previousScore = previousScore
        self.weights = weights
        self.calendar = calendar
    }
}

/// Turns the raw material of a night (epochs, events, markers) into a `CompletedSession`:
/// fills gaps, estimates sleep states, computes metrics, score, insights and wake-up details.
public enum SessionAssembler {
    public static func assemble(_ input: SessionAssemblyInput) -> CompletedSession {
        let header = input.header
        let end = max(input.end, header.start.addingTimeInterval(SleepConstants.epochLength))
        let epochCount = Int((end.timeIntervalSince(header.start) / SleepConstants.epochLength).rounded(.up))
        var epochs = input.epochs.filter { $0.index < epochCount }.filledGaps(sessionStart: header.start, count: epochCount)
        if epochs.count > epochCount { epochs = Array(epochs.prefix(epochCount)) }

        let stager = SleepStager()
        let hypnogram = stager.stage(epochs: epochs, method: header.method, sessionStart: header.start)
        let soundEvents = input.soundEvents.filter { $0.start >= header.start && $0.start <= end }.sorted { $0.start < $1.start }
        let movementEvents = input.movementEvents.filter { $0.start >= header.start && $0.start <= end }.sorted { $0.start < $1.start }
        let metrics = SleepMetricsCalculator.metrics(
            hypnogram: hypnogram,
            epochs: epochs,
            soundEvents: soundEvents,
            movementEvents: movementEvents,
            sessionEnd: end
        )
        let targets = ScoreTargets(sleepGoal: header.sleepGoal)
        let score = SleepScoreCalculator(weights: input.weights).score(metrics: metrics, targets: targets, history: input.history, calendar: input.calendar)

        let audioEpochs = epochs.filter { $0.audioCoverage >= 0.5 }
        let noisy = audioEpochs.isEmpty ? 0 : Double(audioEpochs.filter { $0.disturbanceCount > 0 }.count) / Double(audioEpochs.count)
        let insights = InsightEngine.insights(score: score, metrics: metrics, targets: targets, previousScore: input.previousScore, noisyEpochFraction: noisy)
        let suggestions = InsightEngine.suggestions(score: score, metrics: metrics, targets: targets, noisyEpochFraction: noisy)
        let patterns = MovementPatternDetector.detect(events: movementEvents)

        return CompletedSession(
            header: header,
            end: end,
            epochs: epochs,
            hypnogram: hypnogram,
            metrics: metrics,
            score: score,
            insights: insights,
            suggestions: suggestions,
            soundEvents: soundEvents,
            movementEvents: movementEvents,
            movementPatterns: patterns,
            markers: input.markers.sorted { $0.time < $1.time },
            gaps: gaps(epochs: epochs, method: header.method),
            wakeUp: wakeUp(header: header, markers: input.markers),
            previousScore: input.previousScore,
            noisyEpochFraction: noisy
        )
    }

    /// Runs of at least two epochs (one minute) without data for the primary sensor.
    public static func gaps(epochs: [EpochFeatures], method: TrackingMethod) -> [TrackingGap] {
        var result: [TrackingGap] = []
        var runStart: Int?
        for (position, epoch) in epochs.enumerated() {
            if !epoch.hasData(for: method) {
                if runStart == nil { runStart = position }
            } else if let start = runStart {
                if position - start >= 2 {
                    result.append(TrackingGap(start: epochs[start].start, end: epoch.start))
                }
                runStart = nil
            }
        }
        if let start = runStart, epochs.count - start >= 2, let last = epochs.last {
            result.append(TrackingGap(start: epochs[start].start, end: last.end))
        }
        return result
    }

    public static func wakeUp(header: SessionHeader, markers: [SessionMarker]) -> WakeUpRecord {
        let sorted = markers.sorted { $0.time < $1.time }
        let firstAlarm = sorted.first { $0.kind == .smartAlarmTriggered || $0.kind == .alarmRang }
        let reason: WakeReason?
        if let marker = firstAlarm, marker.kind == .smartAlarmTriggered, let detail = marker.detail {
            reason = WakeReason(rawValue: detail)
        } else if firstAlarm != nil {
            reason = .deadline
        } else {
            reason = nil
        }
        let counting = sorted.first { $0.kind == .napCountingStarted }
        return WakeUpRecord(
            deadline: header.alarm?.deadline,
            windowStart: header.alarm?.windowStart,
            alarmTime: firstAlarm?.time,
            reason: reason,
            snoozeCount: sorted.filter { $0.kind == .snoozed }.count,
            countedFrom: counting?.time,
            sleepDetected: counting.map { $0.detail == "sleep" }
        )
    }
}

public extension CompletedSession {
    /// The night with a new score weighting. Insights and suggestions are derived again because
    /// they depend on which factors cost the most points.
    func rescored(with weights: ScoreWeights, previousScore: Int?) -> CompletedSession {
        var copy = self
        copy.score = score.reweighted(weights)
        copy.previousScore = previousScore
        let targets = ScoreTargets(sleepGoal: header.sleepGoal)
        copy.insights = InsightEngine.insights(score: copy.score, metrics: metrics, targets: targets, previousScore: previousScore, noisyEpochFraction: noisyEpochFraction)
        copy.suggestions = InsightEngine.suggestions(score: copy.score, metrics: metrics, targets: targets, noisyEpochFraction: noisyEpochFraction)
        return copy
    }
}
