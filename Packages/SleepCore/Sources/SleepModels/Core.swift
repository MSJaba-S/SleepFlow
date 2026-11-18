import Foundation

/// Constants shared by every part of the engine.
public enum SleepConstants {
    /// Length of one analysis epoch. 30 s matches the convention used in sleep research (PSG scoring).
    public static let epochLength: TimeInterval = 30
    /// Version of the analysis algorithms. Stored with every session so results stay reproducible.
    public static let algorithmVersion = "1.0.0"
}

/// The three consumer-level sleep states SleepFlow estimates.
///
/// These are estimates from sound and movement, not clinical sleep stages.
/// "Light" covers what a sleep lab would score as N1/N2/REM, "deep" approximates N3.
public enum SleepStage: Int, Codable, Sendable, CaseIterable, Comparable {
    case awake = 0
    case light = 1
    case deep = 2

    public static func < (lhs: SleepStage, rhs: SleepStage) -> Bool { lhs.rawValue < rhs.rawValue }

    public var isAsleep: Bool { self != .awake }
}

/// Probability for each estimated state. Always normalised to sum to 1.
public struct StageProbabilities: Codable, Sendable, Hashable {
    public private(set) var awake: Double
    public private(set) var light: Double
    public private(set) var deep: Double

    public init(awake: Double, light: Double, deep: Double) {
        let a = max(0, awake.isFinite ? awake : 0)
        let l = max(0, light.isFinite ? light : 0)
        let d = max(0, deep.isFinite ? deep : 0)
        let sum = a + l + d
        if sum <= 0 {
            self.awake = 1.0 / 3.0
            self.light = 1.0 / 3.0
            self.deep = 1.0 / 3.0
        } else {
            self.awake = a / sum
            self.light = l / sum
            self.deep = d / sum
        }
    }

    public init(_ values: [Double]) {
        precondition(values.count == 3, "StageProbabilities needs three values")
        self.init(awake: values[0], light: values[1], deep: values[2])
    }

    public static let uniform = StageProbabilities(awake: 1, light: 1, deep: 1)

    public subscript(stage: SleepStage) -> Double {
        switch stage {
        case .awake: return awake
        case .light: return light
        case .deep: return deep
        }
    }

    public var values: [Double] { [awake, light, deep] }

    public var mostLikely: SleepStage {
        if awake >= light && awake >= deep { return .awake }
        if light >= deep { return .light }
        return .deep
    }

    public var confidence: Double { max(awake, max(light, deep)) }
}

/// How the night is measured.
public enum TrackingMethod: String, Codable, Sendable, CaseIterable {
    /// Phone on the bedside table. Sound analysis; runs with the screen locked.
    case microphone
    /// Phone on the mattress. Accelerometer analysis; no microphone.
    case motion
}

/// Weekdays numbered like `Calendar` (1 = Sunday ... 7 = Saturday).
public enum Weekday: Int, Codable, Sendable, CaseIterable, Comparable, Hashable {
    case sunday = 1, monday, tuesday, wednesday, thursday, friday, saturday

    public static func < (lhs: Weekday, rhs: Weekday) -> Bool {
        lhs.mondayFirstIndex < rhs.mondayFirstIndex
    }

    /// Monday-first ordering, as used in Denmark.
    public static let mondayFirst: [Weekday] = [.monday, .tuesday, .wednesday, .thursday, .friday, .saturday, .sunday]

    public var mondayFirstIndex: Int { (rawValue + 5) % 7 }

    public static let weekdays: Set<Weekday> = [.monday, .tuesday, .wednesday, .thursday, .friday]
    public static let weekend: Set<Weekday> = [.saturday, .sunday]
}
