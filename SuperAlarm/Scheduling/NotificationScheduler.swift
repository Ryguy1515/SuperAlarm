import Foundation
import UserNotifications
import os.log

// MARK: - Identifiers

/// Notification identifiers, categories and payload keys.
///
/// Identifiers are structured so that a rebuild can find and remove exactly
/// the requests it owns without disturbing transient ones like an active
/// snooze or a pending wake-up check.
public enum AlarmNotification {
    public static let categoryAlarm = "SUPERALARM_ALARM"
    public static let categoryPreAlarm = "SUPERALARM_PREALARM"
    public static let categoryWakeCheck = "SUPERALARM_WAKECHECK"
    public static let categoryBedtime = "SUPERALARM_BEDTIME"

    public static let actionSnooze = "SUPERALARM_SNOOZE"
    public static let actionStop = "SUPERALARM_STOP"
    public static let actionImUp = "SUPERALARM_IM_UP"

    // Payload keys
    public static let keyAlarmID = "alarmID"
    public static let keyFireDate = "fireDate"
    public static let keyKind = "kind"
    public static let keyChainIndex = "chainIndex"

    public enum Kind: String {
        case alarm, preAlarm, wakeCheck, snooze, safetyNet, bedtime
    }

    // Identifier prefixes
    static let prefixChain = "chain"
    static let prefixPre = "pre"
    static let prefixNet = "net"
    static let prefixSnooze = "snooze"
    static let prefixWakeCheck = "wake"
    static let bedtimeIdentifier = "bedtime"

    /// Prefixes owned by `rebuild` and therefore safe to clear on each pass.
    static let rebuildablePrefixes = [prefixChain, prefixPre, prefixNet]

    static func identifier(_ prefix: String, _ alarmID: UUID, _ date: Date, _ index: Int = 0) -> String {
        "\(prefix)|\(alarmID.uuidString)|\(Int(date.timeIntervalSince1970))|\(index)"
    }

    static func prefix(of identifier: String) -> String {
        identifier.components(separatedBy: "|").first ?? ""
    }

    public static func alarmID(from identifier: String) -> UUID? {
        let parts = identifier.components(separatedBy: "|")
        guard parts.count > 1 else { return nil }
        return UUID(uuidString: parts[1])
    }
}

// MARK: - Scheduler

/// Schedules the local-notification layer of the alarm system.
///
/// On iOS 26 this is a backup behind AlarmKit; below that it is the primary
/// mechanism. Two complementary strategies are used:
///
/// * **Chains** — a run of one-shot notifications 30 s apart starting at the
///   fire time. Each carries a 28 s custom sound, so together they produce a
///   continuous noise for the whole ring window even if the app has been
///   terminated.
/// * **Safety nets** — a single repeating calendar trigger per alarm day.
///   These never expire, so an alarm still fires months from now even if the
///   app is never opened again.
///
/// iOS keeps at most 64 pending requests per app, so everything below is
/// written against an explicit budget.
public final class NotificationScheduler: @unchecked Sendable {
    public static let shared = NotificationScheduler()

    private let center = UNUserNotificationCenter.current()
    private let log = Logger(subsystem: "io.superalarm", category: "notifications")

    /// iOS drops anything past 64. Leave headroom for snoozes and wake checks.
    private let budget = 56
    /// Seconds between links in a chain. Slightly longer than the 28 s tones.
    private let chainSpacing: TimeInterval = 30
    /// Never schedule a chain longer than this.
    private let maxChainLength = 40

    private init() {}

    // MARK: Authorization

