import Foundation
import SleepCore

/// Replays a simulated night at high speed through the tracking pipeline.
///
/// Used by UI tests and by "Simulate a night" in demo mode. Simulated sessions are flagged
/// `isSimulated`, journaled in a separate folder and saved to the demo store only, so they can never
/// mix with real nights.
final class SimulatedNightSource: @unchecked Sendable {
    let outputs: AsyncStream<SensorOutput>
    private let continuation: AsyncStream<SensorOutput>.Continuation
    private let night: SimulatedNight
    /// Real seconds per simulated epoch.
    private let interval: TimeInterval
    private var task: Task<Void, Never>?

    init(method: TrackingMethod, start: Date, duration: TimeInterval = 7.5 * 3600, sleepLatency: TimeInterval = 15 * 60, seed: UInt64 = UInt64.random(in: 1...999_999), interval: TimeInterval = 0.02) {
        let short = duration < 4 * 3600
        let scenario = NightScenario(
            method: method,
            bedtime: start,
            timeInBed: duration,
            sleepLatency: sleepLatency,
            awakenings: short ? 0 : 2,
            snoringPropensity: 0.25,
            restlessness: 0.35
        )
        night = NightSimulator.simulate(scenario, seed: seed)
        self.interval = interval
        (outputs, continuation) = AsyncStream.makeStream(of: SensorOutput.self, bufferingPolicy: .unbounded)
    }

    var simulatedEnd: Date { night.end }

    func start() {
        let night = self.night
        let interval = self.interval
        let continuation = self.continuation
        task = Task.detached(priority: .utility) {
            var soundIndex = 0
            var movementIndex = 0
            let sounds = night.soundEvents.sorted { $0.start < $1.start }
            let movements = night.movementEvents.sorted { $0.start < $1.start }
            for epoch in night.epochs {
                if Task.isCancelled { break }
                while soundIndex < sounds.count, sounds[soundIndex].start < epoch.end {
                    continuation.yield(.soundEvent(sounds[soundIndex]))
                    soundIndex += 1
                }
                while movementIndex < movements.count, movements[movementIndex].start < epoch.end {
                    continuation.yield(.movement(movements[movementIndex]))
                    movementIndex += 1
                }
                continuation.yield(.epoch(epoch))
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        continuation.finish()
    }
}
