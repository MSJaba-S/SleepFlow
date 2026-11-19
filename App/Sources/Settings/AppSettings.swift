import Foundation
import Observation
import SleepCore

/// User preferences, persisted in UserDefaults. Personal sleep data lives in SwiftData, not here.
@MainActor
@Observable
final class AppSettings {
    enum Appearance: String, CaseIterable, Identifiable {
        case system, dark, light
        var id: String { rawValue }
    }

    enum LanguageChoice: String, CaseIterable, Identifiable {
        case system, danish = "da", english = "en"
        var id: String { rawValue }
    }

    private enum Key {
        static let onboarding = "settings.onboardingCompleted"
        static let goal = "settings.sleepGoalMinutes"
        static let method = "settings.trackingMethod"
        static let alarm = "settings.alarm"
        static let clips = "settings.saveSoundClips"
        static let model = "settings.useSoundModel"
        static let appearance = "settings.appearance"
        static let language = "settings.language"
        static let demo = "settings.demoMode"
        static let name = "settings.name"
        static let dimScreen = "settings.dimNightScreen"
        static let habits = "settings.wakeHabit"
        static let weights = "settings.scoreWeights"
    }

    private let defaults: UserDefaults

    var hasCompletedOnboarding: Bool { didSet { defaults.set(hasCompletedOnboarding, forKey: Key.onboarding) } }
    /// Personal sleep goal in minutes (used by the score's duration factor).
    var sleepGoalMinutes: Int { didSet { defaults.set(sleepGoalMinutes, forKey: Key.goal) } }
    var trackingMethod: TrackingMethod { didSet { defaults.set(trackingMethod.rawValue, forKey: Key.method) } }
    var alarm: AlarmSettings { didSet { saveAlarm() } }
    /// Off by default: no audio leaves the analysis pipeline unless the user asks for clips.
    var saveSoundClips: Bool { didSet { defaults.set(saveSoundClips, forKey: Key.clips) } }
    /// Use Apple's on-device sound classifier as a second opinion for detected events.
    var useSoundModel: Bool { didSet { defaults.set(useSoundModel, forKey: Key.model) } }
    var appearance: Appearance { didSet { defaults.set(appearance.rawValue, forKey: Key.appearance) } }
    var language: LanguageChoice { didSet { applyLanguage() } }
    var demoMode: Bool { didSet { defaults.set(demoMode, forKey: Key.demo) } }
    var userName: String { didSet { defaults.set(userName, forKey: Key.name) } }
    /// Dim the night screen automatically after a few seconds.
    var dimNightScreen: Bool { didSet { defaults.set(dimNightScreen, forKey: Key.dimScreen) } }
    /// How much each factor counts in the Sleep Score.
    var scoreWeights: ScoreWeights { didSet { saveWeights() } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hasCompletedOnboarding = defaults.bool(forKey: Key.onboarding)
        let goal = defaults.integer(forKey: Key.goal)
        sleepGoalMinutes = goal > 0 ? goal : 480
        trackingMethod = TrackingMethod(rawValue: defaults.string(forKey: Key.method) ?? "") ?? .microphone
        if let data = defaults.data(forKey: Key.alarm), let decoded = try? JSONDecoder().decode(AlarmSettings.self, from: data) {
            alarm = decoded
        } else {
            alarm = AlarmSettings()
        }
        saveSoundClips = defaults.bool(forKey: Key.clips)
        useSoundModel = defaults.object(forKey: Key.model) as? Bool ?? true
        appearance = Appearance(rawValue: defaults.string(forKey: Key.appearance) ?? "") ?? .dark
        language = LanguageChoice(rawValue: defaults.string(forKey: Key.language) ?? "") ?? .system
        demoMode = defaults.bool(forKey: Key.demo)
        userName = defaults.string(forKey: Key.name) ?? ""
        dimNightScreen = defaults.object(forKey: Key.dimScreen) as? Bool ?? true
        if let data = defaults.data(forKey: Key.weights), let decoded = try? JSONDecoder().decode(ScoreWeights.self, from: data), !decoded.isEmpty {
            scoreWeights = decoded
        } else {
            scoreWeights = .standard
        }
    }

    var sleepGoal: TimeInterval { TimeInterval(sleepGoalMinutes * 60) }

    /// Whether the chosen language differs from what the app currently runs in (needs a restart).
    var languageNeedsRestart: Bool {
        guard language != .system else { return false }
        let current = Bundle.main.preferredLocalizations.first ?? "en"
        return !current.hasPrefix(language.rawValue)
    }

    func resetAll() {
        for key in [Key.onboarding, Key.goal, Key.method, Key.alarm, Key.clips, Key.model, Key.appearance, Key.language, Key.demo, Key.name, Key.dimScreen, Key.habits, Key.weights] {
            defaults.removeObject(forKey: key)
        }
        defaults.removeObject(forKey: "AppleLanguages")
        hasCompletedOnboarding = false
        sleepGoalMinutes = 480
        trackingMethod = .microphone
        alarm = AlarmSettings()
        saveSoundClips = false
        useSoundModel = true
        appearance = .dark
        demoMode = false
        userName = ""
        dimNightScreen = true
        scoreWeights = .standard
    }

    private func saveWeights() {
        if let data = try? JSONEncoder().encode(scoreWeights) {
            defaults.set(data, forKey: Key.weights)
        }
    }

    private func saveAlarm() {
        if let data = try? JSONEncoder().encode(alarm) {
            defaults.set(data, forKey: Key.alarm)
        }
    }

    /// iOS reads `AppleLanguages` at launch; the new language applies from the next start.
    private func applyLanguage() {
        defaults.set(language.rawValue, forKey: Key.language)
        switch language {
        case .system:
            defaults.removeObject(forKey: "AppleLanguages")
        case .danish, .english:
            defaults.set([language.rawValue], forKey: "AppleLanguages")
        }
    }

    /// Read-only access for code that runs outside the main actor (alarm intents).
    nonisolated static func storedAlarmSettings(defaults: UserDefaults = .standard) -> AlarmSettings {
        guard let data = defaults.data(forKey: "settings.alarm"),
              let decoded = try? JSONDecoder().decode(AlarmSettings.self, from: data) else { return AlarmSettings() }
        return decoded
    }
}
