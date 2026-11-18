import AVFoundation
import Foundation
import SoundAnalysis
import SleepCore

/// Second opinion from Apple's built-in, on-device sound classifier (SoundAnalysis, version 1).
///
/// This is a genuine trained model shipped with iOS. It is only run on the short audio of events
/// that SleepCore's own pipeline already detected (not continuously), at most once every
/// two seconds and never when the phone is getting warm. Its probabilities for snoring, coughing,
/// speech and breathing are fused with the rule-based result by `ClassifierFusion`.
final class AppleSoundClassifier: SoundEventRefining {
    private let request: SNClassifySoundRequest
    private let format: AVAudioFormat
    private let ring: SampleRingBuffer
    private let sampleRate: Double
    private var lastRun = Date.distantPast
    var enabled = true

    init?(sampleRate: Double, ring: SampleRingBuffer) {
        guard let request = try? SNClassifySoundRequest(classifierIdentifier: .version1),
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return nil }
        request.overlapFactor = 0.5
        self.request = request
        self.format = format
        self.ring = ring
        self.sampleRate = sampleRate
    }

    func modelDistribution(for candidate: EventCandidate) -> SoundTypeDistribution? {
        guard enabled else { return nil }
        let now = Date()
        guard now.timeIntervalSince(lastRun) >= 2 else { return nil }
        lastRun = now

        // The classifier looks at ~1 s windows; pad short events with surrounding audio.
        let pad = Int64(sampleRate * 0.3)
        var start = candidate.startSample - pad
        var end = candidate.endSample + pad
        let minimum = Int64(sampleRate * 1.1)
        if end - start < minimum {
            let extra = (minimum - (end - start)) / 2 + 1
            start -= extra
            end += extra
        }
        guard let samples = ring.read(from: start, to: end), samples.count >= Int(sampleRate * 0.5) else { return nil }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { channel.update(from: base, count: samples.count) }
        }

        let analyzer = SNAudioStreamAnalyzer(format: format)
        let collector = ClassificationCollector()
        do {
            try analyzer.add(request, withObserver: collector)
        } catch {
            return nil
        }
        analyzer.analyze(buffer, atAudioFramePosition: 0)
        analyzer.completeAnalysis()
        return collector.distribution()
    }
}

/// Collects the highest confidence per label across analysis windows.
final class ClassificationCollector: NSObject, SNResultsObserving, @unchecked Sendable {
    private let lock = NSLock()
    private var best: [String: Double] = [:]

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        lock.lock()
        defer { lock.unlock() }
        for classification in result.classifications {
            best[classification.identifier] = max(best[classification.identifier] ?? 0, classification.confidence)
        }
    }

    func request(_ request: SNRequest, didFailWithError error: any Error) {}

    func requestDidComplete(_ request: SNRequest) {}

    /// Maps Apple's labels to SleepFlow's classes.
    func distribution() -> SoundTypeDistribution? {
        lock.lock()
        let scores = best
        lock.unlock()
        guard !scores.isEmpty else { return nil }
        var result: SoundTypeDistribution = [:]
        for (identifier, confidence) in scores {
            guard let type = ClassificationCollector.map(identifier) else { continue }
            result[type] = max(result[type] ?? 0, confidence)
        }
        let total = result.values.reduce(0, +)
        if total > 1 {
            result = result.mapValues { $0 / total }
        }
        return result
    }

    static func map(_ identifier: String) -> SoundEventType? {
        let label = identifier.lowercased()
        if label.contains("snor") { return .snoring }
        if label.contains("cough") || label.contains("sneez") || label.contains("throat") { return .coughing }
        let speech = ["speech", "whisper", "conversation", "shout", "yell", "laugh", "giggl", "babbl", "chatter", "talk", "singing"]
        if speech.contains(where: { label.contains($0) }) { return .talking }
        let breathing = ["breath", "gasp", "sigh", "pant", "wheez"]
        if breathing.contains(where: { label.contains($0) }) { return .breathing }
        return nil
    }
}
