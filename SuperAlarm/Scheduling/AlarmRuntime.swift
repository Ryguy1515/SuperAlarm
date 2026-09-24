import Foundation
import Combine
import os.log
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Persisted ring state

/// Snapshot of an in-progress alarm, written to disk on every transition so
/// that a crash, a force-quit, or a relaunch resumes exactly where it left off
/// rather than silently losing the alarm.
struct PersistedRingState: Codable {
    var alarmID: UUID
    var occurrenceDate: Date
    var firedAt: Date
    var snoozeCount: Int
    var phase: AlarmRuntime.Phase
    var snoozeEndsAt: Date?
    var wakeCheckFireAt: Date?
    var wakeCheckDeadline: Date?
    var recordID: UUID?
    var playedToneID: String?
    /// Occurrences already dealt with, so the same alarm is not re-triggered.
    var handledOccurrences: [String: Date] = [:]

    // Mission progress, so a relaunch lands back in the mission that is
    // still owed rather than on a fresh ring. All optional: older state
    // files predate them.
    var missionIntent: String?
    var missionStartedAt: Date?
    var missionCompletedRounds: Int?
    var accumulatedMissionSeconds: Double?
    var missionFailures: Int?

    init(
        alarmID: UUID,
        occurrenceDate: Date,
        firedAt: Date,
        snoozeCount: Int,
        phase: AlarmRuntime.Phase,
        snoozeEndsAt: Date? = nil,
        wakeCheckFireAt: Date? = nil,
        wakeCheckDeadline: Date? = nil,
        recordID: UUID? = nil,
        playedToneID: String? = nil,
        handledOccurrences: [String: Date] = [:],
        missionIntent: String? = nil,
        missionStartedAt: Date? = nil,
        missionCompletedRounds: Int? = nil,
        accumulatedMissionSeconds: Double? = nil,
        missionFailures: Int? = nil
    ) {
        self.alarmID = alarmID
        self.occurrenceDate = occurrenceDate
        self.firedAt = firedAt
        self.snoozeCount = snoozeCount
        self.phase = phase
        self.snoozeEndsAt = snoozeEndsAt
        self.wakeCheckFireAt = wakeCheckFireAt
        self.wakeCheckDeadline = wakeCheckDeadline
        self.recordID = recordID
        self.playedToneID = playedToneID
        self.handledOccurrences = handledOccurrences
        self.missionIntent = missionIntent
        self.missionStartedAt = missionStartedAt
        self.missionCompletedRounds = missionCompletedRounds
        self.accumulatedMissionSeconds = accumulatedMissionSeconds
        self.missionFailures = missionFailures
    }

    /// Hand-written so a state file from an older or newer build still
    /// resumes: every field but the identity of the ring is optional, and an
    /// unknown phase is treated as ringing — the safe default for an alarm
    /// that had not been dealt with.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        alarmID = try c.decode(UUID.self, forKey: .alarmID)
        occurrenceDate = try c.decode(Date.self, forKey: .occurrenceDate)
        firedAt = c.decodeOr(.firedAt, occurrenceDate)
        snoozeCount = c.decodeOr(.snoozeCount, 0)
        phase = (try? c.decodeIfPresent(String.self, forKey: .phase))
            .flatMap { AlarmRuntime.Phase(rawValue: $0) } ?? .ringing
        snoozeEndsAt = try? c.decodeIfPresent(Date.self, forKey: .snoozeEndsAt)
        wakeCheckFireAt = try? c.decodeIfPresent(Date.self, forKey: .wakeCheckFireAt)
        wakeCheckDeadline = try? c.decodeIfPresent(Date.self, forKey: .wakeCheckDeadline)
        recordID = try? c.decodeIfPresent(UUID.self, forKey: .recordID)
        playedToneID = try? c.decodeIfPresent(String.self, forKey: .playedToneID)
        handledOccurrences = c.decodeOr(.handledOccurrences, [:])
        missionIntent = try? c.decodeIfPresent(String.self, forKey: .missionIntent)
        missionStartedAt = try? c.decodeIfPresent(Date.self, forKey: .missionStartedAt)
        missionCompletedRounds = try? c.decodeIfPresent(Int.self, forKey: .missionCompletedRounds)
        accumulatedMissionSeconds = try? c.decodeIfPresent(Double.self, forKey: .accumulatedMissionSeconds)
        missionFailures = try? c.decodeIfPresent(Int.self, forKey: .missionFailures)
    }
}

// MARK: - Due-alarm decision

/// What the idle ticker should do about one alarm — pure so the skip and
/// already-fired rules can be tested.
enum DueDecision: Equatable {
    /// Nothing to do.
    case none
    /// The skipped occurrence has passed; clear the skip and move on.
    case clearSkip(Date)
    /// Ring for this occurrence.
    case ring(Date)
    /// Too late to ring; record it as missed.
    case missed(Date)

