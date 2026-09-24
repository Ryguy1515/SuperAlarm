import Foundation
import Combine

/// Tracks progress through a mission while the alarm is ringing: how many
/// rounds are left, how many mistakes were made, and how long it all took.
/// Individual mission views own their own puzzle content and report back here.
@MainActor
public final class MissionSession: ObservableObject {
    public let settings: MissionSettings
    public let startedAt: Date

    @Published public private(set) var completedRounds = 0
    @Published public private(set) var failures = 0
    @Published public private(set) var isComplete = false
    /// Seconds left when a time limit is configured.
    @Published public private(set) var secondsRemaining: Int?
    /// Set when the time limit ran out.
    @Published public private(set) var didTimeOut = false

    /// Raised when the mission is finished successfully.
    public var onComplete: (() -> Void)?
    /// Raised when a configured time limit expires.
    public var onTimeout: (() -> Void)?
    /// Raised after every passed round with the new total, so the runtime
    /// can persist progress for a relaunch.
    public var onProgress: ((Int) -> Void)?

    private var timer: Timer?

    /// - Parameters:
    ///   - now: when the mission started. Pass the original start when
    ///     resuming after a relaunch so elapsed time and step counts carry on.
    ///   - completedRounds: rounds already passed before a relaunch.
    ///   - reference: the current time, injectable so tests are not tied to
    ///     the wall clock.
    public init(settings: MissionSettings, now: Date = Date(), completedRounds: Int = 0, reference: Date = Date()) {
        self.settings = settings
        self.startedAt = now
        self.completedRounds = max(0, min(completedRounds, max(1, settings.rounds)))
        if settings.timeLimitSeconds > 0 {
            let elapsed = Int(reference.timeIntervalSince(now))
            secondsRemaining = max(0, settings.timeLimitSeconds - max(0, elapsed))
        }
    }

    deinit {
        timer?.invalidate()
    }

    public var totalRounds: Int { max(1, settings.rounds) }

    /// 1-based round number for display, clamped to the total.
    public var currentRound: Int { min(completedRounds + 1, totalRounds) }

    public var progress: Double {
        totalRounds == 0 ? 1 : Double(completedRounds) / Double(totalRounds)
    }

    public var elapsed: TimeInterval { Date().timeIntervalSince(startedAt) }

    /// Human-readable "Round 2 of 3", omitted entirely for single-round runs.
    public var roundLabel: String? {
        totalRounds > 1 ? "Round \(currentRound) of \(totalRounds)" : nil
    }

    public func startTimerIfNeeded() {
        guard settings.timeLimitSeconds > 0, timer == nil else { return }
        // Named distinctly from the `timer` property: a local of the same name
        // would shadow it for the whole scope, making the guard above a use
        // before declaration.
        let countdownTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(countdownTimer, forMode: .common)
        timer = countdownTimer
    }

    private func tick() {
        guard !isComplete, secondsRemaining != nil else { return }
        // Wall-clock, not tick-counted: a suspended process must not stretch
        // the limit.
        let next = settings.timeLimitSeconds - Int(Date().timeIntervalSince(startedAt))
        secondsRemaining = max(0, next)
        if next <= 0 {
            didTimeOut = true
            stopTimer()
            onTimeout?()
        }
    }

    public func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    /// Marks the current round as passed. Completes the session once every
    /// round is done.
    public func passRound() {
        guard !isComplete else { return }
        completedRounds += 1
        HapticEngine.shared.success()
        onProgress?(completedRounds)

        if completedRounds >= totalRounds {
            isComplete = true
            stopTimer()
            onComplete?()
        }
    }

    /// Records a wrong answer. Missions decide for themselves whether a
    /// failure also resets their current puzzle.
    public func registerFailure() {
        guard !isComplete else { return }
        failures += 1
        HapticEngine.shared.failure()
    }

    /// Completes everything at once — used by the emergency exit when a
    /// sensor a mission depends on turns out to be unavailable.
    public func forceComplete() {
        guard !isComplete else { return }
        completedRounds = totalRounds
        isComplete = true
        stopTimer()
        onComplete?()
    }
}
