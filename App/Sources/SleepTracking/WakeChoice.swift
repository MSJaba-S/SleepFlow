import SwiftUI
import SleepCore

/// How the user wants to be woken from this session.
enum WakeChoice: Hashable, Sendable {
    /// The regular alarm at a clock time, with its Smart Alarm window.
    case clock
    /// After a power nap or whole sleep cycles, counted from the moment of falling asleep.
    case afterSleep(NapPreset)

    var napPreset: NapPreset? {
        if case .afterSleep(let preset) = self { return preset }
        return nil
    }
}

/// The "wake after sleep" options offered in the app.
enum NapPreset: String, CaseIterable, Identifiable, Sendable {
    case powerNap20
    case powerNap30
    case cycles1
    case cycles2
    case cycles3
    case cycles4
    case cycles5

    var id: String { rawValue }

    var plan: NapPlan {
        switch self {
        case .powerNap20: return .powerNap(minutes: 20)
        case .powerNap30: return .powerNap(minutes: 30)
        case .cycles1: return .cycles(1)
        case .cycles2: return .cycles(2)
        case .cycles3: return .cycles(3)
        case .cycles4: return .cycles(4)
        case .cycles5: return .cycles(5)
        }
    }

    var isPowerNap: Bool { plan.wakesBeforeDeepSleep }

    var title: LocalizedStringKey {
        switch self {
        case .powerNap20, .powerNap30: return "Power nap"
        case .cycles1: return "1 sleep cycle"
        case .cycles2: return "2 sleep cycles"
        case .cycles3: return "3 sleep cycles"
        case .cycles4: return "4 sleep cycles"
        case .cycles5: return "5 sleep cycles"
        }
    }

    /// "20 min", "1h 30m" …
    var durationText: String {
        Formatters.span(minutes: plan.sleepDuration / 60)
    }

    var detail: LocalizedStringKey {
        switch self {
        case .powerNap20:
            return "Short and refreshing. Ends before deep sleep normally begins."
        case .powerNap30:
            return "A little longer. If deep sleep begins first, SleepFlow wakes you right away."
        case .cycles1:
            return "One full cycle of about 90 minutes. Wakes you in the light phase at the end."
        default:
            return "Whole cycles of about 90 minutes, so you wake in a light phase."
        }
    }

    var symbol: String {
        isPowerNap ? "bolt.fill" : "moon.zzz.fill"
    }

    static func from(rawValue: String) -> NapPreset {
        NapPreset(rawValue: rawValue) ?? .powerNap20
    }
}