    public func registerCategories() {
        let snooze = UNNotificationAction(
            identifier: AlarmNotification.actionSnooze,
            title: "Snooze",
            options: []
        )
        // Turning the alarm off has to open the app so the mission can run.
        let stop = UNNotificationAction(
            identifier: AlarmNotification.actionStop,
            title: "Turn off",
            options: [.foreground]
        )
        let imUp = UNNotificationAction(
            identifier: AlarmNotification.actionImUp,
            title: "I'm up",
            options: [.foreground]
        )

        let alarmCategory = UNNotificationCategory(
            identifier: AlarmNotification.categoryAlarm,
            actions: [snooze, stop],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        let preCategory = UNNotificationCategory(
            identifier: AlarmNotification.categoryPreAlarm,
            actions: [],
            intentIdentifiers: [],
            options: []
        )
        let wakeCategory = UNNotificationCategory(
            identifier: AlarmNotification.categoryWakeCheck,
            actions: [imUp],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        let bedtimeCategory = UNNotificationCategory(
            identifier: AlarmNotification.categoryBedtime,
            actions: [],
            intentIdentifiers: [],
            options: []
        )

        center.setNotificationCategories([alarmCategory, preCategory, wakeCategory, bedtimeCategory])
    }

    @discardableResult
    public func requestAuthorization() async -> Bool {
        do {
            // .criticalAlert is requested optimistically: without the Apple
            // entitlement it is simply not granted, and everything else still
            // works. AlarmKit is what actually breaks through Silent mode.
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            log.info("Notification authorization granted: \(granted, privacy: .public)")
            return granted
        } catch {
            log.error("Authorization failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    public func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    public func pendingCount() async -> Int {
        await center.pendingNotificationRequests().count
    }

    // MARK: Rebuild

    /// Tears down and rebuilds every alarm-derived notification.
    ///
    /// `chainsEnabled` is false when a system-level alarm backend is handling
    /// the audible alert, so that only the non-overlapping extras — pre-alarm
    /// heads-ups and the bedtime reminder — are scheduled here.
    public func rebuild(alarms: [Alarm], settings: AppSettings, chainsEnabled: Bool = true) async {
        await clearRebuildable()

        let enabled = alarms.filter(\.isEnabled)
        guard !enabled.isEmpty else {
            await scheduleBedtimeReminder(settings: settings)
            log.info("No enabled alarms; cleared schedule")
            return
        }

        guard chainsEnabled else {
            _ = await schedulePreAlarms(for: enabled, budget: 6)
            await scheduleBedtimeReminder(settings: settings)
            log.info("System alarms active — notification chains suppressed")
            return
        }

        var remaining = budget

        // 1. Safety nets first. They are cheap (one request each) and are the
        //    only thing guaranteeing an alarm still fires weeks from now.
        remaining -= await scheduleSafetyNets(for: enabled, budget: min(remaining, 24))

        // 2. Pre-alarms for anything coming up in the next week.
        remaining -= await schedulePreAlarms(for: enabled, budget: min(remaining, 6))

        // 3. Spend everything left on dense chains, soonest occurrence first.
        await scheduleChains(for: enabled, budget: remaining)

        await scheduleBedtimeReminder(settings: settings)

        let pending = await pendingCount()
        log.info("Rebuilt schedule — \(pending, privacy: .public) pending requests")
    }

    /// Removes only the requests `rebuild` owns.
    private func clearRebuildable() async {
        let pending = await center.pendingNotificationRequests()
        let ids = pending
            .map(\.identifier)
            .filter { AlarmNotification.rebuildablePrefixes.contains(AlarmNotification.prefix(of: $0)) }
        if !ids.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: ids)
        }
        center.removePendingNotificationRequests(withIdentifiers: [AlarmNotification.bedtimeIdentifier])
    }

    // MARK: Safety nets

    /// One repeating trigger per alarm day. These never run out.
    private func scheduleSafetyNets(for alarms: [Alarm], budget: Int) async -> Int {
        var used = 0

        for alarm in alarms where !alarm.isQuickAlarm {
            guard used < budget else { break }

            switch alarm.repeatMode {
            case .weekly where !alarm.repeatDays.isEmpty:
                // A full week is better expressed as one daily trigger.
                if alarm.repeatDays == Weekday.everyDay {
                    guard used < budget else { break }
                    var components = DateComponents()
                    components.hour = alarm.hour
                    components.minute = alarm.minute
                    if await add(
                        alarm: alarm,
                        identifier: AlarmNotification.identifier(AlarmNotification.prefixNet, alarm.id, Date(), 0),
                        components: components,
                        repeats: true,
                        kind: .safetyNet,
                        chainIndex: 0
                    ) { used += 1 }
                } else {
                    for day in Weekday.orderedForLocale() where alarm.repeatDays.contains(day) {
                        guard used < budget else { break }
                        var components = DateComponents()
                        components.weekday = day.rawValue
                        components.hour = alarm.hour
                        components.minute = alarm.minute
                        if await add(
                            alarm: alarm,
                            identifier: AlarmNotification.identifier(
                                AlarmNotification.prefixNet, alarm.id, Date(), day.rawValue
                            ),
                            components: components,
                            repeats: true,
                            kind: .safetyNet,
                            chainIndex: 0
                        ) { used += 1 }
                    }
                }

            case .once, .weekly, .dates:
                // Non-repeating alarms are fully covered by their chain.
                continue
            }
        }

        return used
    }

    // MARK: Pre-alarms

    private func schedulePreAlarms(for alarms: [Alarm], budget: Int) async -> Int {
        var used = 0
        let candidates = alarms
            .compactMap { alarm -> (Alarm, Date)? in
                guard let date = alarm.nextPreAlarmDate() else { return nil }
                return (alarm, date)
            }
            .sorted { $0.1 < $1.1 }

        for (alarm, date) in candidates {
            guard used < budget else { break }
            let content = UNMutableNotificationContent()
            content.title = "Alarm in \(alarm.preAlarm.minutesBefore) minutes"
            content.body = alarm.displayLabel
            content.categoryIdentifier = AlarmNotification.categoryPreAlarm
            content.interruptionLevel = .active
            content.sound = alarm.preAlarm.playSound
                ? UNNotificationSound(named: UNNotificationSoundName(SoundCatalog.tone(id: alarm.preAlarm.toneID).fileName))
                : nil
            content.userInfo = [
                AlarmNotification.keyAlarmID: alarm.id.uuidString,
                AlarmNotification.keyKind: AlarmNotification.Kind.preAlarm.rawValue,
                AlarmNotification.keyFireDate: date.timeIntervalSince1970,
            ]

            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second], from: date
            )
            let request = UNNotificationRequest(
                identifier: AlarmNotification.identifier(AlarmNotification.prefixPre, alarm.id, date),
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            )
            if await submit(request) { used += 1 }
        }

        return used
    }

