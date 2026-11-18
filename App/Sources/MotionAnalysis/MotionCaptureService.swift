import CoreMotion
import Foundation
import SleepCore

/// Accelerometer capture for movement-based tracking (phone on the mattress) and for detecting
/// pickups in microphone mode. Raw accelerometer data is never stored; only per-epoch summaries
/// and movement events leave this class.
final class MotionCaptureService: @unchecked Sendable {
    let outputs: AsyncStream<SensorOutput>
    private let continuation: AsyncStream<SensorOutput>.Continuation
    private let manager = CMMotionManager()
    private let operationQueue: OperationQueue
    private let analyzer: MotionAnalyzer
    private let rate: Double
    private var pending: [AccelerometerSample] = []
    private var lastSample = Date()

    init(sessionStart: Date, rate: Double) {
        self.rate = rate
        analyzer = MotionAnalyzer(sessionStart: sessionStart, expectedSampleRate: rate)
        operationQueue = OperationQueue()
        operationQueue.maxConcurrentOperationCount = 1
        operationQueue.qualityOfService = .utility
        operationQueue.name = "com.samir.SleepFlow.motion"
        (outputs, continuation) = AsyncStream.makeStream(of: SensorOutput.self, bufferingPolicy: .bufferingNewest(500))
    }

    deinit {
        manager.stopAccelerometerUpdates()
        continuation.finish()
    }

    var isAvailable: Bool { manager.isAccelerometerAvailable }

    func start() throws {
        guard manager.isAccelerometerAvailable else { throw CaptureError.accelerometerUnavailable }
        manager.accelerometerUpdateInterval = 1.0 / rate
        // CoreMotion timestamps count seconds since boot; convert them to wall-clock dates.
        let bootDate = Date().addingTimeInterval(-ProcessInfo.processInfo.systemUptime)
        manager.startAccelerometerUpdates(to: operationQueue) { [weak self] data, _ in
            guard let self, let data else { return }
            let sample = AccelerometerSample(
                timestamp: bootDate.addingTimeInterval(data.timestamp),
                x: data.acceleration.x,
                y: data.acceleration.y,
                z: data.acceleration.z
            )
            self.handle(sample)
        }
    }

    /// Stops capture and returns the analyzer's remaining results.
    func stop() async -> [SensorOutput] {
        manager.stopAccelerometerUpdates()
        return await withCheckedContinuation { (resume: CheckedContinuation<[SensorOutput], Never>) in
            operationQueue.addOperation {
                var results = self.flushPending()
                let final = self.analyzer.finish()
                results += final.epochs.map { SensorOutput.motionEpoch($0) }
                results += final.events.map { SensorOutput.movement($0) }
                resume.resume(returning: results)
            }
        }
    }

    func secondsSinceLastSample() -> TimeInterval {
        Date().timeIntervalSince(lastSample)
    }

    /// Runs on the operation queue. Samples are analysed in one-second batches.
    private func handle(_ sample: AccelerometerSample) {
        lastSample = Date()
        pending.append(sample)
        guard pending.count >= Int(rate) else { return }
        for output in flushPending() {
            continuation.yield(output)
        }
    }

    private func flushPending() -> [SensorOutput] {
        guard !pending.isEmpty else { return [] }
        let result = analyzer.process(pending)
        pending.removeAll(keepingCapacity: true)
        return result.epochs.map { SensorOutput.motionEpoch($0) } + result.events.map { SensorOutput.movement($0) }
    }
}
