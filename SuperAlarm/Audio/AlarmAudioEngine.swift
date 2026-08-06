import Foundation
import AVFoundation
import Combine
import os.log
#if canImport(UIKit)
import UIKit
#endif

/// Plays the alarm.
///
/// Three things make this louder and harder to defeat than a plain
/// `AVAudioPlayer`:
///
/// 1. The `.playback` audio session category ignores the hardware ringer
///    switch, so the alarm sounds even with the phone on silent.
/// 2. The hardware output volume is pushed up when the alarm starts, and held
///    there — lowering it with the side buttons is undone within half a second
///    while `lockVolume` is set.
/// 3. A near-silent looping file keeps the audio session (and therefore the
///    process) alive in the background between alarms, so the app is still
///    running when it is time to ring.
@MainActor
public final class AlarmAudioEngine: ObservableObject {
    public static let shared = AlarmAudioEngine()

    private let log = Logger(subsystem: "io.superalarm", category: "audio")

    // Players ---------------------------------------------------------------
    private var alarmPlayer: AVAudioPlayer?
    private var keepAlivePlayer: AVAudioPlayer?
    private var previewPlayer: AVAudioPlayer?

    // Timers ----------------------------------------------------------------
    private var rampTimer: Timer?
    private var volumeLockTimer: Timer?
    private var previewStopWork: DispatchWorkItem?

    // State -----------------------------------------------------------------
    @Published public private(set) var isRinging = false
    @Published public private(set) var isPreviewing = false
    @Published public private(set) var previewingToneID: String?

    /// Volume the hardware was at before the alarm raised it, so it can be
    /// put back afterwards.
    private var restoreSystemVolume: Float?
    /// Level the volume lock enforces.
    private var lockedVolumeTarget: Float = 1.0
    private var lockVolume = false
    /// Target app-level gain once any ramp completes.
    private var targetGain: Float = 1.0
    /// Progress through the gradual-volume ramp.
    private var rampStep = 0
    private var observersInstalled = false

    private init() {
        installObservers()
    }

    // MARK: - Session

