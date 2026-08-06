#if canImport(AlarmKit)
import Foundation
import AlarmKit
import ActivityKit
import AppIntents
import SwiftUI
import os.log

// AlarmKit declares its own `Alarm`, so this file never uses the bare name:
// `AppAlarm` (declared in Models/Alarm.swift) is this app's model, and
// `AlarmKit.Alarm` is the framework's.

// MARK: - Metadata

@available(iOS 26.0, *)
struct SuperAlarmMetadata: AlarmMetadata {
    /// The app-side alarm this system alarm belongs to.
    let appAlarmID: String
    let label: String
    let missionType: String
    /// Backstops are the follow-up alarms that keep firing until the mission
    /// is actually completed.
    let isBackstop: Bool
    let backstopIndex: Int

    init(appAlarmID: String, label: String, missionType: String, isBackstop: Bool = false, backstopIndex: Int = 0) {
        self.appAlarmID = appAlarmID
        self.label = label
        self.missionType = missionType
        self.isBackstop = isBackstop
        self.backstopIndex = backstopIndex
    }
}

// MARK: - Intents

/// Runs when the alarm is stopped from the system UI. Treated as a hint only:
/// Apple documents that this does not fire on every dismissal path, so the
/// backstop chain — not this intent — is what guarantees the user gets up.
@available(iOS 26.0, *)
struct SuperAlarmStopIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Stop"
    static var description = IntentDescription("Stops the alarm that is currently sounding.")

    @Parameter(title: "systemAlarmID") var systemAlarmID: String
    @Parameter(title: "appAlarmID") var appAlarmID: String

    init() {
        systemAlarmID = ""
        appAlarmID = ""
    }

    init(systemAlarmID: String, appAlarmID: String) {
        self.systemAlarmID = systemAlarmID
        self.appAlarmID = appAlarmID
    }

    func perform() throws -> some IntentResult {
        if let id = UUID(uuidString: systemAlarmID) {
            try? AlarmManager.shared.stop(id: id)
        }
        // The mission still has to be completed, so arm the hand-off. If the
        // user genuinely got up they will open the app and finish it; if they
        // rolled over, the backstop chain brings the alarm back.
        if let appID = UUID(uuidString: appAlarmID) {
            PendingMission.shared.arm(alarmID: appID)
        }
        return .result()
    }
}

/// The secondary "Turn off" button. Silences the system alarm and brings the
/// app to the front so the mission can run.
@available(iOS 26.0, *)
struct SuperAlarmOpenMissionIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Turn off"
    static var description = IntentDescription("Opens SuperAlarm to complete the wake-up mission.")

    /// `openAppWhenRun` is deprecated on iOS 26 in favour of `supportedModes`.
    static var supportedModes: IntentModes = [.foreground(.immediate)]

    @Parameter(title: "systemAlarmID") var systemAlarmID: String
    @Parameter(title: "appAlarmID") var appAlarmID: String

    init() {
        systemAlarmID = ""
        appAlarmID = ""
    }

    init(systemAlarmID: String, appAlarmID: String) {
        self.systemAlarmID = systemAlarmID
        self.appAlarmID = appAlarmID
    }

    func perform() throws -> some IntentResult {
        // Silence the system alarm; the app takes over with its own audio so
        // that volume, gradual ramp and the mission UI are all under our
        // control.
        if let id = UUID(uuidString: systemAlarmID) {
            try? AlarmManager.shared.stop(id: id)
        }
        if let appID = UUID(uuidString: appAlarmID) {
            PendingMission.shared.arm(alarmID: appID)
        }
        return .result()
    }
}

// MARK: - Backend

@available(iOS 26.0, *)
@MainActor
final class AlarmKitBackend: SystemAlarmBackend {
    private typealias Config = AlarmManager.AlarmConfiguration<SuperAlarmMetadata>

    private let manager = AlarmManager.shared
    private let log = Logger(subsystem: "io.superalarm", category: "alarmkit")
    private let defaults = StorageLocation.defaults
    private let scheduledKey = "alarmkit.scheduledIDs"
    private let backstopKey = "alarmkit.backstopIDs"

    /// How many follow-up alarms trail the main one, and how far apart.
    ///
    /// This exists because a physical button press dismisses an AlarmKit alarm
    /// outright, and only *currently alerting* alarms are dismissed — so
    /// spacing them out means one survives every button mash.
    private let backstopCount = 5
    private let backstopSpacing: TimeInterval = 120