    // MARK: Chains

    private func scheduleChains(for alarms: [Alarm], budget: Int) async {
        guard budget > 0 else { return }

        // Flatten every upcoming occurrence, nearest first.
        var occurrences: [(alarm: Alarm, date: Date)] = []
        for alarm in alarms {
            for date in alarm.upcomingFireDates(limit: 4) {
                occurrences.append((alarm, date))
            }
        }
        occurrences.sort { $0.date < $1.date }

        var remaining = budget
        var isFirst = true

        for occurrence in occurrences {
            guard remaining > 0 else { break }

            let alarm = occurrence.alarm
            // The imminent alarm gets a full-length chain; later ones get a
            // token chain that the next rebuild will extend.
            let desired: Int
            if isFirst {
                let minutes = alarm.sound.autoStopMinutes
                let needed = minutes == 0
                    ? maxChainLength
                    : Int(ceil(Double(minutes) * 60 / chainSpacing))
                desired = max(2, min(maxChainLength, needed))
            } else {
                desired = 2
            }

            let length = min(desired, remaining)
            guard length > 0 else { break }

            for index in 0..<length {
                let fireDate = occurrence.date.addingTimeInterval(chainSpacing * Double(index))
                let content = UNMutableNotificationContent()
                content.title = alarm.displayLabel
                content.body = index == 0
                    ? (alarm.memo.isEmpty ? "Tap to turn off the alarm." : alarm.memo)
                    : "Still ringing — tap to turn it off."
                content.categoryIdentifier = AlarmNotification.categoryAlarm
                content.interruptionLevel = .timeSensitive
                content.sound = UNNotificationSound(
                    named: UNNotificationSoundName(ToneResolver.bundledTone(for: alarm.sound.toneID).fileName)
                )
                content.userInfo = [
                    AlarmNotification.keyAlarmID: alarm.id.uuidString,
                    AlarmNotification.keyKind: AlarmNotification.Kind.alarm.rawValue,
                    AlarmNotification.keyFireDate: occurrence.date.timeIntervalSince1970,
                    AlarmNotification.keyChainIndex: index,
                ]
                content.relevanceScore = 1.0

                let components = Calendar.current.dateComponents(
                    [.year, .month, .day, .hour, .minute, .second], from: fireDate
                )
                let request = UNNotificationRequest(
                    identifier: AlarmNotification.identifier(
                        AlarmNotification.prefixChain, alarm.id, occurrence.date, index
                    ),
                    content: content,
                    trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
                )
                if await submit(request) { remaining -= 1 }
                if remaining <= 0 { break }
            }

            isFirst = false
        }
    }

