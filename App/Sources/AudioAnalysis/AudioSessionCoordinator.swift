import AVFoundation
import Foundation

/// Single owner of the shared `AVAudioSession`.
///
/// * Tracking with the microphone: `.playAndRecord` in `.measurement` mode (no automatic gain or
///   voice processing, so measured levels are real), routed to the speaker so relaxation sounds and
///   the in-app alarm stay audible. Recording with an active session is what legitimately keeps the
///   app running overnight with the screen locked (`UIBackgroundModes: audio`).
/// * Only playing sounds: `.playback`.
/// * Nothing active: the session is released so other apps get their audio back.
@MainActor
final class AudioSessionCoordinator {
    static let shared = AudioSessionCoordinator()

    private(set) var isRecording = false
    private(set) var isPlaying = false

    func setRecording(_ active: Bool) throws {
        isRecording = active
        try apply()
    }

    func setPlayback(_ active: Bool) {
        isPlaying = active
        do {
            try apply()
        } catch {
            Log.audio.error("Audio session update failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Re-activates the session after an interruption (phone call, Siri) has ended.
    func reactivate() {
        do {
            try apply()
        } catch {
            Log.audio.error("Audio session reactivation failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func apply() throws {
        let session = AVAudioSession.sharedInstance()
        if isRecording {
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP])
            try? session.setPreferredIOBufferDuration(0.1)
            try session.setActive(true)
        } else if isPlaying {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}
