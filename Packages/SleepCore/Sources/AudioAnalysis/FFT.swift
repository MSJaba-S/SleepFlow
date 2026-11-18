import Foundation
#if canImport(Accelerate)
import Accelerate
#endif

/// Magnitude spectrum of a real-valued frame.
///
/// On Apple platforms the transform runs on Accelerate (vDSP), elsewhere on a portable
/// radix-2 implementation. Both produce the magnitude of the standard DFT for bins
/// `0...size/2`, so results are identical up to floating point rounding.
public final class RealFFT {
    public let size: Int
    public var binCount: Int { size / 2 + 1 }

    private let portable: PortableFFT
    #if canImport(Accelerate)
    private let accelerated: AcceleratedFFT?
    #endif

    /// - Parameter size: power of two, at least 4.
    /// - Parameter useAccelerate: set to `false` to force the portable implementation (used by parity tests).
    public init(size: Int, useAccelerate: Bool = true) {
        precondition(size >= 4 && size & (size - 1) == 0, "FFT size must be a power of two")
        self.size = size
        self.portable = PortableFFT(size: size)
        #if canImport(Accelerate)
        self.accelerated = useAccelerate ? AcceleratedFFT(size: size) : nil
        #endif
    }

    /// Returns `size / 2 + 1` magnitudes. `input` must contain exactly `size` samples.
    public func magnitudes(_ input: [Float]) -> [Float] {
        precondition(input.count == size, "FFT input has wrong length")
        #if canImport(Accelerate)
        if let accelerated {
            return accelerated.magnitudes(input)
        }
        #endif
        return portable.magnitudes(input)
    }

    /// Whether this instance uses the Accelerate framework.
    public var isAccelerated: Bool {
        #if canImport(Accelerate)
        return accelerated != nil
        #else
        return false
        #endif
    }
}

/// Iterative radix-2 Cooley-Tukey FFT with precomputed twiddle factors.
final class PortableFFT {
    let size: Int
    private let cosTable: [Float]
    private let sinTable: [Float]
    private let bitReversed: [Int]
    private var real: [Float]
    private var imaginary: [Float]

    init(size: Int) {
        self.size = size
        var cosValues = [Float](repeating: 0, count: size / 2)
        var sinValues = [Float](repeating: 0, count: size / 2)
        for index in 0..<(size / 2) {
            let angle = 2.0 * Double.pi * Double(index) / Double(size)
            cosValues[index] = Float(cos(angle))
            sinValues[index] = Float(sin(angle))
        }
        cosTable = cosValues
        sinTable = sinValues

        var bits = 0
        while (1 << bits) < size { bits += 1 }
        var reversed = [Int](repeating: 0, count: size)
        for index in 0..<size {
            var value = index
            var result = 0
            for _ in 0..<bits {
                result = (result << 1) | (value & 1)
                value >>= 1
            }
            reversed[index] = result
        }
        bitReversed = reversed
        real = [Float](repeating: 0, count: size)
        imaginary = [Float](repeating: 0, count: size)
    }

    func magnitudes(_ input: [Float]) -> [Float] {
        let n = size
        for index in 0..<n {
            real[bitReversed[index]] = input[index]
            imaginary[index] = 0
        }
        var length = 2
        while length <= n {
            let half = length / 2
            let step = n / length
            var start = 0
            while start < n {
                for k in 0..<half {
                    let twiddle = k * step
                    let wr = cosTable[twiddle]
                    let wi = -sinTable[twiddle]
                    let a = start + k
                    let b = a + half
                    let xr = real[b] * wr - imaginary[b] * wi
                    let xi = real[b] * wi + imaginary[b] * wr
                    real[b] = real[a] - xr
                    imaginary[b] = imaginary[a] - xi
                    real[a] += xr
                    imaginary[a] += xi
                }
                start += length
            }
            length <<= 1
        }
        var result = [Float](repeating: 0, count: n / 2 + 1)
        for k in 0...(n / 2) {
            result[k] = (real[k] * real[k] + imaginary[k] * imaginary[k]).squareRoot()
        }
        return result
    }
}

#if canImport(Accelerate)
/// vDSP-backed real FFT. `vDSP_fft_zrip` returns values scaled by 2 and packs the Nyquist bin
/// into the imaginary part of bin 0; this wrapper undoes both.
final class AcceleratedFFT {
    let size: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private var realPart: [Float]
    private var imaginaryPart: [Float]

    init?(size: Int) {
        var bits = 0
        while (1 << bits) < size { bits += 1 }
        guard let setup = vDSP_create_fftsetup(vDSP_Length(bits), FFTRadix(kFFTRadix2)) else { return nil }
        self.size = size
        self.log2n = vDSP_Length(bits)
        self.setup = setup
        self.realPart = [Float](repeating: 0, count: size / 2)
        self.imaginaryPart = [Float](repeating: 0, count: size / 2)
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
    }

    func magnitudes(_ input: [Float]) -> [Float] {
        let half = size / 2
        var result = [Float](repeating: 0, count: half + 1)
        let fftSetup = setup
        let bits = log2n
        realPart.withUnsafeMutableBufferPointer { realBuffer in
            imaginaryPart.withUnsafeMutableBufferPointer { imaginaryBuffer in
                guard let realBase = realBuffer.baseAddress, let imaginaryBase = imaginaryBuffer.baseAddress else { return }
                var split = DSPSplitComplex(realp: realBase, imagp: imaginaryBase)
                input.withUnsafeBufferPointer { inputBuffer in
                    guard let inputBase = inputBuffer.baseAddress else { return }
                    inputBase.withMemoryRebound(to: DSPComplex.self, capacity: half) { complexBase in
                        vDSP_ctoz(complexBase, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, bits, FFTDirection(FFT_FORWARD))
                result[0] = Swift.abs(realBase[0]) * 0.5
                result[half] = Swift.abs(imaginaryBase[0]) * 0.5
                for k in 1..<half {
                    let re = realBase[k]
                    let im = imaginaryBase[k]
                    result[k] = (re * re + im * im).squareRoot() * 0.5
                }
            }
        }
        return result
    }
}
#endif
