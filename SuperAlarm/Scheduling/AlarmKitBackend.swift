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
    static var title: LocalizedStringResource = "Turn off"
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

/// The secondary "Start mission" button. Brings the app to the front so the
/// mission can run.
///
/// Deliberately does *not* stop the system alarm here. The app stops it
/// itself, in `AlarmRuntime`, only after its own audio is playing and the
/// live backstop chain has been re-armed — so there is never a moment where
/// nothing owned by the system is about to ring.
@available(iOS 26.0, *)
struct SuperAlarmOpenMissionIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Start mission"
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
    private let backstopModeKey = "alarmkit.backstopModes"
    private let snoozeKey = "alarmkit.snoozeIDs"

    /// Why a follow-up chain exists, which decides who may replace it.
    ///
    /// * `preArmed` chains are scheduled with the alarm itself and refreshed
    ///   on every rebuild.
    /// * `live` chains belong to an alarm the app is ringing right now and are
    ///   rolled forward by the runtime's heartbeat; a rebuild leaves them alone.
    /// * `snooze` chains sit behind a snooze alarm; a rebuild leaves them alone.
    private enum ChainMode: String {
        case preArmed, live, snooze
    }

    var isSupported: Bool { true }

    var isAuthorized: Bool {
        manager.authorizationState == .authorized
    }

    var isDenied: Bool {
        manager.authorizationState == .denied
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

        // Self-heal: if nothing is tracked but the daemon still holds alarms
        // for this app, they were scheduled by a launch whose bookkeeping
        // was lost (an older build kept it in a non-persisting defaults
        // suite). They can never be cancelled by name, so clear them all
        // before scheduling a fresh, tracked set.
        if scheduledMap().isEmpty, backstopMap().isEmpty, snoozeMap().isEmpty,
           let orphans = try? manager.alarms, !orphans.isEmpty {
            log.error("Found \(orphans.count, privacy: .public) untracked system alarms; clearing them")
            for orphan in orphans {
                try? manager.cancel(id: orphan.id)
            }
        }

        // AlarmKit's `Alarm` exposes no metadata, so the mapping from app
        // alarm to system alarm has to be tracked here to cancel precisely.
        // New alarms are scheduled before the old ones are cancelled, so a
        // crash in between leaves too many alarms rather than none.
        let previous = scheduledMap()
        var scheduled: [String: [String]] = [:]
        var upcoming: [(alarm: AppAlarm, fire: Date)] = []

        for alarm in alarms where !alarm.isQuickAlarm || alarm.quickAlarmFireDate != nil {
            guard let nextFire = alarm.nextFireDate() else { continue }
            guard let id = await schedulePrimary(for: alarm, nextFire: nextFire) else { continue }
            scheduled[alarm.id.uuidString, default: []].append(id.uuidString)
            upcoming.append((alarm, nextFire))
        }

        defaults.set(scheduled, forKey: scheduledKey)
        for ids in previous.values {
            for raw in ids {
                if let id = UUID(uuidString: raw) {
                    try? manager.cancel(id: id)
                }
            }
        }

        // Pre-arm the follow-up chain behind the soonest occurrences, so that
        // pressing Stop on the system alert and rolling over is not the end
        // of it even if the app never runs. Chains that are live or behind a
        // snooze belong to the runtime and are left alone.
        upcoming.sort { $0.fire < $1.fire }
        let chained = Set(upcoming.prefix(BackstopPolicy.preArmedOccurrenceLimit).map { $0.alarm.id })
        for (raw, mode) in backstopModes() where mode == .preArmed {
            guard let alarmID = UUID(uuidString: raw), !chained.contains(alarmID) else { continue }
            await cancelBackstops(alarmID: alarmID)
        }
        for entry in upcoming.prefix(BackstopPolicy.preArmedOccurrenceLimit) {
            let current = backstopModes()[entry.alarm.id.uuidString]
            if current == .live || current == .snooze { continue }
            await replaceBackstops(
                for: entry.alarm,
                dates: BackstopPolicy.dates(from: entry.fire, offsets: BackstopPolicy.preArmedOffsets),
                mode: .preArmed
            )
        }

        log.info("AlarmKit synced \(scheduled.count, privacy: .public) alarms")
    }

    private func schedulePrimary(for alarm: AppAlarm, nextFire: Date) async -> UUID? {
        let schedule: AlarmKit.Alarm.Schedule
        // A skipped occurrence needs an absolute date: a relative weekly
        // schedule would fire on the skipped day regardless.
        if alarm.repeatMode == .weekly, !alarm.repeatDays.isEmpty, !isMidnight(alarm), !alarm.skipNextOccurrence {
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

    // MARK: Backstops

    /// Arms the live follow-up chain from `base` — called the moment the app
    /// starts ringing, and again on every relaunch into an outstanding ring.
    /// New alarms are scheduled before the old ones are cancelled, so the
    /// chain is never empty in between.
    func scheduleBackstops(for alarm: AppAlarm, from base: Date) async {
        guard isAuthorized else { return }
        await replaceBackstops(
            for: alarm,
            dates: BackstopPolicy.dates(from: base, offsets: BackstopPolicy.liveOffsets),
            mode: .live
        )
    }

    /// Rolls the live chain forward while the app is alive and ringing.
    ///
    /// Any backstop that would fire within the next heartbeat window is moved
    /// to the end of the chain, so it never interrupts a mission in progress —
    /// but the instant the process dies, the heartbeat stops and the head of
    /// the chain lands within `BackstopPolicy.firstOffset` seconds.
    func refreshBackstops(for alarm: AppAlarm, now: Date) async {
        guard isAuthorized else { return }
        guard backstopModes()[alarm.id.uuidString] == .live else {
            await scheduleBackstops(for: alarm, from: now)
            return
        }

        var chain = backstopChain(for: alarm.id)
        let horizon = now.addingTimeInterval(BackstopPolicy.firstOffset)
        let expiring = chain.filter { $0.fire < horizon }
        guard !expiring.isEmpty else { return }

        var last = chain.map(\.fire).max() ?? now
        var replacements: [(id: String, fire: Date)] = []
        for _ in expiring {
            last = last.addingTimeInterval(BackstopPolicy.liveTailSpacing)
            guard
                let id = await schedule(
                    id: UUID(),
                    appAlarm: alarm,
                    schedule: .fixed(last),
                    isBackstop: true,
                    index: chain.count + replacements.count + 1
                )
            else { break }
            replacements.append((id: id.uuidString, fire: last))
        }

        for entry in expiring {
            if let id = UUID(uuidString: entry.id) {
                try? manager.cancel(id: id)
            }
        }
        chain.removeAll { entry in expiring.contains { $0.id == entry.id } }
        chain.append(contentsOf: replacements)
        storeBackstopChain(chain, for: alarm.id, mode: .live)
    }

    /// Schedules a fresh chain at `dates`, then cancels whatever chain the
    /// alarm had before.
    private func replaceBackstops(for alarm: AppAlarm, dates: [Date], mode: ChainMode) async {
        let previous = backstopChain(for: alarm.id)

        var chain: [(id: String, fire: Date)] = []
        for (index, fire) in dates.enumerated() {
            guard
                let id = await schedule(
                    id: UUID(),
                    appAlarm: alarm,
                    schedule: .fixed(fire),
                    isBackstop: true,
                    index: index + 1
                )
            else { break }
            chain.append((id: id.uuidString, fire: fire))
        }

        for entry in previous {
            if let id = UUID(uuidString: entry.id) {
                try? manager.cancel(id: id)
            }
        }
        storeBackstopChain(chain, for: alarm.id, mode: mode)
        log.info("Armed \(chain.count, privacy: .public) \(mode.rawValue, privacy: .public) backstops")
    }

    /// Stops every follow-up alarm for one app alarm. Only the coordinator
    /// calls this, and only when `BackstopPolicy` says the event qualifies.
    func cancelBackstops(alarmID: UUID) async {
        for entry in backstopChain(for: alarmID) {
            if let id = UUID(uuidString: entry.id) {
                try? manager.stop(id: id)
                try? manager.cancel(id: id)
            }
        }
        var map = backstopMap()
        map[alarmID.uuidString] = nil
        defaults.set(map, forKey: backstopKey)
        var modes = defaults.dictionary(forKey: backstopModeKey) as? [String: String] ?? [:]
        modes[alarmID.uuidString] = nil
        defaults.set(modes, forKey: backstopModeKey)
    }

    /// Stops the system alarms for one app alarm that are alerting right
    /// now, leaving everything scheduled for later in place. This is the
    /// hand-over: the app has taken over with its own audio.
    func stopAlerting(alarmID: UUID) {
        let owned = Set(
            (scheduledMap()[alarmID.uuidString] ?? [])
                + (snoozeMap()[alarmID.uuidString] ?? [])
                + backstopChain(for: alarmID).map(\.id)
        )
        guard let live = try? manager.alarms else { return }
        for systemAlarm in live where systemAlarm.state == .alerting && owned.contains(systemAlarm.id.uuidString) {
            try? manager.stop(id: systemAlarm.id)
        }
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

        // With no mission the secondary button opens the app; calling it
        // "Turn off" next to a Stop button was two stop-like controls.
        let missionButton = AlarmButton(
            text: appAlarm.mission.type == .none ? "Open SuperAlarm" : "Start mission",
            textColor: .black,
            systemImageName: appAlarm.mission.type == .none ? "alarm.fill" : appAlarm.mission.type.symbolName
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

    /// Removes everything for one app alarm — used when the alarm is deleted
    /// or disabled, never merely because it was dismissed.
    func cancel(alarmID: UUID) async {
        await cancelBackstops(alarmID: alarmID)
        await cancelSnooze(alarmID: alarmID)

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

    /// Schedules the snooze alarm and moves the follow-up chain behind it.
    /// Snoozing is not completing the mission, so the chain does not end —
    /// it just waits for the snooze.
    func scheduleSnooze(alarm: AppAlarm, at date: Date) async {
        guard isAuthorized else { return }
        await cancelSnooze(alarmID: alarm.id)
        if let id = await schedule(
            id: UUID(),
            appAlarm: alarm,
            schedule: .fixed(date),
            isBackstop: false,
            index: 0
        ) {
            var map = snoozeMap()
            map[alarm.id.uuidString] = [id.uuidString]
            defaults.set(map, forKey: snoozeKey)
        }
        await replaceBackstops(
            for: alarm,
            dates: BackstopPolicy.dates(from: date, offsets: BackstopPolicy.snoozeOffsets),
            mode: .snooze
        )
    }

    /// Removes the snooze / wake-check re-ring alarm. Tracked separately so
    /// confirming the wake-up check, or completing the mission after a
    /// snooze was cut short, does not leave a system alarm to fire later.
    func cancelSnooze(alarmID: UUID) async {
        var map = snoozeMap()
        for raw in map[alarmID.uuidString] ?? [] {
            if let id = UUID(uuidString: raw) {
                try? manager.stop(id: id)
                try? manager.cancel(id: id)
            }
        }
        map[alarmID.uuidString] = nil
        defaults.set(map, forKey: snoozeKey)
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
        defaults.removeObject(forKey: backstopModeKey)
        defaults.removeObject(forKey: snoozeKey)
    }

    // MARK: Diagnostics

    var diagnosticSummary: String {
        let chains = backstopMap()
        let count = chains.values.reduce(0) { $0 + $1.count }
        let live = backstopModes().values.filter { $0 == .live }.count
        let systemCount = (try? manager.alarms.count) ?? 0
        let liveText = live > 0 ? " (\(live) for the current ring)" : ""
        return "\(systemCount) scheduled, \(count) follow-ups armed\(liveText)"
    }

    // MARK: Bookkeeping

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

    private func snoozeMap() -> [String: [String]] {
        defaults.dictionary(forKey: snoozeKey) as? [String: [String]] ?? [:]
    }

    /// Alarm ID → ["<systemID>@<fireDate seconds>"].
    private func backstopMap() -> [String: [String]] {
        defaults.dictionary(forKey: backstopKey) as? [String: [String]] ?? [:]
    }

    private func backstopModes() -> [String: ChainMode] {
        let raw = defaults.dictionary(forKey: backstopModeKey) as? [String: String] ?? [:]
        return raw.compactMapValues(ChainMode.init(rawValue:))
    }

    private func backstopChain(for alarmID: UUID) -> [(id: String, fire: Date)] {
        (backstopMap()[alarmID.uuidString] ?? []).compactMap { raw in
            let parts = raw.split(separator: "@", maxSplits: 1).map(String.init)
            guard let first = parts.first else { return nil }
            let seconds = parts.count > 1 ? Double(parts[1]) ?? 0 : 0
            return (first, Date(timeIntervalSince1970: seconds))
        }
    }

    private func storeBackstopChain(_ chain: [(id: String, fire: Date)], for alarmID: UUID, mode: ChainMode) {
        var map = backstopMap()
        map[alarmID.uuidString] = chain.map { "\($0.id)@\(Int($0.fire.timeIntervalSince1970))" }
        defaults.set(map, forKey: backstopKey)
        var modes = defaults.dictionary(forKey: backstopModeKey) as? [String: String] ?? [:]
        modes[alarmID.uuidString] = mode.rawValue
        defaults.set(modes, forKey: backstopModeKey)
    }
}
#endif