    var isSupported: Bool { true }

    var isAuthorized: Bool {
        manager.authorizationState == .authorized
    }

    func requestAuthorization() async -> Bool {
        switch manager.authorizationState {
        case .authorized:
            return true
        case .denied:
            return false
        case .notDetermined:
            do {
                return try await manager.requestAuthorization() == .authorized
            } catch {
                log.error("AlarmKit authorization failed: \(String(describing: error), privacy: .public)")
                return false
            }
        @unknown default:
            return false
        }
    }

    // MARK: Sync

    func sync(alarms: [AppAlarm]) async {
        guard isAuthorized else {
            log.info("AlarmKit not authorized; skipping sync")
            return
        }

        cancelTrackedAlarms()

        // AlarmKit's `Alarm` exposes no metadata, so the mapping from app
        // alarm to system alarm has to be tracked here to cancel precisely.
        var scheduled: [String: [String]] = [:]

        for alarm in alarms where !alarm.isQuickAlarm || alarm.quickAlarmFireDate != nil {
            guard let id = await schedulePrimary(for: alarm) else { continue }
            scheduled[alarm.id.uuidString, default: []].append(id.uuidString)
        }

        defaults.set(scheduled, forKey: scheduledKey)
        log.info("AlarmKit synced \(scheduled.count, privacy: .public) alarms")
    }

    private func schedulePrimary(for alarm: AppAlarm) async -> UUID? {
        guard let nextFire = alarm.nextFireDate() else { return nil }

        let schedule: AlarmKit.Alarm.Schedule
        if alarm.repeatMode == .weekly, !alarm.repeatDays.isEmpty, !isMidnight(alarm) {
            schedule = .relative(
                .init(
                    time: .init(hour: alarm.hour, minute: alarm.minute),
                    repeats: .weekly(alarm.repeatDays.sorted { $0.rawValue < $1.rawValue }.map(localeWeekday))
                )
            )
        } else {
            // One-shot, specific-date, and midnight alarms use an absolute
            // date. Midnight is deliberate: a relative schedule at 00:00 has a
            // known double-fire bug, and an absolute one avoids it. These get
            // re-armed on the next launch after firing.
            schedule = .fixed(nextFire)
        }

        // `self.` is required: the local `schedule` constant above shadows the
        // method of the same name.
        return await self.schedule(
            id: UUID(),
            appAlarm: alarm,
            schedule: schedule,
            isBackstop: false,
            index: 0
        )
    }

    /// Arms the follow-up chain once an alarm has actually started ringing.
    func scheduleBackstops(for alarm: AppAlarm, from base: Date) async {
        guard isAuthorized else { return }
        cancelBackstops(alarmID: alarm.id)

        var ids: [String] = []
        for index in 1...backstopCount {
            let fire = base.addingTimeInterval(backstopSpacing * Double(index))
            guard
                let id = await schedule(
                    id: UUID(),
                    appAlarm: alarm,
                    schedule: .fixed(fire),
                    isBackstop: true,
                    index: index
                )
            else { break }
            ids.append(id.uuidString)
        }

        var map = backstopMap()
        map[alarm.id.uuidString] = ids
        defaults.set(map, forKey: backstopKey)
        log.info("Armed \(ids.count, privacy: .public) backstop alarms")
    }

    private func schedule(
        id: UUID,
        appAlarm: AppAlarm,
        schedule: AlarmKit.Alarm.Schedule,
        isBackstop: Bool,
        index: Int
    ) async -> UUID? {
        let title: LocalizedStringResource = isBackstop
            ? "Still asleep?"
            : LocalizedStringResource(stringLiteral: appAlarm.displayLabel)

        let missionButton = AlarmButton(
            text: appAlarm.mission.type == .none ? "Turn off" : "Start mission",
            textColor: .black,
            systemImageName: appAlarm.mission.type == .none ? "stop.fill" : appAlarm.mission.type.symbolName
        )

        let alert: AlarmPresentation.Alert
        if #available(iOS 26.1, *) {
            // The system draws its own stop control from 26.1 onward.
            alert = .init(
                title: title,
                secondaryButton: missionButton,
                secondaryButtonBehavior: .custom
            )
        } else {
            alert = .init(
                title: title,
                stopButton: AlarmButton(text: "Stop", textColor: .white, systemImageName: "stop.circle"),
                secondaryButton: missionButton,
                secondaryButtonBehavior: .custom
            )
        }

