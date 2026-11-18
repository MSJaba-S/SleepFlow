import Foundation

/// Current estimate during the night, used by the Smart Alarm.
public struct OnlineEstimate: Sendable, Hashable {
    public var epochIndex: Int
    public var probabilities: StageProbabilities
    /// The last epoch showed a movement or vocal arousal relative to this night's activity.
    public var arousal: Bool
    public var hasData: Bool
    /// Normalised activity of the last epoch.
    public var activity: Double

    public init(epochIndex: Int, probabilities: StageProbabilities, arousal: Bool, hasData: Bool, activity: Double) {
        self.epochIndex = epochIndex
        self.probabilities = probabilities
        self.arousal = arousal
        self.hasData = hasData
        self.activity = activity
    }
}
