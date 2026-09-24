import UIKit
import UserNotifications
import os.log

/// Bridges the notification system into the runtime and keeps the app's state
/// safe across suspension.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Set by the app once the runtime exists. A notification tapped on a
    /// cold launch arrives before that, so responses are queued until then.
    var runtime: AlarmRuntime? {
        didSet { replayQueuedResponses() }
    }
    var store: AlarmStore?

    private let log = Logger(subsystem: "io.superalarm", category: "appdelegate")
    private var queuedResponses: [(action: String, payload: Payload)] = []

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        NotificationScheduler.shared.registerCategories()
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        store?.flush()
    }

    /// Fires when the app switcher opens — the last moment before a
    /// force-quit that the app is guaranteed to run. The runtime uses it to
    /// arm the still-ringing reminders.
    func applicationWillResignActive(_ application: UIApplication) {
        runtime?.handleResignActive()
    }

    func applicationWillTerminate(_ application: UIApplication) {
        store?.flush()
        runtime?.handleTermination()
    }

    // MARK: - Notification delegate

    /// Called when a notification arrives while the app is open.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let info = Payload(notification.request.content.userInfo)

        await MainActor.run {
            handle(payload: info)
        }

        let isAlreadyRinging = await MainActor.run { runtime?.isPresenting ?? false }

        // While the ring screen is up the chain and the still-ringing nags
        // are redundant: keep them out of the way entirely rather than
        // stacking banners and sounds on top of the alarm.
        if isAlreadyRinging {
            switch info.kind {
            case .alarm, .snooze, .safetyNet, .wakeCheck:
                return [.list]
            case .preAlarm, .bedtime, .none:
                return [.banner, .list]
            }
        }
        return [.banner, .list, .sound]
    }

    /// Called when the user taps a notification or one of its actions.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = Payload(response.notification.request.content.userInfo)
        let action = response.actionIdentifier

        await MainActor.run {
            process(action: action, payload: info)
        }
    }

    @MainActor
    private func process(action: String, payload: Payload) {
        guard runtime != nil else {
            // Cold launch: the runtime is created a moment later; replay then.
            queuedResponses.append((action, payload))
            return
        }

        switch action {
        case AlarmNotification.actionSnooze:
            handle(payload: payload)
            // Snoozing from a banner is only honoured on the ring screen;
            // from inside a mission it would be a way round the mission.
            runtime?.snooze()

        case AlarmNotification.actionImUp:
            handle(payload: payload)
            runtime?.confirmAwake()

        case AlarmNotification.actionStop, UNNotificationDefaultActionIdentifier:
            // Opening the app puts the ring screen on screen, where the
            // mission (if any) must still be completed.
            handle(payload: payload)

        case UNNotificationDismissActionIdentifier:
            // Swiping a chain link away must not count as turning the
            // alarm off — the rest of the chain keeps going.
            break

        default:
            handle(payload: payload)
        }
    }

    @MainActor
    private func replayQueuedResponses() {
        guard runtime != nil, !queuedResponses.isEmpty else { return }
        let pending = queuedResponses
        queuedResponses.removeAll()
        for entry in pending {
            process(action: entry.action, payload: entry.payload)
        }
    }

    @MainActor
    private func handle(payload: Payload) {
        guard let runtime, let alarmID = payload.alarmID else { return }
        guard let kind = payload.kind else { return }

        switch kind {
        case .bedtime, .preAlarm:
            return
        case .alarm, .snooze, .safetyNet, .wakeCheck:
            // Safety-net payloads carry no fire date; the runtime resolves
            // the occurrence from the schedule so it is recorded correctly.
            runtime.handleNotification(
                alarmID: alarmID,
                occurrence: payload.fireDate,
                kind: kind
            )
        }
    }

    /// Typed view over a notification's `userInfo`.
    private struct Payload {
        let alarmID: UUID?
        let kind: AlarmNotification.Kind?
        let fireDate: Date?

        init(_ userInfo: [AnyHashable: Any]) {
            alarmID = (userInfo[AlarmNotification.keyAlarmID] as? String).flatMap(UUID.init(uuidString:))
            kind = (userInfo[AlarmNotification.keyKind] as? String).flatMap(AlarmNotification.Kind.init(rawValue:))
            if let seconds = userInfo[AlarmNotification.keyFireDate] as? TimeInterval {
                fireDate = Date(timeIntervalSince1970: seconds)
            } else if let seconds = userInfo[AlarmNotification.keyFireDate] as? Double {
                fireDate = Date(timeIntervalSince1970: seconds)
            } else {
                fireDate = nil
            }
        }
    }
}