    /// Category that ignores the mute switch. `duckOthers` quiets music rather
    /// than killing it, so a podcast left playing overnight does not vanish.
    private func activateAlarmSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.duckOthers])
            try session.setActive(true, options: [])
        } catch {
            log.error("Alarm session activation failed: \(String(describing: error), privacy: .public)")
            // Retry without options — some routes reject duckOthers.
            try? session.setCategory(.playback, mode: .default)
            try? session.setActive(true)
        }
    }

    private func activateBackgroundSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true, options: [])
        } catch {
            log.error("Keep-alive session activation failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func deactivateSession() {
        guard keepAlivePlayer == nil, previewPlayer == nil else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    // MARK: - Ringing

    /// Starts the alarm. `tone` is resolved by the caller so the random-sound
    /// option can pick a different one each time.
    public func startAlarm(tone: AlarmTone, settings: SoundSettings, lockVolume shouldLock: Bool) {
        stopPreview()
        stopKeepAlive()

        guard let url = SoundBundle.url(forFileNamed: tone.fileName) else {
            log.error("Missing tone file \(tone.fileName, privacy: .public)")
            // Even with no audio the alarm must still be dismissible, so carry
            // on with vibration only rather than bailing out.
            beginVibration(settings)
            isRinging = true
            return
        }

        activateAlarmSession()
        SystemVolume.shared.prepare()

        // Remember where the volume was so it can be restored on dismissal.
        if restoreSystemVolume == nil {
            restoreSystemVolume = SystemVolume.shared.current
        }

        targetGain = Float(max(0, min(1, settings.volume)))
        lockedVolumeTarget = settings.overrideSystemVolume ? 1.0 : SystemVolume.shared.current
        lockVolume = shouldLock

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.numberOfLoops = -1
            player.volume = settings.gradualIncrease ? 0.05 : targetGain
            player.prepareToPlay()
            player.play()
            alarmPlayer = player
        } catch {
            log.error("Failed to start alarm audio: \(String(describing: error), privacy: .public)")
        }

        if settings.overrideSystemVolume {
            if settings.gradualIncrease {
                SystemVolume.shared.ramp(to: 1.0, over: min(settings.gradualRampSeconds, 30))
            } else {
                SystemVolume.shared.set(1.0)
            }
        }

        if settings.gradualIncrease {
            startRamp(to: targetGain, over: settings.gradualRampSeconds)
        }

        if shouldLock {
            startVolumeLock()
        }

        beginVibration(settings)
        isRinging = true
        log.info("Alarm started with tone \(tone.id, privacy: .public)")
    }

    /// Plays a quieter version of the alarm — used by the pre-alarm heads-up.
    public func startPreAlarm(tone: AlarmTone, volumeScale: Double) {
        stopPreview()
        guard let url = SoundBundle.url(forFileNamed: tone.fileName) else { return }
        activateAlarmSession()
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.numberOfLoops = 0
            player.volume = Float(max(0.02, min(1, volumeScale)))
            player.prepareToPlay()
            player.play()
            alarmPlayer = player
            isRinging = true
        } catch {
            log.error("Pre-alarm playback failed: \(String(describing: error), privacy: .public)")
        }
    }

    public func stopAlarm() {
        rampTimer?.invalidate()
        rampTimer = nil
        stopVolumeLock()

        alarmPlayer?.stop()
        alarmPlayer = nil

        HapticEngine.shared.stopAlarmVibration()

        // Put the volume back where the user had it.
        if let previous = restoreSystemVolume {
            SystemVolume.shared.set(previous)
            restoreSystemVolume = nil
        }

        isRinging = false
        deactivateSession()
        log.info("Alarm stopped")
    }

    /// Briefly mutes without tearing anything down — used while a mission
    /// needs the microphone or camera, or during a voice briefing.
    public func setMuted(_ muted: Bool) {
        alarmPlayer?.volume = muted ? 0 : targetGain
    }

    /// Holds the alarm at a low level until released. Used while a spoken
    /// briefing plays over the top.
    public func setDucked(_ ducked: Bool) {
        guard let player = alarmPlayer else { return }
        player.setVolume(ducked ? targetGain * 0.12 : targetGain, fadeDuration: 0.3)
    }

    /// Momentarily drops the alarm to a low level, then restores it. Used so a
    /// spoken briefing can be heard over the top.
    public func duck(for duration: TimeInterval) {
        guard let player = alarmPlayer else { return }
        player.setVolume(targetGain * 0.15, fadeDuration: 0.3)
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            Task { @MainActor in
                guard let self, let player = self.alarmPlayer else { return }
                player.setVolume(self.targetGain, fadeDuration: 0.4)
            }
        }
    }

    private func beginVibration(_ settings: SoundSettings) {
        guard settings.vibrate else { return }
        HapticEngine.shared.startAlarmVibration()
    }

    // MARK: - Volume ramp and lock

    private func startRamp(to target: Float, over duration: TimeInterval) {
        rampTimer?.invalidate()
        guard duration > 0 else {
            alarmPlayer?.volume = target
            return
        }

        let tick = 0.25
        let steps = max(1, Int(duration / tick))
        // Held as instance state rather than a captured local: the Task's
        // closure is @Sendable, and mutating a captured var from one is
        // rejected by the compiler.
        rampStep = 0

        let timer = Timer(timeInterval: tick, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self, let player = self.alarmPlayer else {
                    timer.invalidate()
                    return
                }
                self.rampStep += 1
                // Ease in so the first few seconds are genuinely gentle.
                let progress = Float(self.rampStep) / Float(steps)
                let eased = progress * progress
                player.volume = min(target, 0.05 + (target - 0.05) * eased)
                if self.rampStep >= steps {
                    player.volume = target
                    timer.invalidate()
                    self.rampTimer = nil
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        rampTimer = timer
    }

    /// Restores the output volume whenever it is lowered while ringing, which
    /// neutralises the side buttons as an escape hatch.
    private func startVolumeLock() {
        stopVolumeLock()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.lockVolume, self.isRinging else { return }
                if SystemVolume.shared.current < self.lockedVolumeTarget - 0.02 {
                    SystemVolume.shared.set(self.lockedVolumeTarget)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        volumeLockTimer = timer
    }

    private func stopVolumeLock() {
        volumeLockTimer?.invalidate()
        volumeLockTimer = nil
        lockVolume = false
    }

    // MARK: - Background keep-alive

    /// Plays an inaudible loop so the audio session — and with it the app —
    /// survives in the background until the next alarm. Only meaningful on
    /// systems without AlarmKit; the scheduler decides whether to call it.
    public func startKeepAlive() {
        guard keepAlivePlayer == nil, !isRinging else { return }
        guard let url = SoundBundle.url(forFileNamed: SoundCatalog.keepAliveFileName) else {
            log.error("Keep-alive file missing")
            return
        }
        activateBackgroundSession()
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.numberOfLoops = -1
            player.volume = 0.008
            player.prepareToPlay()
            player.play()
            keepAlivePlayer = player
            log.info("Keep-alive started")
        } catch {
            log.error("Keep-alive failed: \(String(describing: error), privacy: .public)")
        }
    }

    public func stopKeepAlive() {
        keepAlivePlayer?.stop()
        keepAlivePlayer = nil
    }

    public var isKeepAliveRunning: Bool { keepAlivePlayer != nil }

    // MARK: - Preview

    /// Plays a short sample in the sound picker. Deliberately does not touch
    /// the system volume.
    public func preview(tone: AlarmTone, volume: Double = 0.7, seconds: TimeInterval = 8) {
        if previewingToneID == tone.id {
            stopPreview()
            return
        }
        stopPreview()
        guard let url = SoundBundle.url(forFileNamed: tone.fileName) else { return }

        // Preview should still be audible on silent, matching how the alarm
        // will actually behave.
        activateAlarmSession()
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.numberOfLoops = -1
            player.volume = Float(max(0, min(1, volume)))
            player.prepareToPlay()
            player.play()
            previewPlayer = player
            previewingToneID = tone.id
            isPreviewing = true

            let work = DispatchWorkItem { [weak self] in
                Task { @MainActor in self?.stopPreview() }
            }
            previewStopWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
        } catch {
            log.error("Preview failed: \(String(describing: error), privacy: .public)")
        }
    }

    public func stopPreview() {
        previewStopWork?.cancel()
        previewStopWork = nil
        previewPlayer?.stop()
        previewPlayer = nil
        previewingToneID = nil
        isPreviewing = false
        deactivateSession()
    }

    // MARK: - System notifications

    private func installObservers() {
        guard !observersInstalled else { return }
        observersInstalled = true

        // Phone calls and other interruptions: resume as soon as we are
        // allowed to. An alarm that gives up after a call is useless.
        _ = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in self?.handleInterruption(notification) }
        }

        // Unplugging headphones normally pauses playback. Not here.
        _ = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in self?.handleRouteChange(notification) }
        }

        // Another app taking the session out from under us.
        _ = NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleMediaServicesReset() }
        }
    }

    private func handleInterruption(_ notification: Notification) {
        guard
            let info = notification.userInfo,
            let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: raw)
        else { return }

        switch type {
        case .began:
            log.info("Audio interrupted")
        case .ended:
            if isRinging {
                activateAlarmSession()
                alarmPlayer?.play()
            } else if keepAlivePlayer != nil {
                activateBackgroundSession()
                keepAlivePlayer?.play()
            }
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ notification: Notification) {
        guard
            let info = notification.userInfo,
            let raw = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
            let reason = AVAudioSession.RouteChangeReason(rawValue: raw)
        else { return }

        switch reason {
        case .oldDeviceUnavailable, .newDeviceAvailable, .override:
            // Keep going on whatever route is now active.
            if isRinging, let player = alarmPlayer, !player.isPlaying {
                activateAlarmSession()
                player.play()
            }
            if !isRinging, let player = keepAlivePlayer, !player.isPlaying {
                activateBackgroundSession()
                player.play()
            }
        default:
            break
        }
    }

    private func handleMediaServicesReset() {
        log.error("Media services reset — rebuilding players")
        let wasRinging = isRinging
        let wasKeepAlive = keepAlivePlayer != nil
        alarmPlayer = nil
        keepAlivePlayer = nil
        previewPlayer = nil

        if wasRinging {
            // The ring coordinator owns the tone choice; ask it to restart.
            NotificationCenter.default.post(name: .alarmAudioNeedsRestart, object: nil)
        } else if wasKeepAlive {
            startKeepAlive()
        }
    }
}

public extension Notification.Name {
    /// Posted when the audio stack was torn down underneath a ringing alarm.
    static let alarmAudioNeedsRestart = Notification.Name("io.superalarm.audioNeedsRestart")
}
