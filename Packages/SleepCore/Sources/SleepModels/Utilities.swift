import Foundation

// MARK: - Deterministic random numbers (used by the simulator and tests)

/// SplitMix64: small, fast, deterministic generator. Same seed gives the same night on every platform.
public struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

public extension RandomNumberGenerator {
    /// Uniform value in [0, 1).
    mutating func unit() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    /// Normally distributed value (Box-Muller).
    mutating func gaussian(mean: Double = 0, sd: Double = 1) -> Double {
        var u1 = unit()
        if u1 < 1e-12 { u1 = 1e-12 }
        let u2 = unit()
        let z = (-2.0 * log(u1)).squareRoot() * cos(2.0 * Double.pi * u2)
        return mean + sd * z
    }

    /// Exponentially distributed value with the given mean.
    mutating func exponential(mean: Double) -> Double {
        var u = unit()
        if u < 1e-12 { u = 1e-12 }
        return -mean * log(u)
    }

    mutating func chance(_ probability: Double) -> Bool {
        unit() < probability
    }

    mutating func uniform(_ range: ClosedRange<Double>) -> Double {
        range.lowerBound + (range.upperBound - range.lowerBound) * unit()
    }
}

// MARK: - Statistics helpers

public enum Stats {
    public static func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    /// Linear-interpolated percentile, `p` in 0...1.
    public static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return percentileOfSorted(sorted, p)
    }

    public static func percentileOfSorted(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        if sorted.count == 1 { return sorted[0] }
        let clamped = clamp(p, 0, 1)
        let position = clamped * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = Swift.min(lower + 1, sorted.count - 1)
        let fraction = position - Double(lower)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * fraction
    }

    public static func median(_ values: [Double]) -> Double {
        percentile(values, 0.5)
    }

    public static func standardDeviation(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let m = mean(values)
        let variance = values.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(values.count - 1)
        return variance.squareRoot()
    }

    public static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        Swift.min(Swift.max(value, lower), upper)
    }

    /// Smooth 0→1 transition between `a` and `b` (Hermite smoothstep). Handles a > b by inverting.
    public static func rise(_ x: Double, _ a: Double, _ b: Double) -> Double {
        if a == b { return x >= b ? 1 : 0 }
        let t = clamp((x - a) / (b - a), 0, 1)
        return t * t * (3 - 2 * t)
    }

    /// Smooth 1→0 transition between `a` and `b`.
    public static func fall(_ x: Double, _ a: Double, _ b: Double) -> Double {
        1 - rise(x, a, b)
    }

    /// Plateau membership: rises between a…b, stays 1 until c, falls until d.
    public static func band(_ x: Double, _ a: Double, _ b: Double, _ c: Double, _ d: Double) -> Double {
        rise(x, a, b) * fall(x, c, d)
    }
}

// MARK: - Ring buffer

/// Fixed-capacity FIFO that overwrites the oldest element.
public struct RingBuffer<Element> {
    private var storage: [Element?]
    private var head = 0
    public private(set) var count = 0

    public init(capacity: Int) {
        precondition(capacity > 0, "RingBuffer capacity must be positive")
        storage = Array(repeating: nil, count: capacity)
    }

    public var capacity: Int { storage.count }
    public var isEmpty: Bool { count == 0 }
    public var isFull: Bool { count == storage.count }

    public mutating func append(_ element: Element) {
        let index = (head + count) % storage.count
        storage[index] = element
        if count < storage.count {
            count += 1
        } else {
            head = (head + 1) % storage.count
        }
    }

    public mutating func removeAll() {
        storage = Array(repeating: nil, count: storage.count)
        head = 0
        count = 0
    }

    /// Elements from oldest to newest.
    public var elements: [Element] {
        (0..<count).compactMap { storage[(head + $0) % storage.count] }
    }

    public var last: Element? {
        guard count > 0 else { return nil }
        return storage[(head + count - 1) % storage.count]
    }
}

extension RingBuffer: Sendable where Element: Sendable {}

// MARK: - Clock time helpers

public enum ClockTime {
    /// Minutes since local midnight (0..<1440).
    public static func minutesSinceMidnight(_ date: Date, calendar: Calendar) -> Double {
        let components = calendar.dateComponents([.hour, .minute, .second], from: date)
        return Double(components.hour ?? 0) * 60 + Double(components.minute ?? 0) + Double(components.second ?? 0) / 60
    }

    /// Circular mean of clock times given in minutes since midnight. Handles wrap-around at midnight
    /// (the mean of 23:30 and 00:30 is 00:00, not 12:00).
    public static func circularMean(minutes: [Double]) -> Double? {
        guard !minutes.isEmpty else { return nil }
        var x = 0.0
        var y = 0.0
        for value in minutes {
            let angle = value / 1440.0 * 2 * Double.pi
            x += cos(angle)
            y += sin(angle)
        }
        if Swift.abs(x) < 1e-9 && Swift.abs(y) < 1e-9 { return nil }
        var angle = atan2(y, x)
        if angle < 0 { angle += 2 * Double.pi }
        return angle / (2 * Double.pi) * 1440.0
    }

    /// Smallest difference between two clock times in minutes (0...720).
    public static func circularDistance(_ a: Double, _ b: Double) -> Double {
        let diff = Swift.abs(a - b).truncatingRemainder(dividingBy: 1440)
        return Swift.min(diff, 1440 - diff)
    }

    /// Circular standard deviation in minutes.
    public static func circularSpread(minutes: [Double]) -> Double {
        guard minutes.count > 1, let mean = circularMean(minutes: minutes) else { return 0 }
        let squared = minutes.map { circularDistance($0, mean) * circularDistance($0, mean) }
        return (squared.reduce(0, +) / Double(minutes.count)).squareRoot()
    }
}

/// Signed seconds between two optional dates.
public func interval(from start: Date?, to end: Date?) -> TimeInterval? {
    guard let start, let end else { return nil }
    return end.timeIntervalSince(start)
}
