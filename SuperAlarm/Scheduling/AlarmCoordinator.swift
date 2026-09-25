import Foundation
import Combine
import os.log

/// A system-level alarm mechanism the coordinator can delegate to.
///
/// On iOS 26 this is backed by AlarmKit, which is the only way to break
/// through Silent mode and Focus and to show a real alarm on the Lock Screen.
/// On earlier systems no backend is available and the notification layer plus
/// background audio carry the whole load.
@MainActor
public protocol SystemAlarmBackend: AnyObject {
    /// True when the OS supports the backend and it can be used.
    var isSupported: Bool { get }
    /// True once the user has granted permission.
    var isAuthorized: Bool { get }
    /// True once the user has explicitly declined, so the UI can send them
    /// to Settings instead of asking again.
    var isDenied: Bool { get }
    func requestAuthorization() async -> Bool
    /// Replaces every scheduled system alarm with the given set, including
    /// the pre-armed follow-up chains behind the soonest occurrences.
    func sync(alarms: [Alarm]) async
    /// Removes everything for one alarm — deletion, not dismissal.
    func cancel(alarmID: UUID) async
    func scheduleSnooze(alarm: Alarm, at date: Date) async
    /// Removes the snooze / wake-check re-ring alarm scheduled by
    /// `scheduleSnooze`, without touching the follow-up chain.
    func cancelSnooze(alarmID: UUID) async
    func cancelAll() async

    /// Arms the live follow-up chain from `base`. Necessary because a
    /// physical button press dismisses the alarm that is currently sounding —
    /// but only that one.
    func scheduleBackstops(for alarm: Alarm, from base: Date) async
    /// Rolls the live chain forward while the app is alive and ringing.
    func refreshBackstops(for alarm: Alarm, now: Date) async
    /// Stands the follow-up chain down once the mission is verified complete.
    func cancelBackstops(alarmID: UUID) async
    /// Stops whatever is alerting for this alarm right now, leaving anything
    /// scheduled for later untouched.
    func stopAlerting(alarmID: UUID)
    /// One line for the Diagnostics screen.
    var diagnosticSummary: String { get }
}

public extension SystemAlarmBackend {
    var isDenied: Bool { false }
    func scheduleBackstops(for alarm: Alarm, from base: Date) async {}
    func refreshBackstops(for alarm: Alarm, now: Date) async {}
    func cancelBackstops(alarmID: UUID) async {}
    func cancelSnooze(alarmID: UUID) async {}
    func stopAlerting(alarmID: UUID) {}
    var diagnosticSummary: String { "Unavailable" }
}

/// Fans scheduling out to every available mechanism.
///
/// Redundancy is deliberate: AlarmKit is the loudest and most reliable, but
/// the notification chain is kept in place underneath it so that a revoked
/// permission, an OS quirk, a force-quit or a downgrade cannot leave the user
/// with no alarm at all. When system alarms carry the first alert the chain
/// is offset so the two do not sound on top of each other.
@MainActor
public final class AlarmCoordinator: ObservableObject {
    public static let shared = AlarmCoordinator()

    private let log = Logger(subsystem: "io.superalarm", category: "coordinator")
    private let notifications = NotificationScheduler.shared

    /// Populated at launch when the OS provides one.
    public private(set) var systemBackend: SystemAlarmBackend?

    @Published public private(set) var notificationsAuthorized = false
    @Published public private(set) var systemAlarmsAuthorized = false
    /// The system alarm permission was declined outright.
    @Published public private(set) var systemAlarmsDenied = false
    @Published public private(set) var lastRebuildAt: Date?
    @Published public private(set) var pendingNotificationCount = 0
    /// Last time the live backstop chain was armed or rolled forward.
    @Published public private(set) var lastBackstopArmAt: Date?

    private var rebuildTask: Task<Void, Never>?
    /// Every mutation of the system alarms and notification chains runs
    /// through this one chain of tasks. Arming a chain is read-schedule-
    /// cancel-store with awaits in the middle; two of them interleaving
    /// orphan a set of system alarms that nothing can cancel afterwards.
    private var pipeline: Task<Void, Never>?

