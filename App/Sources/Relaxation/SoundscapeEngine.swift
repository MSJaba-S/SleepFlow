import AVFoundation
import Foundation
import os
import SwiftUI

/// Relaxation soundscapes. Every sound is generated in real time by SleepFlow's own synthesiser,
/// so there are no recordings and no licensing questions.
enum Soundscape: String, CaseIterable, Identifiable, Sendable {
    case rain
    case ocean
    case forest
    case ambient
    case whiteNoise
    case pinkNoise
    case brownNoise
    case fan

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .rain: return "Rain"
        case .ocean: return "Ocean"
        case .forest: return "Forest"
        case .ambient: return "Ambient"
        case .whiteNoise: return "White noise"
        case .pinkNoise: return "Pink noise"
        case .brownNoise: return "Brown noise"
        case .fan: return "Fan"
        }
    }

    var subtitle: LocalizedStringKey {
        switch self {
        case .rain: return "Steady rain with soft drops"
        case .ocean: return "Slow waves on a beach"
        case .forest: return "Wind in the trees and distant birds"
        case .ambient: return "Warm, slowly evolving tones"
        case .whiteNoise: return "Even noise that masks sounds"
        case .pinkNoise: return "Softer, balanced noise"
        case .brownNoise: return "Deep, low rumble"
        case .fan: return "Constant airflow"
        }
    }

    var symbol: String {
        switch self {
        case .rain: return "cloud.rain"
        case .ocean: return "water.waves"
        case .forest: return "leaf"
        case .ambient: return "sparkles"
        case .whiteNoise: return "waveform"
        case .pinkNoise: return "waveform.path"
        case .brownNoise: return "waveform.path.ecg"
        case .fan: return "fan"
        }
    }
}

/// Parameters handed from the main actor to the render thread.
struct SynthParameters: Sendable {
    var soundscape: Soundscape = .rain
    var gain: Float = 0
}

/// Generator state. Owned by the render thread; parameters arrive through a non-blocking lock.
final class SynthState: @unchecked Sendable {
    private let parameters = OSAllocatedUnfairLock(initialState: SynthParameters())
    private let sampleRate: Double

    // Render-thread state.
    private var soundscape: Soundscape = .rain
    private var targetGain: Float = 0
    private var gain: Float = 0
    private var seedLeft: UInt64 = 0x9E37_79B9_7F4A_7C15
    private var seedRight: UInt64 = 0xD1B5_4A32_D192_ED03
    private var pinkLeft = PinkFilter()
    private var pinkRight = PinkFilter()
    private var brownLeft: Float = 0
    private var brownRight: Float = 0
    private var lowLeft: Float = 0
    private var lowRight: Float = 0
    private var highState: Float = 0
    private var highPrevious: Float = 0
    private var time: Double = 0
    private var wavePeriod: Double = 9
    private var waveStart: Double = 0
    private var drops: [Drop] = Array(repeating: Drop(), count: 12)
    private var chirps: [Chirp] = []
    private var nextBirdTime: Double = 3
    private var oscillatorPhases: [Double] = Array(repeating: 0, count: 6)
    private let chord: [Double] = [110.0, 164.81, 220.0, 261.63, 329.63, 392.0]

    struct PinkFilter {
        var b0: Float = 0, b1: Float = 0, b2: Float = 0
        mutating func next(_ white: Float) -> Float {
            b0 = 0.99765 * b0 + white * 0.0990460
            b1 = 0.96300 * b1 + white * 0.2965164
            b2 = 0.57000 * b2 + white * 1.0526913
            return (b0 + b1 + b2 + white * 0.1848) * 0.11
        }
    }

    struct Drop {
        var active = false
        var phase: Double = 0
        var frequency: Double = 3_000
        var amplitude: Float = 0
        var envelope: Float = 0
        var decay: Float = 0.999
    }

