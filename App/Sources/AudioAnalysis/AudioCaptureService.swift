import AVFoundation
import Foundation
import SleepCore

/// Everything the sensor services report to the tracking controller.
enum SensorOutput: Sendable {
    case acousticEpoch(AcousticEpochSummary)
    case soundEvent(SoundEvent)
    case level(LevelReading)
    case motionEpoch(MotionEpochSummary)
    case movement(MovementEvent)
    /// A complete epoch from the night simulator (bypasses the analyzers).
    case epoch(EpochFeatures)
    case interruption(began: Bool, reason: String)
    case failure(String)
}

enum CaptureError: LocalizedError {
    case microphoneDenied
    case noInputDevice
    case accelerometerUnavailable

    var errorDescription: String? {
        switch self {
        case .microphoneDenied: return String(localized: "Microphone access is turned off for SleepFlow.")
        case .noInputDevice: return String(localized: "No microphone is available right now.")
        case .accelerometerUnavailable: return String(localized: "The motion sensor is not available.")
        }
    }
}

/// Overnight microphone capture and analysis.
///
/// A tap on the input node copies each buffer (≈100 ms) and hands it to a serial utility queue
/// where `AudioAnalyzer` (SleepCore) extracts features, segments events and builds epoch summaries.
/// Raw audio is kept only in a 20-second ring buffer in memory, used for the optional second
/// opinion of Apple's on-device classifier and for clips the user explicitly chose to save.
/// Nothing is written to disk or sent anywhere unless clip saving is enabled.
final class AudioCaptureService: @unchecked Sendable {
    struct Configuration: Sendable {
        var sessionStart: Date
        var saveClips: Bool
        var useSoundModel: Bool
        /// Maximum clips saved per night, to bound storage.
        var clipBudget = 40
    }

    let outputs: AsyncStream<SensorOutput>
    private let continuation: AsyncStream<SensorOutput>.Continuation
    private let configuration: Configuration
    private let queue = DispatchQueue(label: "com.samir.SleepFlow.audio", qos: .utility)

    // State below is only touched on `queue`.
    private var engine: AVAudioEngine?
    private var analyzer: AudioAnalyzer?
    private var ring: SampleRingBuffer?
    private var classifier: AppleSoundClassifier?
    private var running = false
    private var masked = false
    private var lastBuffer = Date()
    private var clipsSaved = 0
    private var observers: [NSObjectProtocol] = []

    init(configuration: Configuration) {
        self.configuration = configuration
        (outputs, continuation) = AsyncStream.makeStream(of: SensorOutput.self, bufferingPolicy: .bufferingNewest(500))
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        continuation.finish()
    }

    /// Starts capture. The audio session must already be configured for recording.
    func start() throws {
        try queue.sync {
            try startEngine()
            running = true
            lastBuffer = Date()
        }
        installObservers()
    }

    /// Stops capture and returns the analyzer's final results (open events, last epochs).
    func stop() async -> [SensorOutput] {
        await withCheckedContinuation { (resume: CheckedContinuation<[SensorOutput], Never>) in
            queue.async {
                self.running = false
                self.tearDownEngine()
                var results: [SensorOutput] = []
                if let analyzer = self.analyzer {
                    results = self.sensorOutputs(from: analyzer.finish())
                }
                self.analyzer = nil
                self.ring = nil
                self.classifier = nil
                resume.resume(returning: results)
            }
        }
    }

    func setPlaybackMasked(_ value: Bool) {
        queue.async { self.masked = value }
    }

    /// Seconds since the last audio buffer arrived (watchdog).
    func secondsSinceLastBuffer() -> TimeInterval {
        queue.sync { Date().timeIntervalSince(lastBuffer) }
    }

    /// Restarts the engine if iOS stopped it (route change, interruption that ended).
    func restartIfNeeded(reason: String) {
        queue.async {
            guard self.running else { return }
            if let engine = self.engine, engine.isRunning { return }
            do {
                try self.startEngine()
                self.lastBuffer = Date()
                self.continuation.yield(.interruption(began: false, reason: reason))
                Log.audio.info("Audio engine restarted: \(reason, privacy: .public)")
            } catch {
                self.continuation.yield(.failure("restart: \(error.localizedDescription)"))
            }
        }
    }

    // MARK: - Engine (on queue)

    private func startEngine() throws {
        guard AVAudioApplication.shared.recordPermission == .granted else { throw CaptureError.microphoneDenied }
        tearDownEngine()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.noInputDevice }

        // A new analyzer is needed if the sample rate changed (e.g. a different microphone).
        if analyzer == nil || analyzer?.sampleRate != format.sampleRate {
            if let previous = analyzer {
                for output in sensorOutputs(from: previous.finish()) { continuation.yield(output) }
            }
            let analyzer = AudioAnalyzer(sampleRate: format.sampleRate, sessionStart: configuration.sessionStart)
            let ring = SampleRingBuffer(capacity: Int(format.sampleRate * 20))
            self.analyzer = analyzer
            self.ring = ring
            if configuration.useSoundModel, let classifier = AppleSoundClassifier(sampleRate: format.sampleRate, ring: ring) {
                self.classifier = classifier
                analyzer.refiner = classifier
            } else {
                classifier = nil
            }
        }

