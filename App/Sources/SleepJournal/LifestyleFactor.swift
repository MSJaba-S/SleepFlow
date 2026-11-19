import SwiftUI

/// Things the user can log for the day before a night. Stored in the journal by raw value, so
/// cases may be added later without a migration; unknown values are shown as they are.
enum LifestyleFactor: String, CaseIterable, Identifiable, Sendable {
    case caffeine
    case alcohol
    case lateMeal
    case exercise
    case lateExercise
    case stress
    case screens
    case nap
    case reading
    case meditation
    case travel
    case sick
    case noise
    case warmRoom

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .caffeine: return "Caffeine after 14:00"
        case .alcohol: return "Alcohol"
        case .lateMeal: return "Late meal"
        case .exercise: return "Exercise"
        case .lateExercise: return "Exercise in the evening"
        case .stress: return "Stressful day"
        case .screens: return "Screens in bed"
        case .nap: return "Nap during the day"
        case .reading: return "Read before sleep"
        case .meditation: return "Relaxation or meditation"
        case .travel: return "Travel"
        case .sick: return "Feeling ill"
        case .noise: return "Noisy surroundings"
        case .warmRoom: return "Warm bedroom"
        }
    }

    var symbol: String {
        switch self {
        case .caffeine: return "cup.and.saucer"
        case .alcohol: return "wineglass"
        case .lateMeal: return "fork.knife"
        case .exercise: return "figure.run"
        case .lateExercise: return "dumbbell"
        case .stress: return "bolt.heart"
        case .screens: return "iphone"
        case .nap: return "zzz"
        case .reading: return "book"
        case .meditation: return "figure.mind.and.body"
        case .travel: return "airplane"
        case .sick: return "thermometer.medium"
        case .noise: return "speaker.wave.3"
        case .warmRoom: return "thermometer.sun"
        }
    }

    /// Label for a stored raw value (also for values written by a newer app version).
    static func label(forRaw raw: String) -> Text {
        if let factor = LifestyleFactor(rawValue: raw) {
            return Text(factor.title)
        }
        return Text(verbatim: raw)
    }

    static func symbol(forRaw raw: String) -> String {
        LifestyleFactor(rawValue: raw)?.symbol ?? "tag"
    }
}
