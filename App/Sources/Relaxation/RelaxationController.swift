import Foundation
import Observation
import SwiftUI

/// Plays relaxation soundscapes with a sleep timer and a gentle fade-out.
@MainActor
@Observable
final class RelaxationController {
    private(set) var current: Soundscape?
    private(set) var isPlaying = false
    var volume: Double = 0.6 {
        didSet { if isPlaying { engine?.setGain(Float(volume * fadeFactor)) } }
    }
    private(set) var timerEnd: Date?
    private(set) var timerMinutes: Int?
    private(set) var errorMessage: String?

    /// Informs sleep tracking so sound events are treated with care while audio plays.
    @ObservationIgnored var onPlaybackChanged: ((Bool) -> Void)?

    @ObservationIgnored private var engine: SoundscapeEngine?
    @ObservationIgnored private var timerTask: Task<Void, Never>?
    @ObservationIgnored private var fadeFactor: Double = 1

    static let timerOptions: [Int] = [15, 30, 45, 60, 90]

    func play(_ soundscape: Soundscape) {
        if engine == nil { engine = SoundscapeEngine() }
        AudioSessionCoordinator.shared.setPlayback(true)
        fadeFactor = 1
        do {
            try engine?.play(soundscape, gain: Float(volume))
            current = soundscape
            isPlaying = true
            errorMessage = nil
            onPlaybackChanged?(true)
        } catch {
            errorMessage = error.localizedDescription
            Log.audio.error("Soundscape failed: \(error.localizedDescription, privacy: .public)")
        }
        if let minutes = timerMinutes, timerEnd == nil {
            setTimer(minutes: minutes)
        }
    }

    func toggle(_ soundscape: Soundscape) {
        if isPlaying && current == soundscape {
            stop()
        } else {
            play(soundscape)
        }
    }

    func stop() {
        timerTask?.cancel()
        timerTask = nil
        timerEnd = nil
        engine?.stop()
        isPlaying = false
        AudioSessionCoordinator.shared.setPlayback(false)
        onPlaybackChanged?(false)
    }

    /// Sleep timer: playback fades out over the last 30 seconds and stops.
    func setTimer(minutes: Int?) {
        timerTask?.cancel()
        timerMinutes = minutes
        guard let minutes else {
            timerEnd = nil
            return
        }
        let end = Date().addingTimeInterval(TimeInterval(minutes * 60))
        timerEnd = isPlaying ? end : nil
        guard isPlaying else { return }
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                let remaining = end.timeIntervalSinceNow
                if remaining <= 0 {
                    self.stop()
                    return
                }
                if remaining < 30 {
                    self.fadeFactor = remaining / 30
                    self.engine?.setGain(Float(self.volume * self.fadeFactor))
                }
            }
        }
    }

    var remainingTimerText: String? {
        guard let timerEnd else { return nil }
        let remaining = max(0, timerEnd.timeIntervalSinceNow)
        let minutes = Int(remaining) / 60
        let seconds = Int(remaining) % 60
        return "\(minutes):" + (seconds < 10 ? "0" : "") + "\(seconds)"
    }
}

/// Guided breathing patterns (seconds per phase).
struct BreathingPattern: Identifiable, Hashable, Sendable {
    enum Phase: String, Sendable {
        case inhale, hold, exhale, rest
    }

    let id: String
    let title: LocalizedStringResource
    let detail: LocalizedStringResource
    let inhale: Double
    let holdAfterInhale: Double
    let exhale: Double
    let holdAfterExhale: Double

    var cycleLength: Double { inhale + holdAfterInhale + exhale + holdAfterExhale }

    static let all: [BreathingPattern] = [
        BreathingPattern(id: "calm", title: "Calm breathing", detail: "In for 4, out for 6. Lengthening the exhale helps the body slow down.", inhale: 4, holdAfterInhale: 0, exhale: 6, holdAfterExhale: 0),
        BreathingPattern(id: "478", title: "4-7-8", detail: "In for 4, hold for 7, out for 8. A classic before sleep.", inhale: 4, holdAfterInhale: 7, exhale: 8, holdAfterExhale: 0),
        BreathingPattern(id: "box", title: "Box breathing", detail: "Four equal steps of 4 seconds for a steady rhythm.", inhale: 4, holdAfterInhale: 4, exhale: 4, holdAfterExhale: 4)
    ]

    /// Phase and progress (0...1) at a time offset into the exercise.
    func phase(at elapsed: Double) -> (phase: Phase, progress: Double, remaining: Double) {
        let t = elapsed.truncatingRemainder(dividingBy: max(cycleLength, 0.1))
        if t < inhale { return (.inhale, t / inhale, inhale - t) }
        var offset = inhale
        if t < offset + holdAfterInhale { return (.hold, (t - offset) / holdAfterInhale, offset + holdAfterInhale - t) }
        offset += holdAfterInhale
        if t < offset + exhale { return (.exhale, (t - offset) / exhale, offset + exhale - t) }
        offset += exhale
        let rest = max(holdAfterExhale, 0.001)
        return (.rest, (t - offset) / rest, offset + holdAfterExhale - t)
    }
}