    static func make(
        for alarm: Alarm,
        reference: Date,
        catchUpWindow: TimeInterval,
        alreadyHandled: (Date) -> Bool,
        calendar: Calendar = .current
    ) -> DueDecision {
        guard alarm.isEnabled else { return .none }

        if alarm.skipNextOccurrence {
            // With the skip applied the schedule hides the skipped occurrence;
            // without it we can see whether that occurrence has passed.
            var unskipped = alarm
            unskipped.skipNextOccurrence = false
            if alarm.mostRecentFireDate(before: reference, within: catchUpWindow, calendar: calendar) == nil,
               let skipped = unskipped.mostRecentFireDate(before: reference, within: catchUpWindow, calendar: calendar) {
                return .clearSkip(skipped)
            }
        }

        guard let occurrence = alarm.mostRecentFireDate(before: reference, within: catchUpWindow, calendar: calendar) else {
            return .none
        }
        // Dealt with by a previous process: the store remembers the last
        // occurrence that fired even when the in-memory bookkeeping is gone.
        if let last = alarm.lastFiredAt, last >= occurrence { return .none }
        if alreadyHandled(occurrence) { return .none }

        let age = reference.timeIntervalSince(occurrence)
        let ringWindow = alarm.sound.autoStopMinutes > 0
            ? Double(alarm.sound.autoStopMinutes) * 60
            : catchUpWindow
        return age <= ringWindow ? .ring(occurrence) : .missed(occurrence)
    }
}

// MARK: - Runtime

/// Drives everything that happens from the moment an alarm comes due until the
/// user is genuinely awake.
///
/// The state machine is:
///
/// ```
/// idle → ringing → (snoozed → ringing)* → mission → dismissed
///                                            ↓
///                                  wakeCheckPending → wakeCheckRinging
///                                            ↓              ↓
///                                        confirmed      re-ring
/// ```
@MainActor
public final class AlarmRuntime: ObservableObject {
    public enum Phase: String, Codable, Sendable {
        case idle
        /// Alarm sounding, showing snooze and turn-off controls.
        case ringing
        /// User committed to turning it off; the mission is on screen.
        case mission
        /// Waiting out a snooze interval.
        case snoozed
        /// Dismissed, waiting for the wake-up check to come due.
        case wakeCheckPending
        /// Wake-up check is on screen with its countdown running.
        case wakeCheckRinging
    }

    // MARK: Published state

    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var activeAlarm: Alarm?
    @Published public private(set) var snoozeCount = 0
    @Published public private(set) var occurrenceDate: Date?
    @Published public private(set) var firedAt: Date?
    @Published public private(set) var snoozeEndsAt: Date?
    @Published public private(set) var wakeCheckDeadline: Date?
    @Published public private(set) var playingToneID: String?
    /// Ticks every second so views can render live countdowns.
    @Published public private(set) var now = Date()
    /// Rounds passed in the mission on screen, persisted for a relaunch.
    @Published public private(set) var missionCompletedRounds = 0
    /// When the mission on screen began. Stable across re-renders and
    /// relaunches, so the mission runner (and the pedometer) resume from it.
    @Published public private(set) var missionStartedAt: Date?

    /// True whenever a full-screen takeover should be on screen.
    public var isPresenting: Bool {
        switch phase {
        case .idle, .wakeCheckPending: return false
        case .ringing, .mission, .snoozed, .wakeCheckRinging: return true
        }
    }

    // MARK: Dependencies

    private var store: AlarmStore?
    private let coordinator = AlarmCoordinator.shared
    private let audio = AlarmAudioEngine.shared
    private let files = JSONFileStore()
    private let log = Logger(subsystem: "io.superalarm", category: "runtime")

    // MARK: Internal state

    /// What completing the current mission should actually do. Snoozing and
    /// confirming the wake-up check can both be configured to require the
    /// mission, so the mission screen is reused for all three.
    private enum MissionIntent: String {
        case dismiss
        case snooze
        case confirmAwake
    }

    private var missionIntent: MissionIntent = .dismiss
    private var ticker: Timer?
    private var observers: [NSObjectProtocol] = []
    private var currentRecord: WakeRecord?
    private var handledOccurrences: [String: Date] = [:]
    private var wakeCheckFireAt: Date?
    private var accumulatedMissionSeconds: Double = 0
    private var missionFailures = 0
    /// Set once the current mission's time has been added to the total, so
    /// `missionStartedAt` can stay put as the mission's identity.
    private var missionTimeAccrued = false
    private var isBootstrapped = false
    /// True once the still-ringing reminders have been armed for this ring.
    private var nagArmed = false

    /// Phases in which the alarm is audible and the live backstop chain must
    /// be kept ahead of the process.
    private var isAudiblePhase: Bool {
        phase == .ringing || phase == .mission || phase == .wakeCheckRinging
    }