    // MARK: Snooze and wake-up check

    /// Schedules the chain for a snooze. Cleared automatically when the alarm
    /// is finally dismissed.
    public func scheduleSnooze(alarm: Alarm, fireAt date: Date) async {
        await cancelSnooze(alarmID: alarm.id)

        let length = min(12, maxChainLength)
        for index in 0..<length {
            let fireDate = date.addingTimeInterval(chainSpacing * Double(index))
            let content = UNMutableNotificationContent()
            content.title = alarm.displayLabel
            content.body = index == 0 ? "Snooze is over. Time to get up." : "Still ringing — tap to turn it off."
            content.categoryIdentifier = AlarmNotification.categoryAlarm
            content.interruptionLevel = .timeSensitive
            content.sound = UNNotificationSound(
                named: UNNotificationSoundName(ToneResolver.bundledTone(for: alarm.sound.toneID).fileName)
            )
            content.userInfo = [
                AlarmNotification.keyAlarmID: alarm.id.uuidString,
                AlarmNotification.keyKind: AlarmNotification.Kind.snooze.rawValue,
                AlarmNotification.keyFireDate: date.timeIntervalSince1970,
                AlarmNotification.keyChainIndex: index,
            ]

            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second], from: fireDate
            )
            let request = UNNotificationRequest(
                identifier: AlarmNotification.identifier(AlarmNotification.prefixSnooze, alarm.id, date, index),
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            )
            _ = await submit(request)
        }
    }

    public func cancelSnooze(alarmID: UUID) async {
        await removePending(withPrefix: AlarmNotification.prefixSnooze, alarmID: alarmID)
    }

    /// The "are you actually awake?" follow-up. Fires once; if the user does
    /// not confirm within the window the ring coordinator re-arms the alarm.
    public func scheduleWakeUpCheck(alarm: Alarm, fireAt date: Date) async {
        await cancelWakeUpCheck(alarmID: alarm.id)

        let content = UNMutableNotificationContent()
        content.title = "Are you sure you're awake?"
        content.body = "Confirm within \(alarm.wakeUpCheck.confirmWindowSeconds) seconds or the alarm will ring again."
        content.categoryIdentifier = AlarmNotification.categoryWakeCheck
        content.interruptionLevel = .timeSensitive
        content.sound = UNNotificationSound(
            named: UNNotificationSoundName(ToneResolver.bundledTone(for: alarm.sound.toneID).fileName)
        )
        content.userInfo = [
            AlarmNotification.keyAlarmID: alarm.id.uuidString,
            AlarmNotification.keyKind: AlarmNotification.Kind.wakeCheck.rawValue,
            AlarmNotification.keyFireDate: date.timeIntervalSince1970,
        ]

        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date
        )
        let request = UNNotificationRequest(
            identifier: AlarmNotification.identifier(AlarmNotification.prefixWakeCheck, alarm.id, date),
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        )
        _ = await submit(request)
    }

    public func cancelWakeUpCheck(alarmID: UUID) async {
        await removePending(withPrefix: AlarmNotification.prefixWakeCheck, alarmID: alarmID)
    }

    // MARK: Bedtime

    private func scheduleBedtimeReminder(settings: AppSettings) async {
        guard settings.bedtimeReminderEnabled else { return }

        let content = UNMutableNotificationContent()
        content.title = "Time to wind down"
        content.body = "Head to bed to hit your wake-up time feeling rested."
        content.categoryIdentifier = AlarmNotification.categoryBedtime
        content.interruptionLevel = .active
        content.sound = .default
        content.userInfo = [AlarmNotification.keyKind: AlarmNotification.Kind.bedtime.rawValue]

        var components = DateComponents()
        components.hour = settings.bedtimeHour
        components.minute = settings.bedtimeMinute

        let request = UNNotificationRequest(
            identifier: AlarmNotification.bedtimeIdentifier,
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        )
        _ = await submit(request)
    }

    // MARK: Cancellation

    /// Silences everything belonging to one alarm — used the moment it is
    /// successfully dismissed so the rest of the chain does not keep firing.
    public func cancelEverything(for alarmID: UUID) async {
        let pending = await center.pendingNotificationRequests()
        let ids = pending.map(\.identifier).filter { AlarmNotification.alarmID(from: $0) == alarmID }
        center.removePendingNotificationRequests(withIdentifiers: ids)

        let delivered = await center.deliveredNotifications()
        let deliveredIDs = delivered
            .map(\.request.identifier)
            .filter { AlarmNotification.alarmID(from: $0) == alarmID }
        center.removeDeliveredNotifications(withIdentifiers: deliveredIDs)
    }

    /// Clears the chain for one alarm but leaves its safety nets in place.
    public func cancelChain(for alarmID: UUID) async {
        await removePending(withPrefix: AlarmNotification.prefixChain, alarmID: alarmID)
        await removePending(withPrefix: AlarmNotification.prefixSnooze, alarmID: alarmID)

        let delivered = await center.deliveredNotifications()
        let ids = delivered
            .map(\.request.identifier)
            .filter { AlarmNotification.alarmID(from: $0) == alarmID }
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }

    public func cancelAll() async {
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }

    private func removePending(withPrefix prefix: String, alarmID: UUID) async {
        let pending = await center.pendingNotificationRequests()
        let ids = pending.map(\.identifier).filter {
            AlarmNotification.prefix(of: $0) == prefix && AlarmNotification.alarmID(from: $0) == alarmID
        }
        guard !ids.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    // MARK: Helpers

    private func add(
        alarm: Alarm,
        identifier: String,
        components: DateComponents,
        repeats: Bool,
        kind: AlarmNotification.Kind,
        chainIndex: Int
    ) async -> Bool {
        let content = UNMutableNotificationContent()
        content.title = alarm.displayLabel
        content.body = alarm.memo.isEmpty ? "Tap to turn off the alarm." : alarm.memo
        content.categoryIdentifier = AlarmNotification.categoryAlarm
        content.interruptionLevel = .timeSensitive
        content.sound = UNNotificationSound(
            named: UNNotificationSoundName(ToneResolver.bundledTone(for: alarm.sound.toneID).fileName)
        )
        content.userInfo = [
            AlarmNotification.keyAlarmID: alarm.id.uuidString,
            AlarmNotification.keyKind: kind.rawValue,
            AlarmNotification.keyChainIndex: chainIndex,
        ]

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: repeats)
        )
        return await submit(request)
    }

    private func submit(_ request: UNNotificationRequest) async -> Bool {
        do {
            try await center.add(request)
            return true
        } catch {
            log.error("Failed to add \(request.identifier, privacy: .public): \(String(describing: error), privacy: .public)")
            return false
        }
    }
}
