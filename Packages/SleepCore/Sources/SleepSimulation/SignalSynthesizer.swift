import Foundation
import SleepModels
import MotionAnalysis

/// Synthesises raw microphone and accelerometer signals with known content.
///
/// Used to test the DSP pipelines end to end (feature extraction, segmentation, classification,
/// motion detection) without real recordings. The signals are physically plausible approximations:
/// snoring is a low-frequency harmonic series, speech has formant-shaped harmonics with syllabic
/// modulation, coughs are broadband bursts with an explosive onset, rustling is high-passed noise.
public struct SignalSynthesizer {
    public let sampleRate: Double
    private var rng: SplitMix64

    public init(sampleRate: Double = 48_000, seed: UInt64 = 7) {
        self.sampleRate = sampleRate
        self.rng = SplitMix64(seed: seed)
    }

    private func count(_ duration: Double) -> Int { max(1, Int(duration * sampleRate)) }

    /// Quiet room: lightly low-passed white noise at the given RMS.
    public mutating func background(duration: Double, rms: Float = 0.0004) -> [Float] {
        let n = count(duration)
        var output = [Float](repeating: 0, count: n)
        var state = 0.0
        for index in 0..<n {
            state = 0.7 * state + 0.3 * rng.gaussian()
            output[index] = Float(state)
        }
        return normalise(output, toRMS: rms)
    }

    /// Snore: harmonic series of a ~90 Hz fundamental with a breath-shaped envelope.
    public mutating func snore(duration: Double = 1.3, fundamental: Double = 90, amplitude: Float = 0.012) -> [Float] {
        let n = count(duration)
        var output = [Float](repeating: 0, count: n)
        let jitter = rng.uniform(0.97...1.03)
        for index in 0..<n {
            let t = Double(index) / sampleRate
            let envelope = sin(Double.pi * t / duration)
            var value = 0.0
            for harmonic in 1...8 {
                let frequency = fundamental * jitter * Double(harmonic)
                value += sin(2 * Double.pi * frequency * t) / Double(harmonic * harmonic)
            }
            value += 0.02 * rng.gaussian()
            output[index] = Float(value * envelope * envelope)
        }
        return normalise(output, toPeak: amplitude)
    }

    /// Cough: explosive broadband burst (300–4000 Hz) with exponential decay.
    public mutating func cough(duration: Double = 0.35, amplitude: Float = 0.08) -> [Float] {
        let n = count(duration)
        var noise = (0..<n).map { _ in Float(rng.gaussian()) }
        noise = bandPass(noise, low: 300, high: 4_000)
        var output = [Float](repeating: 0, count: n)
        for index in 0..<n {
            let t = Double(index) / sampleRate
            let attack = min(1, t / 0.008)
            let decay = exp(-t / (duration * 0.35))
            output[index] = noise[index] * Float(attack * decay)
        }
        return normalise(output, toPeak: amplitude)
    }

    /// Speech-like signal: voiced harmonics (f0 ≈ 130 Hz) shaped by two formants, modulated at a
    /// syllable rate of about 4 Hz.
    public mutating func speech(duration: Double = 2.5, amplitude: Float = 0.02, syllableRate: Double = 4) -> [Float] {
        let n = count(duration)
        var output = [Float](repeating: 0, count: n)
        let f0 = rng.uniform(115...145)
        let formants = [(center: 700.0, width: 250.0), (center: 1_400.0, width: 400.0)]
        // Harmonic gains are fixed by the formant envelope at the nominal pitch.
        var gains: [Double] = []
        for harmonic in 1...25 {
            let frequency = f0 * Double(harmonic)
            if frequency > 4_000 { break }
            var gain = 0.08
            for formant in formants {
                let distance = (frequency - formant.center) / formant.width
                gain += exp(-0.5 * distance * distance)
            }
            gains.append(gain / Double(harmonic).squareRoot())
        }
        var phase = 0.0
        for index in 0..<n {
            let t = Double(index) / sampleRate
            // Slight intonation; the phase is integrated so the pitch glides smoothly.
            let pitch = f0 * (1 + 0.05 * sin(2 * Double.pi * 0.7 * t))
            phase += 2 * Double.pi * pitch / sampleRate
            var value = 0.0
            for (offset, gain) in gains.enumerated() {
                value += gain * sin(phase * Double(offset + 1))
            }
            let syllable = 0.5 - 0.5 * cos(2 * Double.pi * syllableRate * t)
            let edge = min(1, t / 0.05, (duration - t) / 0.05)
            output[index] = Float(value * syllable * syllable * max(0, edge))
        }
        return normalise(output, toPeak: amplitude)
    }

