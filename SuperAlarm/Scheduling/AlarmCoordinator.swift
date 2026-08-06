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
    /// Replaces every scheduled system alarm with the given set.
    func sync(alarms: [Alarm]) async
    func cancel(alarmID: UUID) async
    func scheduleSnooze(alarm: Alarm, at date: Date) async
    func cancelAll() async

    /// Arms the follow-up alarms that keep firing until a mission is actually
    /// completed. Necessary because a physical button press dismisses the
    /// alarm that is currently sounding — but only that one.
    func scheduleBackstops(for alarm: Alarm, from base: Date) async
    /// Stands the follow-up chain down once the mission is verified complete.
    func cancelBackstops(alarmID: UUID)
}

public extension SystemAlarmBackend {
    func scheduleBackstops(for alarm: Alarm, from base: Date) async {}
    func cancelBackstops(alarmID: UUID) {}
}

/// Fans scheduling out to every available mechanism.
///
/// Redundancy is deliberate: AlarmKit is the loudest and most reliable, but
/// the notification chain is kept in place underneath it so that a revoked
/// permission, an OS quirk, or a downgrade cannot leave the user with no alarm
/// at all. Duplicate audible alerts are avoided because dismissing an alarm
/// clears every pending request associated with it.
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
        // When AlarmKit is doing the work, the notification chain is muted so
        // the user does not get two overlapping alerts for one alarm. The
        // chain is still scheduled — silently — if the user explicitly opts
        // into the redundant backup.
        let chainsEnabled = !usesSystemAlarms || settings.redundantNotificationBackup
        await notifications.rebuild(alarms: alarms, settings: settings, chainsEnabled: chainsEnabled)

        if let backend = systemBackend, backend.isSupported {
            await backend.sync(alarms: alarms.filter(\.isEnabled))
        }

        lastRebuildAt = Date()
        pendingNotificationCount = await notifications.pendingCount()
        log.info("Rebuild complete for \(alarms.filter(\.isEnabled).count, privacy: .public) enabled alarms")
    }

    // MARK: Per-alarm operations

    public func cancel(alarmID: UUID) async {
        await notifications.cancelEverything(for: alarmID)
        await systemBackend?.cancel(alarmID: alarmID)
    }

    /// Clears the audible chain for an alarm without touching its long-term
    /// safety nets — used the moment an alarm is dismissed.
    public func silence(alarmID: UUID) async {
        await notifications.cancelChain(for: alarmID)
        await systemBackend?.cancel(alarmID: alarmID)
    }

    public func scheduleSnooze(alarm: Alarm, at date: Date) async {
        await notifications.scheduleSnooze(alarm: alarm, fireAt: date)
        await systemBackend?.scheduleSnooze(alarm: alarm, at: date)
    }

    /// Arms the follow-up chain when an alarm starts ringing.
    public func armBackstops(for alarm: Alarm) async {
        await systemBackend?.scheduleBackstops(for: alarm, from: Date())
    }

    /// Stands the follow-up chain down once the mission is verified complete.
    public func standDownBackstops(alarmID: UUID) {
        systemBackend?.cancelBackstops(alarmID: alarmID)
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

    public func cancelEverything() async {
        await notifications.cancelAll()
        await systemBackend?.cancelAll()
    }
}
