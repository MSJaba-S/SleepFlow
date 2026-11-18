import Foundation
import SleepModels

/// Derives night statistics (sleep onset, total sleep, efficiency, interruptions …) from a hypnogram.
public enum SleepMetricsCalculator {
    /// Epochs (10 min) used to confirm sleep onset; at most `onsetTolerance` of them may be awake.
    public static let onsetWindow = 20
    public static let onsetTolerance = 2
    /// An awakening must last at least this many epochs (2 min) to count as an interruption.
    public static let interruptionEpochs = 4

    public static func metrics(
        hypnogram: Hypnogram,
        epochs: [EpochFeatures],
        soundEvents: [SoundEvent],
        movementEvents: [MovementEvent],
        sessionEnd: Date
    ) -> SleepMetrics {
        let stages = hypnogram.stages
        let length = hypnogram.epochLength
        let sessionStart = hypnogram.start
        let timeInBed = max(0, sessionEnd.timeIntervalSince(sessionStart))
        let counts = Dictionary(grouping: soundEvents, by: { $0.type.rawValue }).mapValues(\.count)
        let snoring = soundEvents.filter { $0.type == .snoring }.reduce(0) { $0 + $1.duration }
        let coverage = hypnogram.hasData.isEmpty ? 0 : Double(hypnogram.hasData.filter { $0 }.count) / Double(hypnogram.hasData.count)
        let hours = max(timeInBed / 3600, 1.0 / 60)
        let movementsPerHour = Double(movementEvents.filter { $0.kind != .pickup }.count) / hours

        guard let onsetIndex = sleepOnsetIndex(stages) else {
            return SleepMetrics(
                sessionStart: sessionStart,
                sessionEnd: sessionEnd,
                sleepOnset: nil,
                finalAwakening: nil,
                timeInBed: timeInBed,
                totalSleep: 0,
                sleepLatency: nil,
                wakeAfterSleepOnset: 0,
                awakeTime: timeInBed,
                efficiency: 0,
                interruptions: 0,
                lightSleep: 0,
                deepSleep: 0,
                restlessness: 0,
                movementEventsPerHour: movementsPerHour,
                dataCoverage: coverage,
                snoringDuration: snoring,
                soundEventCounts: counts
            )
        }
        let lastSleepIndex = stages.lastIndex { $0 != .awake } ?? onsetIndex

        var sleepEpochs = 0
        var wakeEpochs = 0
        var light = 0
        var deep = 0
        var restless = 0
        for index in onsetIndex...lastSleepIndex {
            switch stages[index] {
            case .awake:
                wakeEpochs += 1
            case .light:
                sleepEpochs += 1
                light += 1
            case .deep:
                sleepEpochs += 1
                deep += 1
            }
            if stages[index] != .awake, index < epochs.count {
                let epoch = epochs[index]
                if epoch.movementEventCount > 0 || epoch.soundActivity >= 1.5 || epoch.largeMovementCount > 0 {
                    restless += 1
                }
            }
        }

        var interruptions = 0
        var awakeRun = 0
        if lastSleepIndex > onsetIndex {
            for index in onsetIndex...lastSleepIndex {
                if stages[index] == .awake {
                    awakeRun += 1
                } else {
                    if awakeRun >= interruptionEpochs { interruptions += 1 }
                    awakeRun = 0
                }
            }
        }

        let onset = hypnogram.epochStart(onsetIndex)
        let finalAwakening = min(hypnogram.epochStart(lastSleepIndex + 1), sessionEnd)
        let totalSleep = min(Double(sleepEpochs) * length, timeInBed)
        let waso = Double(wakeEpochs) * length
        return SleepMetrics(
            sessionStart: sessionStart,
            sessionEnd: sessionEnd,
            sleepOnset: onset,
            finalAwakening: finalAwakening,
            timeInBed: timeInBed,
            totalSleep: totalSleep,
            sleepLatency: onset.timeIntervalSince(sessionStart),
            wakeAfterSleepOnset: waso,
            awakeTime: max(0, timeInBed - totalSleep),
            efficiency: timeInBed > 0 ? Stats.clamp(totalSleep / timeInBed, 0, 1) : 0,
            interruptions: interruptions,
            lightSleep: Double(light) * length,
            deepSleep: Double(deep) * length,
            restlessness: sleepEpochs > 0 ? Double(restless) / Double(sleepEpochs) : 0,
            movementEventsPerHour: movementsPerHour,
            dataCoverage: coverage,
            snoringDuration: snoring,
            soundEventCounts: counts
        )
    }

    /// First epoch of a 10-minute window that is (almost) entirely asleep.
    public static func sleepOnsetIndex(_ stages: [SleepStage]) -> Int? {
        guard !stages.isEmpty else { return nil }
        let window = min(onsetWindow, stages.count)
        guard window >= 4 else {
            return stages.firstIndex { $0 != .awake }
        }
        var awakeInWindow = stages[0..<window].filter { $0 == .awake }.count
        var start = 0
        while true {
            if stages[start] != .awake && awakeInWindow <= onsetTolerance {
                return start
            }
            let next = start + window
            guard next < stages.count else { break }
            if stages[start] == .awake { awakeInWindow -= 1 }
            if stages[next] == .awake { awakeInWindow += 1 }
            start += 1
        }
        // Short nights: accept the first sleep epoch of the remaining tail if mostly asleep.
        let tail = stages[start...]
        if tail.filter({ $0 != .awake }).count >= max(4, tail.count / 2) {
            return stages[start...].firstIndex { $0 != .awake }
        }
        return nil
    }
}
