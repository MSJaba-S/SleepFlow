import Foundation

/// Kinds of night-time sounds the acoustic pipeline distinguishes.
public enum SoundEventType: String, Codable, Sendable, CaseIterable, Hashable {
    case snoring
    case coughing
    case talking
    /// Rustling of bedding, usually caused by the sleeper moving.
    case movement
    /// Loud or long environmental sound (traffic, doors, other people).
    case disturbance
    /// Audible breathing.
    case breathing
    /// Event detected but not classified with enough confidence.
    case unknown

    /// Sounds that are produced by the sleeper and suggest an arousal.
    public var suggestsArousal: Bool {
        switch self {
        case .coughing, .talking, .movement: return true
        case .snoring, .breathing, .disturbance, .unknown: return false
        }
    }
}

/// A classified night-time sound.
public struct SoundEvent: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var start: Date
    public var duration: TimeInterval
    public var type: SoundEventType
    /// 0...1, how sure the classifier is about `type`.
    public var confidence: Double
    /// Peak level in dBFS (decibels relative to full scale of the microphone).
    public var peakDecibels: Double
    /// Peak level above the adaptive noise floor, in dB.
    public var levelAboveFloor: Double
    /// Whether Apple's on-device sound classifier contributed to the classification.
    public var verifiedByModel: Bool
    /// File name of a saved audio clip, only when the user enabled clip saving.
    public var clipFileName: String?

    public init(
        id: UUID = UUID(),
        start: Date,
        duration: TimeInterval,
        type: SoundEventType,
        confidence: Double,
        peakDecibels: Double,
        levelAboveFloor: Double,
        verifiedByModel: Bool = false,
        clipFileName: String? = nil
    ) {
        self.id = id
        self.start = start
        self.duration = duration
        self.type = type
        self.confidence = confidence
        self.peakDecibels = peakDecibels
        self.levelAboveFloor = levelAboveFloor
        self.verifiedByModel = verifiedByModel
        self.clipFileName = clipFileName
    }

    public var end: Date { start.addingTimeInterval(duration) }
}

public enum MovementKind: String, Codable, Sendable, CaseIterable, Hashable {
    case small
    case large
    /// Very abrupt movement (jerk, startle).
    case sudden
    /// The phone itself was picked up or turned over.
    case pickup
}

/// A movement detected by the accelerometer.
public struct MovementEvent: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var start: Date
    public var duration: TimeInterval
    /// Peak RMS of the gravity-free acceleration in g.
    public var intensity: Double
    public var kind: MovementKind

    public init(id: UUID = UUID(), start: Date, duration: TimeInterval, intensity: Double, kind: MovementKind) {
        self.id = id
        self.start = start
        self.duration = duration
        self.intensity = intensity
        self.kind = kind
    }

    public var end: Date { start.addingTimeInterval(duration) }
}

/// A run of regularly repeating movements (for example periodic limb movements).
public struct RepeatedMovementPattern: Codable, Sendable, Hashable {
    public var start: Date
    public var end: Date
    public var count: Int
    /// Average time between movements in seconds.
    public var meanInterval: TimeInterval

    public init(start: Date, end: Date, count: Int, meanInterval: TimeInterval) {
        self.start = start
        self.end = end
        self.count = count
        self.meanInterval = meanInterval
    }
}
