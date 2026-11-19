import SwiftUI
import SleepCore

extension SleepInsight {
    /// One localised sentence explaining the finding, with its number.
    var text: Text {
        switch kind {
        case .lowCoverage:
            return Text("Only \(Formatters.percent(value / 100)) of the night was measured, so these results are less certain.")
        case .goalReached:
            return Text("You slept \(Formatters.span(minutes: value)) and reached your sleep goal.")
        case .shortSleep:
            return Text("You slept \(Formatters.span(minutes: value)) less than your goal.")
        case .longLatency:
            return Text("It took about \(Formatters.span(minutes: value)) to fall asleep.")
        case .quickOnset:
            return Text("You fell asleep quickly, in about \(Formatters.span(minutes: value)).")
        case .fragmentedSleep:
            return Text("Your sleep was broken up. Interruptions: \(Int(value.rounded())).")
        case .restless:
            return Text("A restless night: there was movement in \(Formatters.percent(value / 100)) of your sleep.")
        case .calm:
            return Text("A calm night: you lay still most of the time.")
        case .irregularSchedule:
            return Text("Your bed and wake times were about \(Formatters.span(minutes: value)) off your usual rhythm.")
        case .regularSchedule:
            return Text("A regular rhythm: within \(Formatters.span(minutes: value)) of your usual times.")
        case .highEfficiency:
            return Text("High sleep efficiency: you were asleep \(Formatters.percent(value / 100)) of the time in bed.")
        case .snoring:
            return Text("Snoring was detected for about \(Formatters.span(minutes: value)).")
        case .noisyRoom:
            return Text("Loud sounds disturbed \(Formatters.percent(value / 100)) of the night.")
        case .betterThanPrevious:
            return Text("Your score is up by \(Int(value.rounded())) since the previous night.")
        case .worseThanPrevious:
            return Text("Your score is down by \(Int(value.rounded())) since the previous night.")
        }
    }

    var symbol: String {
        switch kind {
        case .lowCoverage: return "exclamationmark.triangle"
        case .goalReached: return "target"
        case .shortSleep: return "hourglass.bottomhalf.filled"
        case .longLatency: return "moon.zzz"
        case .quickOnset: return "bolt"
        case .fragmentedSleep: return "exclamationmark.bubble"
        case .restless: return "figure.roll"
        case .calm: return "leaf"
        case .irregularSchedule: return "calendar.badge.exclamationmark"
        case .regularSchedule: return "calendar.badge.checkmark"
        case .highEfficiency: return "gauge.with.dots.needle.67percent"
        case .snoring: return "zzz"
        case .noisyRoom: return "speaker.wave.3"
        case .betterThanPrevious: return "arrow.up.right"
        case .worseThanPrevious: return "arrow.down.right"
        }
    }
}

extension SuggestionKind {
    var title: LocalizedStringKey {
        switch self {
        case .keepRoutine: return "Keep your routine"
        case .earlierBedtime: return "Go to bed a little earlier"
        case .windDown: return "Wind down before bed"
        case .consistentSchedule: return "Keep regular times"
        case .limitCaffeine: return "Watch caffeine and alcohol"
        case .quieterRoom: return "Make the bedroom quieter"
        case .snoringPosition: return "Try sleeping on your side"
        case .checkPlacement: return "Check the phone's placement"
        case .limitScreens: return "Put screens away earlier"
        case .morningLight: return "Get daylight in the morning"
        }
    }

    var detail: LocalizedStringKey {
        switch self {
        case .keepRoutine:
            return "The night went well. Going to bed and getting up at similar times keeps it that way."
        case .earlierBedtime:
            return "Moving your bedtime 15–30 minutes earlier brings you closer to your sleep goal."
        case .windDown:
            return "Spend the last half hour before bed on something calm: dim light, reading or a breathing exercise."
        case .consistentSchedule:
            return "The same bed and wake times every day – also at weekends – make falling asleep and waking up easier."
        case .limitCaffeine:
            return "Caffeine in the afternoon and alcohol in the evening can make sleep lighter and more broken."
        case .quieterRoom:
            return "Sounds disturbed your sleep. Earplugs, a closed window or a steady background sound can help."
        case .snoringPosition:
            return "Snoring is often less on your side. If it is loud or you wake up unrested, talk to your doctor."
        case .checkPlacement:
            return "Parts of the night were not measured. Keep the phone charging and placed as described before you start."
        case .limitScreens:
            return "Bright screens and exciting content late in the evening can delay sleep."
        case .morningLight:
            return "Daylight soon after waking helps your body clock keep a steady rhythm."
        }
    }

    var symbol: String {
        switch self {
        case .keepRoutine: return "checkmark.seal"
        case .earlierBedtime: return "bed.double"
        case .windDown: return "wind"
        case .consistentSchedule: return "calendar"
        case .limitCaffeine: return "cup.and.saucer"
        case .quieterRoom: return "ear"
        case .snoringPosition: return "person.fill.turn.right"
        case .checkPlacement: return "iphone.gen3"
        case .limitScreens: return "iphone.slash"
        case .morningLight: return "sun.max"
        }
    }
}

extension WakeUpRecord {
    /// Sentence describing how the alarm went, or nil when no alarm was set.
    var summary: Text? {
        guard deadline != nil else { return nil }
        guard let alarmTime, let reason else {
            return Text("The night ended before the alarm.")
        }
        let time = Formatters.time(alarmTime)
        switch reason {
        case .lightSleep:
            let early = Formatters.span(minutes: minutesBeforeDeadline ?? 0)
            return Text("Woken at \(time) in light sleep, \(early) before your alarm time.")
        case .alreadyAwake:
            return Text("You were already awake at \(time), so the alarm rang a little early.")
        case .nearDeadline:
            return Text("Woken at \(time), just before your alarm time.")
        case .deadline:
            return Text("Woken at \(time), your alarm time.")
        case .beforeDeepSleep:
            return Text("Woken at \(time) just as deep sleep began, so you would not wake up groggy.")
        }
    }
}