    private init() {
        systemBackend = SystemAlarmBackendFactory.make()
    }

    /// Runs `operation` after every previously enqueued operation finishes.
    private func serialized(_ operation: @escaping @MainActor () async -> Void) async {
        let previous = pipeline
        let task = Task { @MainActor in
            await previous?.value
            await operation()
        }
        pipeline = task
        await task.value
    }

    /// True when a real system-level alarm is doing the work, which is what
    /// lets the alarm sound through Silent mode and Focus.
    public var usesSystemAlarms: Bool {
        (systemBackend?.isSupported ?? false) && systemAlarmsAuthorized
    }

    public var systemBackendName: String {
        systemBackend?.isSupported == true ? "System alarms (iOS 26)" : "Notifications"
    }

    /// What will bring the user back if the app is killed.
    public var reSummonDescription: String {
        usesSystemAlarms ? "System follow-up alarms and repeat notifications" : "Repeat notifications"
    }

    public var backendDiagnostics: String {
        systemBackend?.diagnosticSummary ?? "Not available"
    }

    // MARK: Authorization

    public func requestAllAuthorizations() async {
        notifications.registerCategories()

        // The system alarm permission first: it is the one that matters, and
        // the second prompt in a row is the one people reflexively dismiss.
        if let backend = systemBackend, backend.isSupported {
            systemAlarmsAuthorized = await backend.requestAuthorization()
            systemAlarmsDenied = backend.isDenied
        }
        notificationsAuthorized = await notifications.requestAuthorization()
        log.info(
            "Authorization — notifications: \(self.notificationsAuthorized, privacy: .public), system: \(self.systemAlarmsAuthorized, privacy: .public)"
        )
    }

    public func refreshAuthorizationStatus() async {
        notificationsAuthorized = await notifications.authorizationStatus() == .authorized
        systemAlarmsAuthorized = systemBackend?.isAuthorized ?? false
        systemAlarmsDenied = systemBackend?.isDenied ?? false
        pendingNotificationCount = await notifications.pendingCount()
    }

    // MARK: Rebuild

    /// Rebuilds every scheduled alarm. Coalesces rapid successive calls, which
    /// happen naturally while the user is editing.
    public func rebuild(alarms: [Alarm], settings: AppSettings) {
        rebuildTask?.cancel()
        rebuildTask = Task { [weak self] in
            // Small delay so a burst of edits results in one rebuild.
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.performRebuild(alarms: alarms, settings: settings)
        }
    }

    /// Rebuilds immediately, awaiting completion.
    public func rebuildNow(alarms: [Alarm], settings: AppSettings) async {
        rebuildTask?.cancel()
        await performRebuild(alarms: alarms, settings: settings)
    }

    private func performRebuild(alarms: [Alarm], settings: AppSettings) async {
        await serialized { [self] in
            // With system alarms active the chain is the re-summon layer: it
            // is kept, but offset past the first alert so the two never
            // stack. The user can still switch it off.
            let chainsEnabled = !usesSystemAlarms || settings.redundantNotificationBackup
            let chainOffset = usesSystemAlarms ? BackstopPolicy.chainOffsetWithSystemAlarms : 0
            await notifications.rebuild(
                alarms: alarms,
                settings: settings,
                chainsEnabled: chainsEnabled,
                chainOffset: chainOffset
            )

            if let backend = systemBackend, backend.isSupported {
                await backend.sync(alarms: alarms.filter(\.isEnabled))
            }

            lastRebuildAt = Date()
            pendingNotificationCount = await notifications.pendingCount()
            log.info("Rebuild complete for \(alarms.filter(\.isEnabled).count, privacy: .public) enabled alarms")
        }
    }

    // MARK: Per-alarm operations

    /// Removes everything for an alarm. Deletion, not dismissal.
    public func cancel(alarmID: UUID) async {
        await notifications.cancelEverything(for: alarmID)
        await systemBackend?.cancel(alarmID: alarmID)
    }