    struct Chirp {
        var start: Double
        var duration: Double
        var from: Double
        var to: Double
        var amplitude: Float
        var phase: Double = 0
    }

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
    }

    func update(_ change: @Sendable (inout SynthParameters) -> Void) {
        parameters.withLock { change(&$0) }
    }

    private func random(_ seed: inout UInt64) -> Float {
        seed ^= seed << 13
        seed ^= seed >> 7
        seed ^= seed << 17
        return Float(Int64(bitPattern: seed) >> 11) / Float(1 << 52)
    }

    private func unit(_ seed: inout UInt64) -> Double {
        Double(random(&seed)) * 0.5 + 0.5
    }

    func render(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>?) {
        if let snapshot = parameters.withLockIfAvailable({ $0 }) {
            if snapshot.soundscape != soundscape {
                soundscape = snapshot.soundscape
                time = 0
                waveStart = 0
            }
            targetGain = snapshot.gain
        }
        let dt = 1.0 / sampleRate
        for frame in 0..<frames {
            gain += (targetGain - gain) * 0.0004
            let (l, r) = sample()
            left[frame] = l * gain
            right?[frame] = r * gain
            time += dt
        }
    }

    private func sample() -> (Float, Float) {
        let wl = random(&seedLeft)
        let wr = random(&seedRight)
        switch soundscape {
        case .whiteNoise:
            return (wl * 0.25, wr * 0.25)
        case .pinkNoise:
            return (pinkLeft.next(wl), pinkRight.next(wr))
        case .brownNoise:
            brownLeft = (brownLeft + 0.02 * wl) / 1.02
            brownRight = (brownRight + 0.02 * wr) / 1.02
            return (brownLeft * 3.2, brownRight * 3.2)
        case .fan:
            brownLeft = (brownLeft + 0.02 * wl) / 1.02
            brownRight = (brownRight + 0.02 * wr) / 1.02
            let pl = pinkLeft.next(wl)
            let pr = pinkRight.next(wr)
            lowLeft += (pl - lowLeft) * 0.08
            lowRight += (pr - lowRight) * 0.08
            let flutter = Float(1 + 0.03 * sin(2 * Double.pi * 1.7 * time))
            return ((brownLeft * 2.2 + lowLeft * 0.9) * flutter, (brownRight * 2.2 + lowRight * 0.9) * flutter)
        case .rain:
            return rain(wl, wr)
        case .ocean:
            return ocean(wl, wr)
        case .forest:
            return forest(wl, wr)
        case .ambient:
            return ambient(wl, wr)
        }
    }

    private func rain(_ wl: Float, _ wr: Float) -> (Float, Float) {
        let pl = pinkLeft.next(wl)
        let pr = pinkRight.next(wr)
        // Gentle high-pass for the hiss of rain.
        let hp = 0.94 * (highState + pl - highPrevious)
        highPrevious = pl
        highState = hp
        brownLeft = (brownLeft + 0.02 * wl) / 1.02
        var drops: Float = 0
        // About 35 drops per second.
        if unit(&seedLeft) < 35 / sampleRate, let free = self.drops.firstIndex(where: { !$0.active }) {
            self.drops[free] = Drop(
                active: true,
                phase: 0,
                frequency: 2_000 + unit(&seedRight) * 4_000,
                amplitude: Float(0.05 + unit(&seedRight) * 0.18),
                envelope: 1,
                decay: Float(exp(-1 / (sampleRate * (0.002 + unit(&seedLeft) * 0.004))))
            )
        }
        for index in self.drops.indices where self.drops[index].active {
            var drop = self.drops[index]
            drop.phase += 2 * Double.pi * drop.frequency / sampleRate
            drops += Float(sin(drop.phase)) * drop.amplitude * drop.envelope
            drop.envelope *= drop.decay
            if drop.envelope < 0.001 { drop.active = false }
            self.drops[index] = drop
        }
        let base = hp * 0.55 + brownLeft * 0.9
        return (base + drops, base * 0.96 + drops * 0.8 + pr * 0.05)
    }

    private func ocean(_ wl: Float, _ wr: Float) -> (Float, Float) {
        brownLeft = (brownLeft + 0.02 * wl) / 1.02
        brownRight = (brownRight + 0.02 * wr) / 1.02
        let phase = (time - waveStart) / wavePeriod
        if phase >= 1 {
            waveStart = time
            wavePeriod = 7.5 + unit(&seedLeft) * 4
        }
        let swell = pow(sin(Double.pi * min(max(phase, 0), 1)), 2)
        let envelope = Float(0.22 + 0.78 * pow(swell, 1.4))
        let hiss = pinkLeft.next(wl) * envelope * envelope * envelope * 0.5
        let hissRight = pinkRight.next(wr) * envelope * envelope * envelope * 0.5
        return (brownLeft * 3.0 * envelope + hiss, brownRight * 3.0 * envelope + hissRight)
    }

    private func forest(_ wl: Float, _ wr: Float) -> (Float, Float) {
        let pl = pinkLeft.next(wl)
        let pr = pinkRight.next(wr)
        lowLeft += (pl - lowLeft) * 0.06
        lowRight += (pr - lowRight) * 0.06
        let gust = Float(0.55 + 0.3 * sin(2 * Double.pi * 0.05 * time) + 0.15 * sin(2 * Double.pi * 0.013 * time + 1))
        var bird: Float = 0
        if time >= nextBirdTime {
            let count = 2 + Int(unit(&seedRight) * 4)
            let base = 2_800 + unit(&seedLeft) * 1_800
            for index in 0..<count {
                chirps.append(Chirp(start: time + Double(index) * 0.18, duration: 0.09 + unit(&seedRight) * 0.06, from: base, to: base * 0.72, amplitude: Float(0.03 + unit(&seedLeft) * 0.04)))
            }
            nextBirdTime = time + 3 + unit(&seedLeft) * 8
        }
        if !chirps.isEmpty {
            for index in chirps.indices {
                let progress = (time - chirps[index].start) / chirps[index].duration
                guard progress >= 0, progress <= 1 else { continue }
                let frequency = chirps[index].from + (chirps[index].to - chirps[index].from) * progress
                chirps[index].phase += 2 * Double.pi * frequency / sampleRate
                bird += Float(sin(chirps[index].phase) * sin(Double.pi * progress)) * chirps[index].amplitude
            }
            chirps.removeAll { time > $0.start + $0.duration }
        }
        return (lowLeft * 2.4 * gust + bird, lowRight * 2.4 * gust + bird * 0.6)
    }

    private func ambient(_ wl: Float, _ wr: Float) -> (Float, Float) {
        var left: Double = 0
        var right: Double = 0
        for index in chord.indices {
            let detune = 0.25 * sin(2 * Double.pi * 0.021 * time + Double(index))
            oscillatorPhases[index] += 2 * Double.pi * (chord[index] + detune) / sampleRate
            if oscillatorPhases[index] > 2 * Double.pi { oscillatorPhases[index] -= 2 * Double.pi }
            let swell = 0.5 + 0.5 * sin(2 * Double.pi * (0.03 + 0.011 * Double(index)) * time + Double(index) * 1.3)
            let value = sin(oscillatorPhases[index]) * swell
            let pan = 0.5 + 0.4 * sin(2 * Double.pi * 0.017 * time + Double(index) * 2.1)
            left += value * (1 - pan)
            right += value * pan
        }
        let air = pinkLeft.next(wl) * 0.03
        let airRight = pinkRight.next(wr) * 0.03
        return (Float(left * 0.07) + air, Float(right * 0.07) + airRight)
    }
}