    /// True when a ring is saved on disk and would resume on the next launch.
    public var hasPersistedRingState: Bool {
        files.load(PersistedRingState.self, from: StorageLocation.ringStateFile) != nil
    }

    /// How far past an alarm's time we will still ring when the app was not
    /// running. Beyond this the occurrence is logged as missed.
    private let catchUpWindow: TimeInterval = 30 * 60

    /// Grace period between the wake-up check's deadline and the scheduled
    /// re-ring that backs it up.
    private static let wakeCheckReRingBuffer: TimeInterval = 10

    public init() {}

    deinit {
        ticker?.invalidate()
        for token in observers {
            NotificationCenter.default.removeObserver(token)
        }
    }

    // MARK: - Lifecycle

    public func bootstrap(store: AlarmStore) {
        guard !isBootstrapped else { return }
        isBootstrapped = true
        self.store = store

        restoreState()
        startTicker()
        installObservers()
        consumePendingMission()
        evaluate()
    }

    /// A system alarm fired and the user tapped through to the app. AlarmKit
    /// has already been silenced by the intent, so pick the alarm up here and
    /// take over with our own audio and the mission UI.
    private func consumePendingMission() {
        guard let store, let alarmID = PendingMission.shared.consume() else { return }
        guard let alarm = store.alarm(with: alarmID) else { return }
        // Already handling this one — or a different one, which must not be
        // clobbered mid-mission. The second alarm is picked up by the due
        // check once this ring is over, within its catch-up window.
        if phase != .idle {
            if activeAlarm?.id != alarmID {
                log.info("Ignoring hand-over for a second alarm while one is active")
            }
            return
        }

        let occurrence = alarm.mostRecentFireDate(before: Date(), within: catchUpWindow) ?? Date()
        markHandled(alarmID: alarmID, date: occurrence)
        startRinging(alarm: alarm, occurrence: occurrence)
        log.info("Resumed alarm \(alarmID.uuidString, privacy: .public) handed over from the system alarm")
    }