    /// Bedding rustle: noise above ~1.5 kHz with a smooth envelope.
    public mutating func rustle(duration: Double = 1.6, amplitude: Float = 0.004) -> [Float] {
        let n = count(duration)
        var noise = (0..<n).map { _ in Float(rng.gaussian()) }
        noise = highPass(noise, cutoff: 1_500)
        var output = [Float](repeating: 0, count: n)
        for index in 0..<n {
            let t = Double(index) / sampleRate
            let envelope = sin(Double.pi * t / duration)
            let flutter = 0.6 + 0.4 * sin(2 * Double.pi * 1.3 * t + 1)
            output[index] = noise[index] * Float(envelope * flutter)
        }
        return normalise(output, toPeak: amplitude)
    }

    /// Adds `signal` into `base` starting at `seconds`.
    public func mix(_ signal: [Float], into base: inout [Float], at seconds: Double) {
        let offset = Int(seconds * sampleRate)
        guard offset < base.count else { return }
        for index in 0..<min(signal.count, base.count - offset) {
            base[offset + index] += signal[index]
        }
    }

    // MARK: - Filters

    func highPass(_ input: [Float], cutoff: Double) -> [Float] {
        let rc = 1 / (2 * Double.pi * cutoff)
        let dt = 1 / sampleRate
        let alpha = Float(rc / (rc + dt))
        var output = [Float](repeating: 0, count: input.count)
        guard input.count > 1 else { return input }
        for index in 1..<input.count {
            output[index] = alpha * (output[index - 1] + input[index] - input[index - 1])
        }
        return output
    }

    func lowPass(_ input: [Float], cutoff: Double) -> [Float] {
        let rc = 1 / (2 * Double.pi * cutoff)
        let dt = 1 / sampleRate
        let alpha = Float(dt / (rc + dt))
        var output = [Float](repeating: 0, count: input.count)
        var previous: Float = 0
        for index in 0..<input.count {
            previous += alpha * (input[index] - previous)
            output[index] = previous
        }
        return output
    }

    func bandPass(_ input: [Float], low: Double, high: Double) -> [Float] {
        lowPass(highPass(input, cutoff: low), cutoff: high)
    }

    func normalise(_ input: [Float], toPeak peak: Float) -> [Float] {
        let current = input.map { abs($0) }.max() ?? 0
        guard current > 0 else { return input }
        let gain = peak / current
        return input.map { $0 * gain }
    }

    func normalise(_ input: [Float], toRMS target: Float) -> [Float] {
        let rms = (input.reduce(0) { $0 + $1 * $1 } / Float(max(input.count, 1))).squareRoot()
        guard rms > 0 else { return input }
        let gain = target / rms
        return input.map { $0 * gain }
    }

    // MARK: - Accelerometer

    public struct MovementSpec: Sendable {
        public var offset: TimeInterval
        public var duration: TimeInterval
        /// Peak gravity-free acceleration in g.
        public var magnitude: Double

        public init(offset: TimeInterval, duration: TimeInterval, magnitude: Double) {
            self.offset = offset
            self.duration = duration
            self.magnitude = magnitude
        }
    }

    /// Phone lying flat (gravity on -z) with sensor noise, breathing micro-motion and movements.
    /// `flipAt` rotates the phone by 180° (picked up and put down face up/down).
    public mutating func accelerometer(
        start: Date,
        duration: TimeInterval,
        rate: Double = 20,
        movements: [MovementSpec] = [],
        flipAt: TimeInterval? = nil,
        noise: Double = 0.0025
    ) -> [AccelerometerSample] {
        let n = max(1, Int(duration * rate))
        var samples: [AccelerometerSample] = []
        samples.reserveCapacity(n)
        for index in 0..<n {
            let t = Double(index) / rate
            var x = rng.gaussian(sd: noise)
            var y = rng.gaussian(sd: noise)
            var z = -1 + rng.gaussian(sd: noise) + 0.0015 * sin(2 * Double.pi * t / 4.2)
            for movement in movements where t >= movement.offset && t <= movement.offset + movement.duration {
                let phase = (t - movement.offset) / max(movement.duration, 0.1)
                let envelope = sin(Double.pi * phase)
                x += movement.magnitude * envelope * sin(2 * Double.pi * 2.3 * t)
                y += movement.magnitude * 0.6 * envelope * sin(2 * Double.pi * 1.7 * t + 0.5)
                z += movement.magnitude * 0.4 * envelope * sin(2 * Double.pi * 3.1 * t + 1.1)
            }
            if let flipAt, t >= flipAt {
                z = -z
                x = -x
            }
            samples.append(AccelerometerSample(timestamp: start.addingTimeInterval(t), x: x, y: y, z: z))
        }
        return samples
    }
}
