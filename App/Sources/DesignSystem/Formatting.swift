import Foundation
import SwiftUI
import SleepCore

/// Locale-aware formatting. Uses the system's format styles so Danish and English read naturally.
enum Formatters {
    /// "7h 32m" / "7t 32m"
    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let duration = Duration.seconds(total - total % 60)
        if total < 60 {
            return Duration.seconds(total).formatted(.units(allowed: [.seconds], width: .narrow))
        }
        return duration.formatted(.units(allowed: [.hours, .minutes], width: .narrow))
    }

    /// "7:32" for compact tiles.
    static func clockDuration(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int((seconds / 60).rounded()))
        let hours = minutes / 60
        let rest = minutes % 60
        return "\(hours):" + (rest < 10 ? "0" : "") + "\(rest)"
    }

    static func minutes(_ seconds: TimeInterval) -> String {
        Duration.seconds(max(0, Int((seconds / 60).rounded()) * 60)).formatted(.units(allowed: [.minutes], width: .abbreviated))
    }

    /// A span given in minutes: "12 min" below an hour, "1h 05m" style above. Never "0".
    static func span(minutes: Double) -> String {
        let rounded = max(1, minutes.rounded())
        return rounded < 60 ? self.minutes(rounded * 60) : duration(rounded * 60)
    }

    /// "23:12–07:04"
    static func timeRange(_ start: Date, _ end: Date) -> String {
        "\(time(start))–\(time(end))"
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    static func dayAndDate(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    static func shortDate(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated))
    }

    static func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)))
    }

    /// Minutes since midnight → "23:45".
    static func clock(minutes: Double) -> String {
        let normalised = (Int(minutes.rounded()) % 1_440 + 1_440) % 1_440
        var components = DateComponents()
        components.hour = normalised / 60
        components.minute = normalised % 60
        let date = Calendar.current.date(from: components) ?? Date()
        return time(date)
    }

    static func signed(_ value: Int) -> String {
        value > 0 ? "+\(value)" : "\(value)"
    }
}

extension SleepStage {
    var title: LocalizedStringKey {
        switch self {
        case .awake: return "Awake"
        case .light: return "Light sleep"
        case .deep: return "Deep sleep"
        }
    }

    var shortTitle: LocalizedStringKey {
        switch self {
        case .awake: return "Awake"
        case .light: return "Light"
        case .deep: return "Deep"
        }
    }
}

extension TrackingMethod {
    var title: LocalizedStringKey {
        switch self {
        case .microphone: return "Microphone"
        case .motion: return "Movement"
        }
    }

    var symbol: String {
        switch self {
        case .microphone: return "waveform"
        case .motion: return "bed.double"
        }
    }

    var summary: LocalizedStringKey {
        switch self {
        case .microphone:
            return "Recommended. Detects snoring, coughing and sleep talking. Works with the screen locked."
        case .motion:
            return "No microphone. Measures how you move with the phone on the mattress. SleepFlow stays open during the night."
        }
    }

    var placement: LocalizedStringKey {
        switch self {
        case .microphone:
            return "Place the phone on the bedside table, within about one metre of your head, with the microphone free. Plug in the charger. Tracking continues with the screen locked."
        case .motion:
            return "Place the phone face down on the mattress next to your pillow, not under it. Plug in the charger. Keep SleepFlow open: iOS pauses motion tracking when another app is used or the phone is locked."
        }
    }
}

extension SoundEventType {
    var title: LocalizedStringKey {
        switch self {
        case .snoring: return "Snoring"
        case .coughing: return "Coughing"
        case .talking: return "Sleep talking"
        case .movement: return "Movement sounds"
        case .disturbance: return "Disturbance"
        case .breathing: return "Breathing"
        case .unknown: return "Other sound"
        }
    }

    var symbol: String {
        switch self {
        case .snoring: return "zzz"
        case .coughing: return "lungs"
        case .talking: return "text.bubble"
        case .movement: return "figure.roll"
        case .disturbance: return "speaker.wave.3"
        case .breathing: return "wind"
        case .unknown: return "questionmark.circle"
        }
    }
}

extension ScoreQuality {
    var title: LocalizedStringKey {
        switch self {
        case .excellent: return "Excellent"
        case .good: return "Good"
        case .fair: return "Fair"
        case .poor: return "Poor"
        case .bad: return "Very poor"
        }
    }
}

extension ScoreFactor {
    var title: LocalizedStringKey {
        switch self {
        case .duration: return "Sleep duration"
        case .efficiency: return "Sleep efficiency"
        case .latency: return "Time to fall asleep"
        case .interruptions: return "Interruptions"
        case .restlessness: return "Restlessness"
        case .consistency: return "Regular schedule"
        }
    }

    var symbol: String {
        switch self {
        case .duration: return "clock"
        case .efficiency: return "gauge.with.dots.needle.67percent"
        case .latency: return "moon.zzz"
        case .interruptions: return "exclamationmark.bubble"
        case .restlessness: return "figure.roll"
        case .consistency: return "calendar"
        }
    }

    /// Human-readable measured value of a score component.
    func measuredText(_ value: Double) -> String {
        switch self {
        case .duration: return Formatters.duration(value)
        case .efficiency, .restlessness: return Formatters.percent(value)
        case .latency: return Formatters.minutes(value)
        case .interruptions: return "\(Int(value))"
        case .consistency: return Formatters.minutes(value * 60)
        }
    }
}

extension WakeReason {
    var title: LocalizedStringKey {
        switch self {
        case .lightSleep: return "Woken in light sleep"
        case .alreadyAwake: return "You were already awake"
        case .nearDeadline: return "Woken just before your alarm time"
        case .deadline: return "Woken at your alarm time"
        }
    }
}