    private func startTicker() {
        ticker?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.now = Date()
                self?.evaluate()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func installObservers() {
        #if canImport(UIKit)
        observers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleForeground() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleBackground() }
        })
        #endif

        observers.append(NotificationCenter.default.addObserver(
            forName: .alarmAudioNeedsRestart, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.restartAudioIfRinging() }
        })
    }

    public func handleForeground() {
        now = Date()
        audio.stopKeepAlive()
        SystemVolume.shared.prepare()
        consumePendingMission()
        evaluate()

        // Back on the ring screen: the reminders have done their job.
        if nagArmed, let alarm = activeAlarm {
            nagArmed = false
            Task { await coordinator.cancelStillRingingNag(alarmID: alarm.id) }
        }
    }

    public func handleBackground() {
        store?.flush()
        persistState()
        updateKeepAlive()
        armDefencesForLeaving()
    }

    /// The app switcher is opening, or a call is coming in. This is the last
    /// moment before a force-quit the app is guaranteed to run, so the
    /// defences are armed here as well as on backgrounding.
    public func handleResignActive() {
        persistState()
        armDefencesForLeaving()
    }

    /// Best effort: the process is being torn down. Anything scheduled here
    /// may not make it, which is why the chains are already armed.
    public func handleTermination() {
        persistState()
        armDefencesForLeaving()
    }

    /// Re-arms the live backstops from now and schedules the still-ringing
    /// reminders, so leaving the app is answered within seconds.
    private func armDefencesForLeaving() {
        guard isAudiblePhase, let alarm = activeAlarm else { return }
        // Resign-active and background arrive milliseconds apart; arm once.
        guard !nagArmed else { return }
        let occurrence = occurrenceDate ?? Date()
        nagArmed = true
        Task {
            await coordinator.refreshBackstops(for: alarm, occurrence: occurrence)
            await coordinator.scheduleStillRingingNag(for: alarm, occurrence: occurrence)
        }
    }

    /// Runs the near-silent background loop only when it is actually needed:
    /// there is an alarm coming up soon and no system-level alarm backend is
    /// carrying the load. Running it unconditionally is what gives other alarm
    /// apps their reputation for eating battery.
    private func updateKeepAlive() {
        guard let store else { return }
        guard store.settings.backgroundKeepAlive else {
            audio.stopKeepAlive()
            return
        }

        // A ringing or snoozed alarm always keeps the session alive.
        if phase != .idle {
            audio.startKeepAlive()
            return
        }

        // AlarmKit wakes the device by itself; no need to burn battery.
        if coordinator.usesSystemAlarms {
            audio.stopKeepAlive()
            return
        }

        guard let next = store.nextAlarm?.date else {
            audio.stopKeepAlive()
            return
        }

        let window = TimeInterval(store.settings.keepAliveWindowHours * 3600)
        if next.timeIntervalSinceNow <= window {
            audio.startKeepAlive()
        } else {
            audio.stopKeepAlive()
        }
    }

    // MARK: - Evaluation

    /// Advances the state machine. Safe to call as often as you like.
    public func evaluate() {
        guard let store else { return }
        let reference = Date()

        switch phase {
        case .snoozed:
            if let ends = snoozeEndsAt, reference >= ends {
                resumeFromSnooze()
            }

        case .wakeCheckPending:
            if let fireAt = wakeCheckFireAt, reference >= fireAt {
                beginWakeCheck()
            }

        case .wakeCheckRinging:
            if let deadline = wakeCheckDeadline, reference >= deadline {
                failWakeCheck()
            }

        case .ringing:
            enforceAutoStop(reference: reference)

        case .mission:
            break

        case .idle:
            checkForDueAlarms(in: store, reference: reference)
        }

        heartbeatBackstops(reference: reference)
    }

    /// Keeps the live follow-up chain ahead of a ringing app. While the
    /// process is alive the head of the chain is pushed back before it can
    /// fire; the moment the process dies it stops being pushed and the next
    /// backstop lands within `BackstopPolicy.firstOffset` seconds.
    private func heartbeatBackstops(reference: Date) {
        guard isAudiblePhase, let alarm = activeAlarm else { return }
        guard BackstopPolicy.heartbeatIsDue(lastArmedAt: coordinator.lastBackstopArmAt, now: reference) else { return }
        let occurrence = occurrenceDate ?? Date()
        Task { await coordinator.refreshBackstops(for: alarm, occurrence: occurrence) }
    }

    /// Stops an alarm that has been ringing unattended for its whole window.
    private func enforceAutoStop(reference: Date) {
        guard let alarm = activeAlarm, let firedAt else { return }
        let minutes = alarm.sound.autoStopMinutes
        guard minutes > 0 else { return }
        guard reference.timeIntervalSince(firedAt) >= Double(minutes) * 60 else { return }

        log.info("Auto-stopping alarm after \(minutes, privacy: .public) minutes")
        finishRecord(outcome: .rangOut)
        teardown(on: .rangOut)
    }

    private func checkForDueAlarms(in store: AlarmStore, reference: Date) {
        for alarm in store.alarms where alarm.isEnabled {
            let decision = DueDecision.make(
                for: alarm,
                reference: reference,
                catchUpWindow: catchUpWindow,
                alreadyHandled: { handledOccurrences[occurrenceKey(alarmID: alarm.id, date: $0)] != nil }
            )

            switch decision {
            case .none:
                continue

            case .clearSkip(let skipped):
                // The occurrence the user asked to skip has passed; without
                // this the skip would swallow every following occurrence too.
                markHandled(alarmID: alarm.id, date: skipped)
                store.setSkipNext(false, for: alarm.id)
                log.info("Skipped occurrence passed for \(alarm.id.uuidString, privacy: .public)")

            case .ring(let occurrence):
                markHandled(alarmID: alarm.id, date: occurrence)
                startRinging(alarm: alarm, occurrence: occurrence)
                return

            case .missed(let occurrence):
                // Too late to be useful — log it so the history is honest.
                markHandled(alarmID: alarm.id, date: occurrence)
                var record = WakeRecord(
                    alarmID: alarm.id,
                    alarmLabel: alarm.displayLabel,
                    scheduledFor: occurrence,
                    firedAt: occurrence
                )
                record.missionType = alarm.mission.type
                record.outcome = .missed
                store.record(record)
                store.markFired(id: alarm.id, at: occurrence)
                log.info("Recorded missed alarm \(alarm.id.uuidString, privacy: .public)")
            }
        }
    }

    // MARK: - Ringing

    /// Called by the notification delegate when the user taps an alarm alert.
    public func handleNotification(alarmID: UUID, occurrence: Date?, kind: AlarmNotification.Kind) {
        guard let store, let alarm = store.alarm(with: alarmID) else { return }

        switch kind {
        case .wakeCheck:
            if phase == .wakeCheckPending || phase == .idle {
                activeAlarm = alarm
                beginWakeCheck()
            }

        case .alarm, .snooze, .safetyNet:
            // Already handling this one, or a different alarm that must not
            // be interrupted mid-mission.
            if phase != .idle { return }
            // A safety net carries no fire date; resolve it from the schedule
            // so the history and the handled bookkeeping line up.
            let resolved = occurrence
                ?? alarm.mostRecentFireDate(before: Date(), within: catchUpWindow)
                ?? Date()
            if let last = alarm.lastFiredAt, last >= resolved { return }
            markHandled(alarmID: alarmID, date: resolved)
            startRinging(alarm: alarm, occurrence: resolved)

        case .preAlarm, .bedtime:
            break
        }
    }

    /// Immediately fires an alarm — used by the notification "Turn off" action
    /// and by the preview button in the editor.
    ///
    /// A preview rehearses the whole flow, defences included, but is not a
    /// real occurrence: it does not switch a one-shot alarm off, stamp its
    /// last-fired date, or write a wake record.
    public func startRinging(alarm: Alarm, occurrence: Date, isPreview: Bool = false) {
        guard let store else { return }

        activeAlarm = alarm
        occurrenceDate = occurrence
        firedAt = Date()
        snoozeCount = 0
        missionFailures = 0
        accumulatedMissionSeconds = 0
        phase = .ringing

        if isPreview {
            currentRecord = nil
        } else {
            var record = WakeRecord(
                alarmID: alarm.id,
                alarmLabel: alarm.displayLabel,
                scheduledFor: occurrence,
                firedAt: Date()
            )
            record.missionType = alarm.mission.type
            currentRecord = record
        }

        // Defences first: the chain is armed before anything that could
        // trigger a schedule rebuild.
        Task {
            await coordinator.cancelWakeUpCheck(alarmID: alarm.id)
            await takeOverFromSystem(alarm: alarm)
        }

        if !isPreview {
            store.markFired(id: alarm.id, at: occurrence, notify: false)
        }
        beginAudio(for: alarm)
        persistState()
        log.info("Ringing alarm \(alarm.id.uuidString, privacy: .public)")
    }

    /// Arms the live follow-up chain from now and only then stops whatever
    /// the system is alerting for this alarm. The order matters: the app's
    /// audio is already playing, and there must never be a moment where
    /// nothing owned by the system is about to ring.
    private func takeOverFromSystem(alarm: Alarm) async {
        await coordinator.armBackstops(for: alarm, occurrence: occurrenceDate ?? Date())
        coordinator.stopSystemAlert(alarmID: alarm.id)
    }

    private func beginAudio(for alarm: Alarm) {
        // Bedtime ambience never plays under an alarm.
        SleepSoundPlayer.shared.stop()
        let tone = ToneResolver.resolve(alarm.sound.toneID, lastPlayed: playingToneID)
        playingToneID = tone.id
        let shouldLock = store?.settings.lockVolumeWhileRinging ?? true
        audio.startAlarm(tone: tone, settings: alarm.sound, lockVolume: shouldLock)

        if alarm.voiceBriefing.isEnabled {
            VoiceBriefing.shared.speakBriefing(for: alarm, settings: store?.settings ?? AppSettings())
        }
    }

    private func restartAudioIfRinging() {
        guard isAudiblePhase, let alarm = activeAlarm else { return }
        beginAudio(for: alarm)
    }

    // MARK: - Snooze

    public var canSnooze: Bool {
        guard let alarm = activeAlarm, alarm.snooze.isEnabled else { return false }
        return alarm.snooze.isUnlimited || snoozeCount < alarm.snooze.maxCount
    }

    public var snoozesRemainingText: String? {
        guard let alarm = activeAlarm, alarm.snooze.isEnabled else { return nil }
        if alarm.snooze.isUnlimited { return nil }
        let left = max(0, alarm.snooze.maxCount - snoozeCount)
        return left == 1 ? "1 snooze left" : "\(left) snoozes left"
    }

    public func snooze() {
        guard let alarm = activeAlarm, canSnooze else { return }
        // Only from the ring screen. A snooze action on a banner while the
        // mission is on screen would be a way round the mission.
        guard phase == .ringing else { return }

        // Snoozing can be made exactly as much work as getting up.
        if alarm.snooze.requireMissionToSnooze,
           alarm.mission.type != .none,
           alarm.mission.isReady {
            beginMission(intent: .snooze)
            return
        }

        performSnooze()
    }

    private func performSnooze() {
        guard let alarm = activeAlarm else { return }

        let interval = alarm.snooze.interval(forSnoozeIndex: snoozeCount)
        let wakeAt = Date().addingTimeInterval(interval)

        snoozeCount += 1
        currentRecord?.snoozeCount = snoozeCount
        snoozeEndsAt = wakeAt
        phase = .snoozed

        audio.stopAlarm()
        VoiceBriefing.shared.stop()
        persistState()

        Task {
            await coordinator.silence(alarmID: alarm.id)
            await coordinator.scheduleSnooze(alarm: alarm, at: wakeAt)
        }
        log.info("Snoozed until \(wakeAt, privacy: .public)")
    }

    private func resumeFromSnooze() {
        guard let alarm = activeAlarm else {
            teardown(on: .forceStopped)
            return
        }
        snoozeEndsAt = nil
        phase = .ringing
        // The auto-stop window starts again with every ring; measuring it
        // from the original fire time would let three snoozes use it up and
        // end the alarm as "rang out" with no mission done.
        firedAt = Date()
        beginAudio(for: alarm)
        persistState()
        // The system snooze alarm fires at the same instant; the app's audio
        // takes over from it exactly as it does from the first alert.
        Task {
            await coordinator.cancelSnooze(alarmID: alarm.id)
            await takeOverFromSystem(alarm: alarm)
        }
    }

    /// Cuts a snooze short.
    public func wakeNow() {
        guard phase == .snoozed else { return }
        resumeFromSnooze()
    }

    // MARK: - Mission

    /// Invoked when the user slides "Turn off". Goes straight to dismissal
    /// when no mission is configured.
    public func beginTurnOff() {
        guard let alarm = activeAlarm else { return }

        guard alarm.mission.type != .none, alarm.mission.isReady else {
            dismiss()
            return
        }

        beginMission(intent: .dismiss)
    }

    private func beginMission(intent: MissionIntent) {
        missionIntent = intent
        missionStartedAt = Date()
        missionTimeAccrued = false
        missionCompletedRounds = 0
        phase = .mission
        persistState()
    }

    /// Abandons the mission and goes back to the ringing screen.
    public func cancelMission() {
        guard phase == .mission else { return }
        accrueMissionTime()
        missionIntent = .dismiss
        missionCompletedRounds = 0
        phase = .ringing
        persistState()
    }

    public func registerMissionFailure() {
        missionFailures += 1
        persistState()
    }

    /// A round was passed. Saved immediately so a relaunch resumes from the
    /// same round rather than from the beginning.
    public func noteMissionProgress(completedRounds: Int) {
        guard phase == .mission else { return }
        missionCompletedRounds = max(missionCompletedRounds, completedRounds)
        persistState()
    }

    /// The mission was completed. What that earns depends on why it was run.
    public func completeMission() {
        accrueMissionTime()

        switch missionIntent {
        case .dismiss:
            missionIntent = .dismiss
            dismiss()
        case .snooze:
            missionIntent = .dismiss
            performSnooze()
        case .confirmAwake:
            missionIntent = .dismiss
            finishWakeCheck()
        }
    }

    private func accrueMissionTime() {
        if let started = missionStartedAt, !missionTimeAccrued {
            accumulatedMissionSeconds += Date().timeIntervalSince(started)
            missionTimeAccrued = true
        }
    }

    // MARK: - Dismissal

    public func dismiss() {
        guard let alarm = activeAlarm else {
            teardown(on: .forceStopped)
            return
        }

        accrueMissionTime()
        audio.stopAlarm()
        VoiceBriefing.shared.stop()

        // The mission is verifiably done, so the follow-up chain can stand
        // down. `BackstopPolicy` is the gatekeeper for every stand-down.
        coordinator.standDownBackstops(alarmID: alarm.id, on: .missionCompleted)
        nagArmed = false

        if alarm.wakeUpCheck.isEnabled {
            let fireAt = Date().addingTimeInterval(TimeInterval(alarm.wakeUpCheck.delayMinutes * 60))
            wakeCheckFireAt = fireAt
            wakeCheckDeadline = nil
            phase = .wakeCheckPending
            persistState()

            // The confirmation window is enforced by a scheduled alarm, not by
            // a timer in this process. Between dismissing the alarm and the
            // check firing the app will usually be suspended, and a suspended
            // app cannot re-ring anything. Arming the re-ring up front means
            // ignoring the check has the same consequence as failing it.
            // The small buffer gives the in-app path a head start to cancel
            // this if the app happens to be running when the window expires,
            // so the two can never alert on top of each other.
            let reRingAt = fireAt.addingTimeInterval(
                TimeInterval(alarm.wakeUpCheck.confirmWindowSeconds) + Self.wakeCheckReRingBuffer
            )
            // One task, in order: silencing clears the old snooze chain, so
            // it must finish before the re-ring is scheduled under the same
            // prefix or the re-ring could be swept away with it.
            Task {
                await coordinator.silence(alarmID: alarm.id)
                await coordinator.cancelStillRingingNag(alarmID: alarm.id)
                await coordinator.scheduleWakeUpCheck(alarm: alarm, at: fireAt)
                await coordinator.scheduleSnooze(alarm: alarm, at: reRingAt)
            }
            log.info("Wake-up check armed for \(fireAt, privacy: .public), re-ring at \(reRingAt, privacy: .public)")
        } else {
            Task {
                await coordinator.silence(alarmID: alarm.id)
                await coordinator.cancelStillRingingNag(alarmID: alarm.id)
            }
            finishRecord(outcome: .dismissed)
            teardown(on: .missionCompleted)
        }
    }

    // MARK: - Wake-up check

    private func beginWakeCheck() {
        guard let alarm = activeAlarm else {
            teardown(on: .forceStopped)
            return
        }

        wakeCheckFireAt = nil
        wakeCheckDeadline = Date().addingTimeInterval(TimeInterval(alarm.wakeUpCheck.confirmWindowSeconds))
        firedAt = Date()
        phase = .wakeCheckRinging
        beginAudio(for: alarm)
        persistState()
        // This process owns the countdown now. The re-ring that was scheduled
        // behind the check would land partway through a late-started window,
        // so it stands down and the live chain takes its place.
        Task {
            await coordinator.cancelSnooze(alarmID: alarm.id)
            await coordinator.armBackstops(for: alarm, occurrence: occurrenceDate ?? Date())
        }
        log.info("Wake-up check started")
    }

    /// Seconds remaining in the confirmation window, for the countdown ring.
    public var wakeCheckSecondsRemaining: Int {
        guard let deadline = wakeCheckDeadline else { return 0 }
        return max(0, Int(deadline.timeIntervalSince(now).rounded(.up)))
    }

    public var wakeCheckProgress: Double {
        guard let alarm = activeAlarm, let deadline = wakeCheckDeadline else { return 0 }
        let total = Double(alarm.wakeUpCheck.confirmWindowSeconds)
        guard total > 0 else { return 0 }
        return max(0, min(1, deadline.timeIntervalSince(now) / total))
    }

    /// The "I'm up" button.
    public func confirmAwake() {
        guard phase == .wakeCheckRinging || phase == .wakeCheckPending else { return }
        guard let alarm = activeAlarm else {
            teardown(on: .forceStopped)
            return
        }

        // Tapping a button is easy to do without waking up, so the check can
        // be configured to demand the mission again.
        if alarm.wakeUpCheck.requireMission,
           alarm.mission.type != .none,
           alarm.mission.isReady {
            beginMission(intent: .confirmAwake)
            return
        }

        finishWakeCheck()
    }

    private func finishWakeCheck() {
        audio.stopAlarm()
        VoiceBriefing.shared.stop()
        currentRecord?.wakeUpCheckPassed = true
        finishRecord(outcome: .dismissed)

        if let alarm = activeAlarm {
            // Stand down both the check itself and the re-ring armed behind it.
            coordinator.standDownBackstops(alarmID: alarm.id, on: .wakeCheckConfirmed)
            Task {
                await coordinator.cancelWakeUpCheck(alarmID: alarm.id)
                await coordinator.cancelSnooze(alarmID: alarm.id)
                await coordinator.silence(alarmID: alarm.id)
            }
        }
        teardown(on: .wakeCheckConfirmed)
        log.info("Wake-up check confirmed")
    }

    /// The window elapsed without confirmation, so the alarm comes back.
    private func failWakeCheck() {
        guard let alarm = activeAlarm else {
            teardown(on: .forceStopped)
            return
        }

        currentRecord?.wakeUpCheckPassed = false
        wakeCheckDeadline = nil
        snoozeCount = 0
        phase = .ringing
        firedAt = Date()

        // This process is handling the re-ring, so stand down the scheduled
        // one that was armed as the backup — and arm the live chain behind
        // this ring, which a kill must not end.
        Task {
            await coordinator.cancelSnooze(alarmID: alarm.id)
            await takeOverFromSystem(alarm: alarm)
        }

        beginAudio(for: alarm)
        persistState()

        // Keep checking on a loop if configured, otherwise this is the last
        // chance and dismissing will end it.
        if !alarm.wakeUpCheck.repeatUntilConfirmed {
            var updated = alarm
            updated.wakeUpCheck.isEnabled = false
            activeAlarm = updated
        }
        log.info("Wake-up check failed — re-ringing")
    }

    // MARK: - Teardown

    private func finishRecord(outcome: WakeRecord.Outcome) {
        guard var record = currentRecord, let store else { return }
        record.dismissedAt = Date()
        record.snoozeCount = snoozeCount
        record.missionSeconds = accumulatedMissionSeconds
        record.missionFailures = missionFailures
        record.outcome = outcome
        store.record(record)
        currentRecord = nil
    }

    /// Ends the ring. `event` says why, and `BackstopPolicy` decides whether
    /// that reason is allowed to stand the follow-up chain down.
    private func teardown(on event: BackstopPolicy.Event) {
        audio.stopAlarm()
        VoiceBriefing.shared.stop()
        PendingMission.shared.clear()

        if let alarm = activeAlarm {
            coordinator.standDownBackstops(alarmID: alarm.id, on: event)
            nagArmed = false
            Task { await coordinator.cancelStillRingingNag(alarmID: alarm.id) }
        }

        phase = .idle
        activeAlarm = nil
        occurrenceDate = nil
        firedAt = nil
        snoozeEndsAt = nil
        wakeCheckFireAt = nil
        wakeCheckDeadline = nil
        missionStartedAt = nil
        missionCompletedRounds = 0
        accumulatedMissionSeconds = 0
        missionFailures = 0
        snoozeCount = 0
        currentRecord = nil

        files.delete(StorageLocation.ringStateFile)

        // Rebuild so the next occurrence of a repeating alarm is scheduled.
        if let store {
            coordinator.rebuild(alarms: store.alarms, settings: store.settings)
        }
        updateKeepAlive()
    }

    /// Emergency exit used by the diagnostics screen if something wedges.
    public func forceStop() {
        finishRecord(outcome: .dismissed)
        teardown(on: .forceStopped)
    }

    // MARK: - Occurrence bookkeeping

    private func occurrenceKey(alarmID: UUID, date: Date) -> String {
        "\(alarmID.uuidString)@\(Int(date.timeIntervalSince1970))"
    }

    private func markHandled(alarmID: UUID, date: Date) {
        handledOccurrences[occurrenceKey(alarmID: alarmID, date: date)] = date
        // Keep only the last couple of days so the file cannot grow forever.
        let cutoff = Date().addingTimeInterval(-2 * 86_400)
        handledOccurrences = handledOccurrences.filter { $0.value > cutoff }
    }

    // MARK: - Persistence

    private func persistState() {
        guard let alarm = activeAlarm, let occurrence = occurrenceDate, phase != .idle else {
            files.delete(StorageLocation.ringStateFile)
            return
        }

        let state = PersistedRingState(
            alarmID: alarm.id,
            occurrenceDate: occurrence,
            firedAt: firedAt ?? Date(),
            snoozeCount: snoozeCount,
            phase: phase,
            snoozeEndsAt: snoozeEndsAt,
            wakeCheckFireAt: wakeCheckFireAt,
            wakeCheckDeadline: wakeCheckDeadline,
            recordID: currentRecord?.id,
            playedToneID: playingToneID,
            handledOccurrences: handledOccurrences,
            missionIntent: missionIntent.rawValue,
            missionStartedAt: missionStartedAt,
            missionCompletedRounds: missionCompletedRounds,
            accumulatedMissionSeconds: accumulatedMissionSeconds,
            missionFailures: missionFailures
        )
        files.saveNow(state, to: StorageLocation.ringStateFile)
    }

    private func restoreState() {
        guard let state = files.load(PersistedRingState.self, from: StorageLocation.ringStateFile) else { return }
        handledOccurrences = state.handledOccurrences

        guard let store, let alarm = store.alarm(with: state.alarmID) else {
            files.delete(StorageLocation.ringStateFile)
            return
        }

        let plan = RingStateRestorePlan.make(from: state, now: Date())
        switch plan {
        case .nothing:
            files.delete(StorageLocation.ringStateFile)
            return

        case .discardAsStale:
            // Too old to ring now, but the history should say what happened.
            var record = WakeRecord(
                alarmID: alarm.id,
                alarmLabel: alarm.displayLabel,
                scheduledFor: state.occurrenceDate,
                firedAt: state.firedAt
            )
            record.missionType = alarm.mission.type
            record.snoozeCount = state.snoozeCount
            record.outcome = .rangOut
            store.record(record)
            files.delete(StorageLocation.ringStateFile)
            coordinator.standDownBackstops(alarmID: alarm.id, on: .rangOut)
            log.info("Discarded stale ring state from \(state.firedAt, privacy: .public)")
            return

        case .resume(let resumedPhase, let restartAudio):
            activeAlarm = alarm
            occurrenceDate = state.occurrenceDate
            firedAt = state.firedAt
            snoozeCount = state.snoozeCount
            snoozeEndsAt = state.snoozeEndsAt
            wakeCheckFireAt = state.wakeCheckFireAt
            wakeCheckDeadline = state.wakeCheckDeadline
            playingToneID = state.playedToneID
            missionIntent = state.missionIntent.flatMap(MissionIntent.init(rawValue:)) ?? .dismiss
            missionStartedAt = state.missionStartedAt
            missionCompletedRounds = state.missionCompletedRounds ?? 0
            accumulatedMissionSeconds = state.accumulatedMissionSeconds ?? 0
            missionFailures = state.missionFailures ?? 0

            var record = WakeRecord(
                alarmID: alarm.id,
                alarmLabel: alarm.displayLabel,
                scheduledFor: state.occurrenceDate,
                firedAt: state.firedAt
            )
            record.missionType = alarm.mission.type
            record.snoozeCount = state.snoozeCount
            currentRecord = record

            if resumedPhase == .mission, missionStartedAt == nil {
                // Older state without a start time: the runner needs one.
                missionStartedAt = Date()
            }

            phase = resumedPhase
            if restartAudio {
                // The auto-stop window restarts with this ring, and the
                // reminders armed before the kill are cancelled on the first
                // foreground pass.
                firedAt = Date()
                nagArmed = true
                beginAudio(for: alarm)
                // The process was gone, so the live chain was not being kept
                // ahead; re-arm it from now and stop anything alerting.
                Task { await takeOverFromSystem(alarm: alarm) }
            }
            log.info("Restored ring state in phase \(resumedPhase.rawValue, privacy: .public)")
        }
    }
}
