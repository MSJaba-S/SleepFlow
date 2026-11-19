import AVFoundation
import Foundation
import Observation

/// Plays the short sound clips a user chose to keep (snoring, talking …).
@MainActor
@Observable
final class ClipPlayer {
    private(set) var playingName: String?

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var endTask: Task<Void, Never>?

    func toggle(_ name: String) {
        if playingName == name {
            stop()
        } else {
            play(name)
        }
    }

    func play(_ name: String) {
        stop()
        let url = FileLocations.clipURL(named: name)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        AudioSessionCoordinator.shared.setPlayback(true)
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            player.play()
            self.player = player
            playingName = name
            let duration = player.duration
            endTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(duration + 0.2))
                guard !Task.isCancelled else { return }
                self?.finished(name)
            }
        } catch {
            Log.audio.error("Clip playback failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stop() {
        endTask?.cancel()
        endTask = nil
        player?.stop()
        player = nil
        // The audio session is left as it is: relaxation sounds may share it.
        playingName = nil
    }

    private func finished(_ name: String) {
        guard playingName == name else { return }
        stop()
    }
}