/// Plays soundscapes through its own `AVAudioEngine`.
@MainActor
final class SoundscapeEngine {
    private let engine = AVAudioEngine()
    private let reverb = AVAudioUnitReverb()
    private let state: SynthState
    private let source: AVAudioSourceNode
    private(set) var isRunning = false
    private var observer: NSObjectProtocol?

    init() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        state = SynthState(sampleRate: format.sampleRate)
        source = SoundscapeEngine.makeSource(state: state, format: format)
        engine.attach(source)
        engine.attach(reverb)
        reverb.loadFactoryPreset(.largeHall)
        reverb.wetDryMix = 15
        engine.connect(source, to: reverb, format: format)
        engine.connect(reverb, to: engine.mainMixerNode, format: format)
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.restartIfNeeded() }
        }
    }

    /// The render block is created outside the main actor: it runs on the real-time audio thread.
    nonisolated private static func makeSource(state: SynthState, format: AVAudioFormat) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard buffers.count > 0, let left = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let right = buffers.count > 1 ? buffers[1].mData?.assumingMemoryBound(to: Float.self) : nil
            state.render(frames: Int(frameCount), left: left, right: right)
            return noErr
        }
    }

    func play(_ soundscape: Soundscape, gain: Float) throws {
        reverb.wetDryMix = soundscape == .ambient ? 45 : (soundscape == .forest ? 22 : 8)
        state.update { parameters in
            parameters.soundscape = soundscape
            parameters.gain = gain
        }
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
        isRunning = true
    }

    func setGain(_ gain: Float) {
        state.update { $0.gain = gain }
    }

    func stop() {
        state.update { $0.gain = 0 }
        engine.pause()
        isRunning = false
    }

    private func restartIfNeeded() {
        guard isRunning, !engine.isRunning else { return }
        try? engine.start()
    }
}
