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
    func requestAuthorization() async -> Bool
    /// Replaces every scheduled system alarm with the given set, including
    /// the pre-armed follow-up chains behind the soonest occurrences.
    func sync(alarms: [Alarm]) async
    /// Removes everything for one alarm — deletion, not dismissal.
    func cancel(alarmID: UUID) async
    func scheduleSnooze(alarm: Alarm, at date: Date) async
    func cancelAll() async

    /// Arms the live follow-up chain from `base`. Necessary because a
    /// physical button press dismisses the alarm that is currently sounding —
    /// but only that one.
    func scheduleBackstops(for alarm: Alarm, from base: Date) async
    /// Rolls the live chain forward while the app is alive and ringing.
    func refreshBackstops(for alarm: Alarm, now: Date) async
    /// Stands the follow-up chain down once the mission is verified complete.
    func cancelBackstops(alarmID: UUID)
    /// Stops whatever is alerting for this alarm right now, leaving anything
    /// scheduled for later untouched.
    func stopAlerting(alarmID: UUID)
    /// One line for the Diagnostics screen.
    var diagnosticSummary: String { get }
}

public extension SystemAlarmBackend {
    func scheduleBackstops(for alarm: Alarm, from base: Date) async {}
    func refreshBackstops(for alarm: Alarm, now: Date) async {}
    func cancelBackstops(alarmID: UUID) {}
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
    @Published public private(set) var lastRebuildAt: Date?
    @Published public private(set) var pendingNotificationCount = 0
    /// Last time the live backstop chain was armed or rolled forward.
    @Published public private(set) var lastBackstopArmAt: Date?

    private var rebuildTask: Task<Void, Never>?

    private init() {
        systemBackend = SystemAlarmBackendFactory.make()
    }

    /// True when a real system-level alarm is doing the work, which is what
    /// lets the alarm sound through Silent mode and Focus.
    public var usesSystemAlarms: Bool {
        (systemBackend?.isSupported ?? false) && systemAlarmsAuthorized
    }

    public var systemBackendName: String {
        systemBackend?.isSupported == true ? "AlarmKit" : "Notifications"
    }

    /// What will bring the user back if the app is killed.
    public var reSummonDescription: String {
        usesSystemAlarms ? "AlarmKit backstops + notification chain" : "Notification chain"
    }

    public var backendDiagnostics: String {
        systemBackend?.diagnosticSummary ?? "No system backend"
    }

    // MARK: Authorization

    public func requestAllAuthorizations() async {
        notifications.registerCategories()
        notificationsAuthorized = await notifications.requestAuthorization()

        if let backend = systemBackend, backend.isSupported {
            systemAlarmsAuthorized = await backend.requestAuthorization()
        }
        log.info(
            "Authorization — notifications: \(self.notificationsAuthorized, privacy: .public), system: \(self.systemAlarmsAuthorized, privacy: .public)"
        )
    }

    public func refreshAuthorizationStatus() async {
        notificationsAuthorized = await notifications.authorizationStatus() == .authorized
        systemAlarmsAuthorized = systemBackend?.isAuthorized ?? false
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
        // With system alarms active the chain is the re-summon layer: it is
        // kept, but offset past the first alert so the two never stack. The
        // user can still switch it off.
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
        await notifications.scheduleSnooze(alarm: alarm, fireAt: date)
        await systemBackend?.scheduleSnooze(alarm: alarm, at: date)
    }

    /// Arms the live follow-up chain when an alarm starts ringing.
    public func armBackstops(for alarm: Alarm) async {
        await systemBackend?.scheduleBackstops(for: alarm, from: Date())
        lastBackstopArmAt = Date()
    }

    /// Keeps the live chain ahead of a ringing app.
    public func refreshBackstops(for alarm: Alarm) async {
        let now = Date()
        await systemBackend?.refreshBackstops(for: alarm, now: now)
        lastBackstopArmAt = now
    }

    /// Stands the follow-up chain down. Refuses unless the event is one that
    /// `BackstopPolicy` allows — nothing but verified completion may end it.
    public func standDownBackstops(alarmID: UUID, on event: BackstopPolicy.Event) {
        guard BackstopPolicy.mayStandDown(on: event) else {
            log.error("Refused to stand down backstops on \(event.rawValue, privacy: .public)")
            return
        }
        systemBackend?.cancelBackstops(alarmID: alarmID)
        lastBackstopArmAt = nil
    }

    public func cancelSnooze(alarmID: UUID) async {
        await notifications.cancelSnooze(alarmID: alarmID)
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
