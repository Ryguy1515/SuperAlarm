import Foundation
import AVFoundation
import Combine
import os.log

/// The bedtime ambience player.
///
/// Separate from `AlarmAudioEngine` so that the two can never fight over the
/// same `AVAudioPlayer`: the alarm always takes priority and stops this the
/// moment it fires.
@MainActor
public final class SleepSoundPlayer: ObservableObject {
    public static let shared = SleepSoundPlayer()

    @Published public private(set) var playingID: String?
    @Published public private(set) var secondsRemaining: Int?

    private var player: AVAudioPlayer?
    private var countdown: Timer?
    private let log = Logger(subsystem: "io.superalarm", category: "sleepsound")

    private init() {}

    public var isPlaying: Bool { playingID != nil }

    /// Starts an ambience loop. `stopAt` overrides the configured duration and
    /// is used for the "until alarm" option.
    public func play(_ sound: SleepSound, settings: SleepSoundSettings, stopAt: Date? = nil) {
        if playingID == sound.id {
            stop()
            return
        }
        stop()

        guard let url = SoundBundle.url(forFileNamed: sound.fileName) else {
            log.error("Sleep sound \(sound.fileName, privacy: .public) missing")
            return
        }

        let session = AVAudioSession.sharedInstance()
        do {
            // Mixes so a podcast or audiobook keeps playing alongside.
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            log.error("Sleep session failed: \(String(describing: error), privacy: .public)")
        }

        do {
            let newPlayer = try AVAudioPlayer(contentsOf: url)
            newPlayer.numberOfLoops = -1
            newPlayer.volume = Float(max(0.02, min(1, settings.volume)))
            newPlayer.prepareToPlay()
            newPlayer.play()
            player = newPlayer
            playingID = sound.id
        } catch {
            log.error("Sleep playback failed: \(String(describing: error), privacy: .public)")
            return
        }

        // Work out how long to run for.
        let duration: TimeInterval?
        if let stopAt {
            duration = max(60, stopAt.timeIntervalSinceNow)
        } else if settings.durationMinutes > 0 {
            duration = TimeInterval(settings.durationMinutes * 60)
        } else {
            duration = nil
        }

        if let duration {
            secondsRemaining = Int(duration)
            startCountdown(fadeOut: settings.fadeOut)
        } else {
            secondsRemaining = nil
        }
    }

    private func startCountdown(fadeOut: Bool) {
        countdown?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let remaining = self.secondsRemaining else { return }
                let next = remaining - 1
                self.secondsRemaining = max(0, next)

                // Ease out over the last half minute so it does not cut off.
                if fadeOut, next <= 30, let player = self.player {
                    player.volume = max(0, player.volume * 0.93)
                }

                if next <= 0 { self.stop() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        countdown = timer
    }

    public func stop() {
        countdown?.invalidate()
        countdown = nil
        player?.stop()
        player = nil
        playingID = nil
        secondsRemaining = nil
    }

    public var remainingLabel: String? {
        guard let seconds = secondsRemaining else { return nil }
        let minutes = seconds / 60
        let rest = seconds % 60
        return String(format: "%d:%02d left", minutes, rest)
    }
}
