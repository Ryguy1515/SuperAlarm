import Foundation

/// Decides what a relaunch does with a saved ring state.
///
/// After a crash or a force-quit the app must come back up on the ring screen
/// with the mission still owed — never on the alarm list, never reset. But a
/// state file can also be genuinely stale (the phone died at 7am and is turned
/// on at 9pm), and ringing out of nowhere then would be a bug of its own. The
/// decision is pure so it can be tested against every phase and age.
enum RingStateRestorePlan: Equatable, Sendable {
    /// Resume the outstanding alarm in this phase, restarting audio if the
    /// phase is audible.
    case resume(AlarmRuntime.Phase, restartAudio: Bool)
    /// The saved state is too old to act on; log the occurrence and clear it.
    case discardAsStale
    /// Nothing worth restoring.
    case nothing

    /// How long an unfinished alarm stays resumable after it fired. Generous,
    /// because the whole point is that leaving the app must not end the
    /// alarm; but bounded, so a phone that was off all day does not ring at
    /// dinner time.
    static let staleAfter: TimeInterval = 2 * 60 * 60

    static func make(from state: PersistedRingState, now: Date) -> RingStateRestorePlan {
        // A fire date more than a minute in the future means the clock moved;
        // nothing sensible can be resumed from that.
        if state.firedAt.timeIntervalSince(now) > 60 { return .discardAsStale }

        // The freshest timestamp the phase carries decides staleness: a snooze
        // or wake-up check that was armed hours ago is stale even if the alarm
        // originally fired a little before that.
        let anchor: Date
        switch state.phase {
        case .snoozed:
            anchor = state.snoozeEndsAt ?? state.firedAt
        case .wakeCheckPending:
            anchor = state.wakeCheckFireAt ?? state.firedAt
        case .wakeCheckRinging:
            anchor = state.wakeCheckDeadline ?? state.firedAt
        case .mission:
            anchor = state.missionStartedAt ?? state.firedAt
        case .ringing, .idle:
            anchor = state.firedAt
        }
        if now.timeIntervalSince(anchor) > staleAfter {
            return .discardAsStale
        }

        switch state.phase {
        case .idle:
            return .nothing
        case .ringing:
            return .resume(.ringing, restartAudio: true)
        case .mission:
            // The mission itself is resumed: the runner rebuilds it from the
            // persisted progress, and the alarm keeps sounding underneath.
            return .resume(.mission, restartAudio: true)
        case .snoozed:
            return .resume(.snoozed, restartAudio: false)
        case .wakeCheckPending:
            return .resume(.wakeCheckPending, restartAudio: false)
        case .wakeCheckRinging:
            return .resume(.wakeCheckRinging, restartAudio: true)
        }
    }
}
