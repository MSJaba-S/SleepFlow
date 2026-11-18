import AVFoundation
import AudioToolbox
import Foundation
import SwiftUI

/// Alarm tones bundled with the app. All tones are original, synthesised for SleepFlow.
struct AlarmSound: Identifiable, Hashable, Sendable {
    let id: String
    let fileName: String
    let title: LocalizedStringResource

    static let all: [AlarmSound] = [
        AlarmSound(id: "sunrise", fileName: "sunrise.wav", title: "Sunrise"),
        AlarmSound(id: "morningBells", fileName: "morning-bells.wav", title: "Morning bells"),
        AlarmSound(id: "softPulse", fileName: "soft-pulse.wav", title: "Soft pulse"),
        AlarmSound(id: "birdsong", fileName: "birdsong.wav", title: "Birdsong"),
        AlarmSound(id: "classic", fileName: "classic.wav", title: "Classic")
    ]

    static func sound(id: String) -> AlarmSound {
        all.first { $0.id == id } ?? all[0]
    }

    var url: URL? {
        let name = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        return Bundle.main.url(forResource: name, withExtension: ext)
    }
}

/// Plays alarm tones inside the app: previews in settings, and the ringing alarm when the system
/// alarm (AlarmKit) is not available. Volume rises gradually over 30 seconds.
@MainActor
final class AlarmSoundPlayer {
    private var player: AVAudioPlayer?
    private var rampTask: Task<Void, Never>?
    private var vibrationTask: Task<Void, Never>?

    var isPlaying: Bool { player?.isPlaying ?? false }

    func preview(_ sound: AlarmSound) {
        stop()
        guard let url = sound.url, let player = try? AVAudioPlayer(contentsOf: url) else { return }
        AudioSessionCoordinator.shared.setPlayback(true)
        player.volume = 0.6
        player.play()
        self.player = player
        rampTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    /// Rings until stopped, with a gentle volume ramp and optional vibration.
    func ring(_ sound: AlarmSound, vibrate: Bool) {
        stop()
        AudioSessionCoordinator.shared.setPlayback(true)
        if let url = sound.url, let player = try? AVAudioPlayer(contentsOf: url) {
            player.numberOfLoops = -1
            player.volume = 0.15
            player.play()
            self.player = player
            rampTask = Task { [weak self] in
                for step in 1...30 {
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled else { return }
                    self?.player?.volume = min(1, 0.15 + Float(step) * 0.03)
                }
            }
        }
        if vibrate {
            vibrationTask = Task {
                while !Task.isCancelled {
                    AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
    }

    func stop() {
        rampTask?.cancel()
        vibrationTask?.cancel()
        rampTask = nil
        vibrationTask = nil
        player?.stop()
        player = nil
    }
}
