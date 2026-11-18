import Foundation

/// Acoustic features of one analysis frame (~85 ms at 48 kHz).
public struct FrameFeatures: Sendable, Hashable {
    /// Root mean square of the raw samples (linear, full scale = 1).
    public var rms: Float
    /// Level in dBFS, `20·log10(rms)`, floored at -120 dB.
    public var decibels: Float
    /// Zero crossings per sample (0...1). High for noise and fricatives, low for voiced/low-frequency sounds.
    public var zeroCrossingRate: Float
    /// Energy-weighted mean frequency of the spectrum in Hz.
    public var spectralCentroid: Float
    /// Frequency below which 85 % of the spectral energy lies, in Hz.
    public var spectralRolloff: Float
    /// Geometric / arithmetic mean of the power spectrum (0 = tonal, 1 = white noise).
    public var spectralFlatness: Float
    /// Positive spectral change compared with the previous frame (normalised spectra).
    public var spectralFlux: Float
    /// Fraction of energy per band: < 300 Hz, 300–1000 Hz, 1–3 kHz, > 3 kHz.
    public var bandLow: Float
    public var bandLowMid: Float
    public var bandMid: Float
    public var bandHigh: Float

    public init(
        rms: Float,
        decibels: Float,
        zeroCrossingRate: Float,
        spectralCentroid: Float,
        spectralRolloff: Float,
        spectralFlatness: Float,
        spectralFlux: Float,
        bandLow: Float,
        bandLowMid: Float,
        bandMid: Float,
        bandHigh: Float
    ) {
        self.rms = rms
        self.decibels = decibels
        self.zeroCrossingRate = zeroCrossingRate
        self.spectralCentroid = spectralCentroid
        self.spectralRolloff = spectralRolloff
        self.spectralFlatness = spectralFlatness
        self.spectralFlux = spectralFlux
        self.bandLow = bandLow
        self.bandLowMid = bandLowMid
        self.bandMid = bandMid
        self.bandHigh = bandHigh
    }
}

public enum WindowFunction {
    /// Periodic Hann window.
    public static func hann(_ count: Int) -> [Float] {
        guard count > 1 else { return [1] }
        return (0..<count).map { index in
            Float(0.5 - 0.5 * cos(2.0 * Double.pi * Double(index) / Double(count)))
        }
    }
}

public enum Decibels {
    public static let floor: Float = -120

    public static func fromRMS(_ rms: Float) -> Float {
        guard rms > 1e-6 else { return floor }
        return max(floor, 20 * log10(rms))
    }
}

/// Computes `FrameFeatures` (and optionally MFCCs) for frames of a fixed size.
public final class FrameFeatureExtractor {
    public let sampleRate: Double
    public let frameSize: Int
    private let fft: RealFFT
    private let window: [Float]
    private let binFrequencies: [Float]
    private let melBank: MelFilterBank
    private var previousSpectrum: [Float]?

    public init(sampleRate: Double, frameSize: Int, useAccelerate: Bool = true) {
        self.sampleRate = sampleRate
        self.frameSize = frameSize
        self.fft = RealFFT(size: frameSize, useAccelerate: useAccelerate)
        self.window = WindowFunction.hann(frameSize)
        let binCount = frameSize / 2 + 1
        let resolution = Float(sampleRate) / Float(frameSize)
        self.binFrequencies = (0..<binCount).map { Float($0) * resolution }
        self.melBank = MelFilterBank(sampleRate: sampleRate, fftSize: frameSize, bandCount: 26, minFrequency: 50, maxFrequency: min(8000, sampleRate / 2))
    }

    public var usesAccelerate: Bool { fft.isAccelerated }

    /// Most recent magnitude spectrum, kept so MFCCs can be derived without a second FFT.
    public private(set) var lastSpectrum: [Float] = []

    public func reset() {
        previousSpectrum = nil
        lastSpectrum = []
    }