    /// Clears the audible chain for an alarm and stops whatever the system is
    /// alerting for it right now, without touching its long-term safety nets
    /// or its follow-up chain.
    public func silence(alarmID: UUID) async {
        await notifications.cancelChain(for: alarmID)
        systemBackend?.stopAlerting(alarmID: alarmID)
    }

    /// The hand-over: the app's own audio is playing, so the system alert
    /// that summoned it can stop. Call only after the live chain is armed.
    public func stopSystemAlert(alarmID: UUID) {
        systemBackend?.stopAlerting(alarmID: alarmID)
    }

    public func scheduleSnooze(alarm: Alarm, at date: Date) async {
        await serialized { [self] in
            await notifications.scheduleSnooze(alarm: alarm, fireAt: date)
            await systemBackend?.scheduleSnooze(alarm: alarm, at: date)
        }
    }

    /// Arms the live follow-up chain when an alarm starts ringing: AlarmKit
    /// backstops when system alarms are active, an audible notification
    /// chain otherwise. The timestamp is set before the awaits so the
    /// heartbeat does not start a second arm while this one is in flight.
    public func armBackstops(for alarm: Alarm, occurrence: Date) async {
        lastBackstopArmAt = Date()
        await serialized { [self] in
            if usesSystemAlarms {
                await systemBackend?.scheduleBackstops(for: alarm, from: Date())
            } else {
                await notifications.scheduleLiveChain(alarm: alarm, occurrence: occurrence, from: Date())
            }
        }
    }

    /// Keeps the live chain ahead of a ringing app.
    public func refreshBackstops(for alarm: Alarm, occurrence: Date) async {
        let now = Date()
        lastBackstopArmAt = now
        await serialized { [self] in
            if usesSystemAlarms {
                await systemBackend?.refreshBackstops(for: alarm, now: now)
            } else {
                await notifications.scheduleLiveChain(alarm: alarm, occurrence: occurrence, from: Date())
            }
        }
    }

    /// Stands the follow-up chain down. Refuses unless the event is one that
    /// `BackstopPolicy` allows — nothing but verified completion may end it.
    /// Queued behind any arm in flight, so a chain being armed right now is
    /// cancelled too rather than orphaned.
    public func standDownBackstops(alarmID: UUID, on event: BackstopPolicy.Event) {
        guard BackstopPolicy.mayStandDown(on: event) else {
            log.error("Refused to stand down backstops on \(event.rawValue, privacy: .public)")
            return
        }
        lastBackstopArmAt = nil
        Task {
            await serialized { [self] in
                await systemBackend?.cancelBackstops(alarmID: alarmID)
                await systemBackend?.cancelSnooze(alarmID: alarmID)
                await notifications.cancelLiveChain(alarmID: alarmID)
            }
        }
    }

    /// Cancels the snooze / wake-check re-ring on both backends.
    public func cancelSnooze(alarmID: UUID) async {
        await serialized { [self] in
            await notifications.cancelSnooze(alarmID: alarmID)
            await systemBackend?.cancelSnooze(alarmID: alarmID)
        }
    }

    public func scheduleWakeUpCheck(alarm: Alarm, at date: Date) async {
        await notifications.scheduleWakeUpCheck(alarm: alarm, fireAt: date)
    }

    public func cancelWakeUpCheck(alarmID: UUID) async {
        await notifications.cancelWakeUpCheck(alarmID: alarmID)
    }

    // MARK: Still-ringing nags

    /// Schedules the "Alarm still ringing — finish your mission" reminders
    /// that land seconds after the user leaves a ringing app.
    public func scheduleStillRingingNag(for alarm: Alarm, occurrence: Date) async {
        await notifications.scheduleStillRingingNag(alarm: alarm, occurrence: occurrence, from: Date())
    }

    public func cancelStillRingingNag(alarmID: UUID) async {
        await notifications.cancelStillRingingNag(alarmID: alarmID)
    }

    public func cancelEverything() async {
        await notifications.cancelAll()
        await systemBackend?.cancelAll()
    }
}
