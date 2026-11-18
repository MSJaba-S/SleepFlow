import Foundation
import SleepModels

/// Tracks the ambient sound level of the bedroom.
///
/// Minimum-statistics style estimator: the floor follows quieter frames quickly and louder
/// frames only very slowly, so short events (snores, coughs) barely move it while a
/// fan switching on is absorbed within about a minute.
public struct NoiseFloorEstimator: Sendable {
    public struct Configuration: Sendable {
        /// Smoothing factor per frame when the level is below the floor.
        public var fallRate: Double = 0.08
        /// Smoothing factor per frame when the level is above the floor.
        public var riseRate: Double = 0.0025
        /// Lowest floor the estimator accepts (very quiet rooms / muted input).
        public var minimumFloor: Double = -100
        /// Frames used to initialise the estimate.
        public var warmUpFrames: Int = 12

        public init() {}
    }

    public let configuration: Configuration
    public private(set) var floor: Double?
    private var warmUp: [Double] = []

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public var isReady: Bool { floor != nil }

    /// Feeds the level of one frame (dBFS) and returns the updated floor.
    @discardableResult
    public mutating func update(frameDecibels level: Double, frozen: Bool = false) -> Double {
        let value = Swift.max(level, configuration.minimumFloor)
        guard let current = floor else {
            warmUp.append(value)
            if warmUp.count >= configuration.warmUpFrames {
                // Start from a low percentile so an event during warm-up does not inflate the floor.
                floor = Stats.percentile(warmUp, 0.3)
                warmUp.removeAll()
            }
            return floor ?? Stats.percentile(warmUp, 0.3)
        }
        if frozen { return current }
        let rate = value < current ? configuration.fallRate : configuration.riseRate
        let updated = current + (value - current) * rate
        floor = Swift.max(updated, configuration.minimumFloor)
        return floor ?? updated
    }

    public mutating func reset() {
        floor = nil
        warmUp.removeAll()
    }
}