        let bufferSize = AVAudioFrameCount(max(1_024, Int(format.sampleRate / 10)))
        input.installTap(onBus: 0, bufferSize: bufferSize, format: format) { [weak self] buffer, time in
            self?.receive(buffer: buffer, time: time)
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
    }

    private func tearDownEngine() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }

    // MARK: - Buffers

    /// Called on the audio tap thread: copy and hand over, nothing else.
    private func receive(buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }
        let samples = Array(UnsafeBufferPointer(start: channel, count: count))
        let date = AudioCaptureService.date(for: time, frames: count, sampleRate: buffer.format.sampleRate)
        queue.async { [weak self] in
            self?.process(samples, date: date)
        }
    }

    private func process(_ samples: [Float], date: Date) {
        guard running, let analyzer else { return }
        lastBuffer = Date()
        ring?.append(samples, startingAt: analyzer.nextSampleIndex)
        analyzer.isPlaybackMasked = masked
        classifier?.enabled = ProcessInfo.processInfo.thermalState.rawValue < ProcessInfo.ThermalState.serious.rawValue
        for output in sensorOutputs(from: analyzer.process(samples, startingAt: date)) {
            continuation.yield(output)
        }
    }

    private func sensorOutputs(from analysis: AudioAnalysisOutput) -> [SensorOutput] {
        var results: [SensorOutput] = []
        for (index, original) in analysis.events.enumerated() {
            var event = original
            if configuration.saveClips, clipsSaved < configuration.clipBudget,
               [.snoring, .talking, .coughing].contains(event.type),
               index < analysis.candidates.count,
               let analyzer, let ring {
                let candidate = analysis.candidates[index]
                let margin = Int64(analyzer.sampleRate * 0.5)
                let maximum = Int64(analyzer.sampleRate * 10)
                let start = candidate.startSample - margin
                let end = min(candidate.endSample + margin, start + maximum)
                if let samples = ring.read(from: start, to: end) {
                    let name = "\(event.id.uuidString).m4a"
                    do {
                        try ClipWriter.write(samples: samples, sampleRate: analyzer.sampleRate, to: FileLocations.clipURL(named: name))
                        event.clipFileName = name
                        clipsSaved += 1
                    } catch {
                        Log.audio.error("Clip not saved: \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
            results.append(.soundEvent(event))
        }
        results.append(contentsOf: analysis.epochs.map { SensorOutput.acousticEpoch($0) })
        if let level = analysis.level { results.append(.level(level)) }
        return results
    }

    static func date(for time: AVAudioTime, frames: Int, sampleRate: Double) -> Date {
        if time.isHostTimeValid {
            let now = AVAudioTime.seconds(forHostTime: mach_absolute_time())
            let then = AVAudioTime.seconds(forHostTime: time.hostTime)
            return Date().addingTimeInterval(then - now)
        }
        return Date().addingTimeInterval(-Double(frames) / max(sampleRate, 1))
    }

    // MARK: - System notifications

    private func installObservers() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: nil) { [weak self] notification in
            guard let self else { return }
            let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt ?? 0
            let type = AVAudioSession.InterruptionType(rawValue: rawType)
            if type == .began {
                self.continuation.yield(.interruption(began: true, reason: "interruption"))
            } else {
                Task { @MainActor in AudioSessionCoordinator.shared.reactivate() }
                self.restartIfNeeded(reason: "interruption ended")
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.engine = nil }
            Task { @MainActor in AudioSessionCoordinator.shared.reactivate() }
            self.restartIfNeeded(reason: "media services reset")
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil) { [weak self] _ in
            self?.restartIfNeeded(reason: "configuration change")
        })
    }
}

/// Fixed-size ring of recent samples addressed by absolute sample index.
final class SampleRingBuffer {
    private var storage: [Float]
    private let capacity: Int
    private var writePosition = 0
    private var filled = 0
    private(set) var endSample: Int64 = 0

    init(capacity: Int) {
        self.capacity = max(capacity, 1)
        storage = [Float](repeating: 0, count: max(capacity, 1))
    }

    func append(_ samples: [Float], startingAt absolute: Int64) {
        if absolute != endSample {
            // Non-contiguous: forget the old content.
            filled = 0
            endSample = absolute
        }
        for sample in samples {
            storage[writePosition] = sample
            writePosition = (writePosition + 1) % capacity
        }
        endSample += Int64(samples.count)
        filled = min(capacity, filled + samples.count)
    }

    /// Samples in [start, end), or nil if that range is no longer (or not yet) in the buffer.
    func read(from start: Int64, to end: Int64) -> [Float]? {
        let oldest = endSample - Int64(filled)
        let lower = max(start, oldest)
        let upper = min(end, endSample)
        guard upper > lower else { return nil }
        let count = Int(upper - lower)
        var result = [Float]()
        result.reserveCapacity(count)
        var position = (writePosition - Int(endSample - lower)) % capacity
        if position < 0 { position += capacity }
        for _ in 0..<count {
            result.append(storage[position])
            position = (position + 1) % capacity
        }
        return result
    }
}

/// Writes a short AAC clip. Only used when the user enabled clip saving.
enum ClipWriter {
    static func write(samples: [Float], sampleRate: Double, to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 48_000
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress {
                channel.update(from: base, count: samples.count)
            }
        }
        try file.write(from: buffer)
        FileLocations.protect(url, .completeUnlessOpen)
    }
}
