import Foundation

/// The rules for the follow-up alarms that make killing the app pointless.
///
/// iOS will not let an app stop the user from force-quitting it, so the only
/// defence is to make sure something the *system* owns is always about to
/// ring. Two chains cover that:
///
/// * **Pre-armed** — scheduled together with the alarm itself, before it ever
///   fires. If the user presses Stop on the system alert and never opens the
///   app, these bring the alarm back on their own.
/// * **Live** — re-armed from "now" the moment the app starts ringing and
///   then refreshed on a heartbeat while it keeps ringing. While the app is
///   alive the first backstop is always at least `firstOffset` away, so it
///   never interrupts a mission; the instant the process dies the heartbeat
///   stops and the next backstop lands within `firstOffset` seconds.
///
/// Nothing but verified mission completion stands a chain down. That rule is
/// encoded in `mayStandDown(on:)` so it cannot be bypassed by accident.
public enum BackstopPolicy {
    /// Seconds from the base date to each pre-armed follow-up alarm.
    public static let preArmedOffsets: [TimeInterval] = [30, 60, 120, 180, 300, 480, 720]

    /// Seconds from "now" to each live follow-up alarm. Never more than a
    /// minute apart, so a kill at any point is answered within a minute and
    /// the chain keeps coming for eight minutes after that.
    public static let liveOffsets: [TimeInterval] = [30, 60, 90, 120, 180, 240, 300, 360, 420, 480]

    /// Spacing used when the heartbeat rolls an expiring live backstop to the
    /// end of the chain.
    public static let liveTailSpacing: TimeInterval = 60

    /// When system alarms are carrying the first alert, the notification
    /// chain starts this long after the alarm time so the two do not sound on
    /// top of each other. From then on it interleaves with the backstops.
    public static let chainOffsetWithSystemAlarms: TimeInterval = 45

    /// Seconds from a snooze's end to each follow-up armed behind it.
    public static let snoozeOffsets: [TimeInterval] = [30, 60, 120, 180, 300]

    /// How often a ringing app refreshes its live chain. Must be shorter than
    /// the first live offset or a backstop fires while the app is still alive.
    public static let heartbeatInterval: TimeInterval = 15

    /// The earliest live backstop, for tests and diagnostics.
    public static var firstOffset: TimeInterval { liveOffsets.first ?? 0 }

    /// How many upcoming occurrences get a pre-armed chain. Only the soonest
    /// alarms matter: once one has rung and been dealt with, the rebuild
    /// re-arms the next.
    public static let preArmedOccurrenceLimit = 2

    /// Fire dates for a chain.
    public static func dates(from base: Date, offsets: [TimeInterval]) -> [Date] {
        offsets.map { base.addingTimeInterval($0) }
    }

    /// True when the live chain is due for a refresh.
    public static func heartbeatIsDue(lastArmedAt: Date?, now: Date) -> Bool {
        guard let lastArmedAt else { return true }
        return now.timeIntervalSince(lastArmedAt) >= heartbeatInterval
    }

    // MARK: Stand-down rules

    /// Everything that can happen to a ringing alarm.
    public enum Event: String, CaseIterable, Sendable {
        /// The mission was completed and the alarm dismissed for good.
        case missionCompleted
        /// The wake-up check was confirmed (or its mission completed).
        case wakeCheckConfirmed
        /// The alarm rang unattended for its whole auto-stop window.
        case rangOut
        /// The diagnostics emergency exit.
        case forceStopped
        /// The user snoozed. The chain moves behind the snooze; it does not end.
        case snoozed
        /// The user pressed Stop on a system alert or a notification.
        case systemStopButton
        /// The app was backgrounded, force-quit or crashed.
        case appLeft
        /// The user backed out of the mission to the ring screen.
        case missionAbandoned
        /// A wake-up check expired and the alarm is re-ringing.
        case wakeCheckFailed
    }

    /// Whether an event is allowed to cancel the follow-up chain.
    public static func mayStandDown(on event: Event) -> Bool {
        switch event {
        case .missionCompleted, .wakeCheckConfirmed, .rangOut, .forceStopped:
            return true
        case .snoozed, .systemStopButton, .appLeft, .missionAbandoned, .wakeCheckFailed:
            return false
        }
    }

    // MARK: Nag notifications

    /// Seconds after leaving the app before the first "still ringing"
    /// notification lands, and the spacing of the ones after it.
    public static let nagFirstDelay: TimeInterval = 4
    public static let nagSpacing: TimeInterval = 25
    public static let nagCount = 12

    public static func nagDates(from base: Date) -> [Date] {
        (0..<nagCount).map { base.addingTimeInterval(nagFirstDelay + nagSpacing * Double($0)) }
    }
}