        let metadata = SuperAlarmMetadata(
            appAlarmID: appAlarm.id.uuidString,
            label: appAlarm.displayLabel,
            missionType: appAlarm.mission.type.rawValue,
            isBackstop: isBackstop,
            backstopIndex: index
        )

        let attributes = AlarmAttributes(
            presentation: AlarmPresentation(alert: alert),
            metadata: metadata,
            tintColor: Color(hex: 0xFFD400)
        )

        let configuration = Config(
            schedule: schedule,
            attributes: attributes,
            stopIntent: SuperAlarmStopIntent(
                systemAlarmID: id.uuidString,
                appAlarmID: appAlarm.id.uuidString
            ),
            secondaryIntent: SuperAlarmOpenMissionIntent(
                systemAlarmID: id.uuidString,
                appAlarmID: appAlarm.id.uuidString
            ),
            sound: alertSound(for: appAlarm)
        )

        do {
            _ = try await manager.schedule(id: id, configuration: configuration)
            return id
        } catch AlarmManager.AlarmError.maximumLimitReached {
            log.error("AlarmKit refused a new alarm: limit reached")
            return nil
        } catch {
            log.error("AlarmKit schedule failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Custom sounds were broken on iOS 26.0 — `named(_:)` played the system
    /// error tone regardless of format. Fall back to the default alarm sound
    /// there rather than shipping something that sounds broken.
    private func alertSound(for alarm: AppAlarm) -> AlertConfiguration.AlertSound {
        guard #available(iOS 26.1, *) else { return .default }
        guard alarm.sound.isEnabled else { return .default }
        // AlarmKit can only reference bundled files.
        return .named(ToneResolver.bundledTone(for: alarm.sound.toneID).fileName)
    }

    private func isMidnight(_ alarm: AppAlarm) -> Bool {
        alarm.hour == 0 && alarm.minute == 0
    }

    private func localeWeekday(_ day: Weekday) -> Locale.Weekday {
        switch day {
        case .sunday: return .sunday
        case .monday: return .monday
        case .tuesday: return .tuesday
        case .wednesday: return .wednesday
        case .thursday: return .thursday
        case .friday: return .friday
        case .saturday: return .saturday
        }
    }

    // MARK: Cancellation

    func cancel(alarmID: UUID) async {
        cancelBackstops(alarmID: alarmID)

        var map = scheduledMap()
        for raw in map[alarmID.uuidString] ?? [] {
            if let id = UUID(uuidString: raw) {
                try? manager.stop(id: id)
                try? manager.cancel(id: id)
            }
        }
        map[alarmID.uuidString] = nil
        defaults.set(map, forKey: scheduledKey)
    }

    /// Stops every follow-up alarm for one app alarm. Called the moment a
    /// mission is verifiably completed.
    func cancelBackstops(alarmID: UUID) {
        var map = backstopMap()
        guard let ids = map[alarmID.uuidString] else { return }
        for raw in ids {
            if let id = UUID(uuidString: raw) {
                try? manager.stop(id: id)
                try? manager.cancel(id: id)
            }
        }
        map[alarmID.uuidString] = nil
        defaults.set(map, forKey: backstopKey)
    }

    func scheduleSnooze(alarm: AppAlarm, at date: Date) async {
        guard isAuthorized else { return }
        cancelBackstops(alarmID: alarm.id)
        _ = await schedule(
            id: UUID(),
            appAlarm: alarm,
            schedule: .fixed(date),
            isBackstop: false,
            index: 0
        )
    }

    func cancelAll() async {
        cancelTrackedAlarms()
        if let live = try? manager.alarms {
            for systemAlarm in live {
                try? manager.cancel(id: systemAlarm.id)
            }
        }
        defaults.removeObject(forKey: scheduledKey)
        defaults.removeObject(forKey: backstopKey)
    }

    private func cancelTrackedAlarms() {
        for ids in scheduledMap().values {
            for raw in ids {
                if let id = UUID(uuidString: raw) {
                    try? manager.cancel(id: id)
                }
            }
        }
        defaults.removeObject(forKey: scheduledKey)
    }

    private func scheduledMap() -> [String: [String]] {
        defaults.dictionary(forKey: scheduledKey) as? [String: [String]] ?? [:]
    }

    private func backstopMap() -> [String: [String]] {
        defaults.dictionary(forKey: backstopKey) as? [String: [String]] ?? [:]
    }
}
#endif