    public func features(of frame: [Float]) -> FrameFeatures {
        precondition(frame.count == frameSize, "Frame has wrong size")

        var sumSquares: Float = 0
        var crossings = 0
        var previousSign = frame[0] >= 0
        for sample in frame {
            sumSquares += sample * sample
            let sign = sample >= 0
            if sign != previousSign { crossings += 1 }
            previousSign = sign
        }
        let rms = (sumSquares / Float(frameSize)).squareRoot()
        let decibels = Decibels.fromRMS(rms)
        let zcr = Float(crossings) / Float(frameSize)

        var windowed = [Float](repeating: 0, count: frameSize)
        for index in 0..<frameSize {
            windowed[index] = frame[index] * window[index]
        }
        let magnitudes = fft.magnitudes(windowed)
        lastSpectrum = magnitudes

        var totalPower: Float = 0
        var weightedFrequency: Float = 0
        var low: Float = 0, lowMid: Float = 0, mid: Float = 0, high: Float = 0
        var logSum: Double = 0
        var usedBins = 0
        // Skip DC; analyse up to 8 kHz where nearly all sleep-related sounds live.
        let maxFrequency = min(Float(sampleRate / 2), 8000)
        for bin in 1..<magnitudes.count {
            let frequency = binFrequencies[bin]
            if frequency > maxFrequency { break }
            let power = magnitudes[bin] * magnitudes[bin]
            totalPower += power
            weightedFrequency += power * frequency
            switch frequency {
            case ..<300: low += power
            case ..<1000: lowMid += power
            case ..<3000: mid += power
            default: high += power
            }
            logSum += log(Double(power) + 1e-12)
            usedBins += 1
        }

        var centroid: Float = 0
        var rolloff: Float = 0
        var flatness: Float = 0
        if totalPower > 1e-12, usedBins > 0 {
            centroid = weightedFrequency / totalPower
            let target = totalPower * 0.85
            var cumulative: Float = 0
            for bin in 1..<magnitudes.count {
                let frequency = binFrequencies[bin]
                if frequency > maxFrequency { break }
                cumulative += magnitudes[bin] * magnitudes[bin]
                if cumulative >= target {
                    rolloff = frequency
                    break
                }
            }
            let geometricMean = exp(logSum / Double(usedBins))
            let arithmeticMean = Double(totalPower) / Double(usedBins)
            flatness = Float(min(1, geometricMean / max(arithmeticMean, 1e-12)))
            low /= totalPower
            lowMid /= totalPower
            mid /= totalPower
            high /= totalPower
        }

        // Spectral flux on L1-normalised magnitude spectra.
        var flux: Float = 0
        let magnitudeSum = magnitudes.reduce(0, +)
        if magnitudeSum > 1e-9 {
            let normalised = magnitudes.map { $0 / magnitudeSum }
            if let previous = previousSpectrum, previous.count == normalised.count {
                for index in 0..<normalised.count {
                    let difference = normalised[index] - previous[index]
                    if difference > 0 { flux += difference }
                }
            }
            previousSpectrum = normalised
        }

        return FrameFeatures(
            rms: rms,
            decibels: decibels,
            zeroCrossingRate: zcr,
            spectralCentroid: centroid,
            spectralRolloff: rolloff,
            spectralFlatness: flatness,
            spectralFlux: flux,
            bandLow: low,
            bandLowMid: lowMid,
            bandMid: mid,
            bandHigh: high
        )
    }

    /// MFCCs of the most recent frame passed to `features(of:)`.
    public func mfccOfLastFrame(coefficients: Int = 13) -> [Float] {
        guard !lastSpectrum.isEmpty else { return [Float](repeating: 0, count: coefficients) }
        return melBank.mfcc(magnitudes: lastSpectrum, coefficients: coefficients)
    }
}

/// Triangular mel filter bank and DCT-II for MFCC computation.
public struct MelFilterBank: Sendable {
    public let bandCount: Int
    /// For each band: (first bin, weights for consecutive bins).
    private let filters: [(start: Int, weights: [Float])]

    public init(sampleRate: Double, fftSize: Int, bandCount: Int, minFrequency: Double, maxFrequency: Double) {
        self.bandCount = bandCount
        func hzToMel(_ hz: Double) -> Double { 2595 * log10(1 + hz / 700) }
        func melToHz(_ mel: Double) -> Double { 700 * (pow(10, mel / 2595) - 1) }

        let binCount = fftSize / 2 + 1
        let minMel = hzToMel(minFrequency)
        let maxMel = hzToMel(maxFrequency)
        let points = (0..<(bandCount + 2)).map { index -> Double in
            melToHz(minMel + (maxMel - minMel) * Double(index) / Double(bandCount + 1))
        }
        let binOf: (Double) -> Double = { frequency in frequency * Double(fftSize) / sampleRate }

        var result: [(start: Int, weights: [Float])] = []
        for band in 0..<bandCount {
            let left = binOf(points[band])
            let center = binOf(points[band + 1])
            let right = binOf(points[band + 2])
            let startBin = max(0, Int(left.rounded(.down)))
            let endBin = min(binCount - 1, Int(right.rounded(.up)))
            var weights: [Float] = []
            if endBin >= startBin {
                for bin in startBin...endBin {
                    let position = Double(bin)
                    var weight = 0.0
                    if position >= left && position <= center && center > left {
                        weight = (position - left) / (center - left)
                    } else if position > center && position <= right && right > center {
                        weight = (right - position) / (right - center)
                    }
                    weights.append(Float(max(0, weight)))
                }
            }
            result.append((start: startBin, weights: weights))
        }
        filters = result
    }

    public func bandEnergies(magnitudes: [Float]) -> [Float] {
        filters.map { filter in
            var energy: Float = 0
            for (offset, weight) in filter.weights.enumerated() {
                let bin = filter.start + offset
                if bin < magnitudes.count {
                    energy += weight * magnitudes[bin] * magnitudes[bin]
                }
            }
            return energy
        }
    }

    public func mfcc(magnitudes: [Float], coefficients: Int) -> [Float] {
        let logEnergies = bandEnergies(magnitudes: magnitudes).map { log(max($0, 1e-10)) }
        let n = Float(logEnergies.count)
        return (0..<coefficients).map { k in
            var sum: Float = 0
            for (index, value) in logEnergies.enumerated() {
                sum += value * Float(cos(Double.pi * Double(k) * (Double(index) + 0.5) / Double(n)))
            }
            return sum
        }
    }
}
