import XCTest
@testable import SuperAlarm

/// The three field-observed failures — volume-down defeating the lock, a
/// force-quit ending the alarm, and a walking mission that felt stuck — each
/// come down to a decision that can be pinned here without hardware.
final class VolumeLockPolicyTests: XCTestCase {

    func testOverrideAlwaysTargetsFullVolume() {
        XCTAssertEqual(VolumeLockPolicy.initialTarget(overridesSystemVolume: true, current: 0.1), 1.0)
        XCTAssertEqual(VolumeLockPolicy.initialTarget(overridesSystemVolume: true, current: 0.0), 1.0)
    }

    func testWithoutOverrideTheCurrentLevelIsHeldButNeverBelowTheFloor() {
        XCTAssertEqual(VolumeLockPolicy.initialTarget(overridesSystemVolume: false, current: 0.7), 0.7)
        XCTAssertEqual(
            VolumeLockPolicy.initialTarget(overridesSystemVolume: false, current: 0.05),
            VolumeLockPolicy.floor,
            "Locking a muted phone at zero would defend a silent alarm"
        )
    }

    func testOneVolumeButtonStepIsAlwaysCaught() {
        // iOS moves the hardware volume in sixteenths.
        let policy = VolumeLockPolicy(target: 1.0)
        XCTAssertTrue(policy.shouldRestore(observed: 1.0 - 1.0 / 16.0))
        XCTAssertTrue(policy.shouldRestore(observed: 0.0))
    }

    func testFloatNoiseAndHigherLevelsDoNotTriggerARestore() {
        let policy = VolumeLockPolicy(target: 0.8)
        XCTAssertFalse(policy.shouldRestore(observed: 0.8))
        XCTAssertFalse(policy.shouldRestore(observed: 0.79))
        XCTAssertFalse(policy.shouldRestore(observed: 1.0), "Turning it up is allowed")
    }

    func testRampedTargetRisesMonotonicallyBetweenItsEndpoints() {
        XCTAssertEqual(VolumeLockPolicy.rampedTarget(start: 0.3, end: 1.0, progress: 0), 0.3)
        XCTAssertEqual(VolumeLockPolicy.rampedTarget(start: 0.3, end: 1.0, progress: 1), 1.0)
        XCTAssertEqual(VolumeLockPolicy.rampedTarget(start: 0.3, end: 1.0, progress: 2), 1.0, "Clamped")
        var last: Float = 0
        for step in 0...20 {
            let value = VolumeLockPolicy.rampedTarget(start: 0.3, end: 1.0, progress: Double(step) / 20)
            XCTAssertGreaterThanOrEqual(value, last)
            last = value
        }
    }

    func testTargetIsClampedToTheUnitRange() {
        XCTAssertEqual(VolumeLockPolicy(target: 1.7).target, 1.0)
        XCTAssertEqual(VolumeLockPolicy(target: -0.2).target, 0.0)
    }
}

final class BackstopPolicyTests: XCTestCase {

    func testLiveChainAnswersAKillWithinThirtySecondsAndNeverLeavesAMinuteGap() {
        let offsets = BackstopPolicy.liveOffsets
        XCTAssertEqual(offsets.first, 30)
        XCTAssertEqual(offsets, offsets.sorted())
        for (previous, next) in zip(offsets, offsets.dropFirst()) {
            XCTAssertLessThanOrEqual(next - previous, 60, "Gap between \(previous) and \(next) is too long")
            XCTAssertGreaterThan(next, previous)
        }
        XCTAssertGreaterThanOrEqual(offsets.last ?? 0, 5 * 60, "The chain should keep coming for minutes")
    }

    func testPreArmedChainStartsWithinThirtySecondsOfTheAlarm() {
        let offsets = BackstopPolicy.preArmedOffsets
        XCTAssertEqual(offsets.first, 30)
        XCTAssertEqual(offsets, offsets.sorted())
        XCTAssertEqual(Set(offsets).count, offsets.count, "Two backstops at the same instant waste the budget")
    }

    func testHeartbeatRunsFasterThanTheFirstBackstop() {
        // Otherwise a backstop fires while the app is alive and interrupts
        // the mission with a system alert.
        XCTAssertLessThan(BackstopPolicy.heartbeatInterval, BackstopPolicy.firstOffset)
        XCTAssertLessThanOrEqual(BackstopPolicy.liveTailSpacing, 60)
    }

    func testHeartbeatIsDueWhenNeverArmedOrAfterTheInterval() {
        let now = Date()
        XCTAssertTrue(BackstopPolicy.heartbeatIsDue(lastArmedAt: nil, now: now))
        XCTAssertFalse(BackstopPolicy.heartbeatIsDue(lastArmedAt: now.addingTimeInterval(-1), now: now))
        XCTAssertTrue(
            BackstopPolicy.heartbeatIsDue(
                lastArmedAt: now.addingTimeInterval(-BackstopPolicy.heartbeatInterval),
                now: now
            )
        )
    }

    func testOnlyVerifiedCompletionMayStandTheChainDown() {
        let allowed: Set<BackstopPolicy.Event> = [.missionCompleted, .wakeCheckConfirmed, .rangOut, .forceStopped]
        for event in BackstopPolicy.Event.allCases {
            XCTAssertEqual(
                BackstopPolicy.mayStandDown(on: event),
                allowed.contains(event),
                "\(event.rawValue) has the wrong stand-down rule"
            )
        }
        // The three ways a sleeper tries to escape must all leave it armed.
        XCTAssertFalse(BackstopPolicy.mayStandDown(on: .systemStopButton))
        XCTAssertFalse(BackstopPolicy.mayStandDown(on: .appLeft))
        XCTAssertFalse(BackstopPolicy.mayStandDown(on: .snoozed))
    }

    func testChainDatesAreOffsetFromTheBase() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let dates = BackstopPolicy.dates(from: base, offsets: [30, 60])
        XCTAssertEqual(dates, [base.addingTimeInterval(30), base.addingTimeInterval(60)])
    }

    func testStillRingingNagLandsWithinFiveSecondsAndRepeatsEveryTwentyToThirty() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let dates = BackstopPolicy.nagDates(from: base)
        XCTAssertLessThanOrEqual(dates.first!.timeIntervalSince(base), 5)
        for (previous, next) in zip(dates, dates.dropFirst()) {
            let gap = next.timeIntervalSince(previous)
            XCTAssertGreaterThanOrEqual(gap, 20)
            XCTAssertLessThanOrEqual(gap, 30)
        }
    }

    func testNotificationChainOffsetInterleavesWithTheBackstops() {
        // The chain must start after the first system alert has had its say,
        // and must not land on the same second as a backstop.
        let offset = BackstopPolicy.chainOffsetWithSystemAlarms
        XCTAssertGreaterThan(offset, 30)
        XCTAssertFalse(BackstopPolicy.preArmedOffsets.contains(offset))
    }
}

final class RingStateRestorePlanTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func state(
        phase: AlarmRuntime.Phase,
        firedAgo: TimeInterval,
        snoozeEndsIn: TimeInterval? = nil,
        wakeCheckIn: TimeInterval? = nil,
        wakeCheckDeadlineIn: TimeInterval? = nil,
        missionStartedAgo: TimeInterval? = nil
    ) -> PersistedRingState {
        PersistedRingState(
            alarmID: UUID(),
            occurrenceDate: now.addingTimeInterval(-firedAgo),
            firedAt: now.addingTimeInterval(-firedAgo),
            snoozeCount: 0,
            phase: phase,
            snoozeEndsAt: snoozeEndsIn.map { now.addingTimeInterval($0) },
            wakeCheckFireAt: wakeCheckIn.map { now.addingTimeInterval($0) },
            wakeCheckDeadline: wakeCheckDeadlineIn.map { now.addingTimeInterval($0) },
            recordID: nil,
            playedToneID: nil,
            handledOccurrences: [:],
            missionIntent: nil,
            missionStartedAt: missionStartedAgo.map { now.addingTimeInterval(-$0) },
            missionCompletedRounds: nil,
            accumulatedMissionSeconds: nil,
            missionFailures: nil
        )
    }

    func testAFreshRingResumesRingingWithAudio() {
        XCTAssertEqual(
            RingStateRestorePlan.make(from: state(phase: .ringing, firedAgo: 90), now: now),
            .resume(.ringing, restartAudio: true)
        )
    }

    func testAMissionInProgressResumesTheMissionNotTheRing() {
        // This is the force-quit case: the sleeper must land back on the
        // mission they still owe.
        XCTAssertEqual(
            RingStateRestorePlan.make(from: state(phase: .mission, firedAgo: 200, missionStartedAgo: 60), now: now),
            .resume(.mission, restartAudio: true)
        )
    }

    func testStateOlderThanTheWindowIsDiscarded() {
        let stale = state(phase: .ringing, firedAgo: RingStateRestorePlan.staleAfter + 60)
        XCTAssertEqual(RingStateRestorePlan.make(from: stale, now: now), .discardAsStale)
    }

    func testASnoozeIsJudgedByItsEndNotTheOriginalFireTime() {
        // Fired three hours ago but the snooze ends in a minute: still live.
        let snoozed = state(phase: .snoozed, firedAgo: 3 * 3600, snoozeEndsIn: 60)
        XCTAssertEqual(RingStateRestorePlan.make(from: snoozed, now: now), .resume(.snoozed, restartAudio: false))

        let abandoned = state(phase: .snoozed, firedAgo: 6 * 3600, snoozeEndsIn: -(3 * 3600))
        XCTAssertEqual(RingStateRestorePlan.make(from: abandoned, now: now), .discardAsStale)
    }

    func testWakeCheckPhasesResume() {
        XCTAssertEqual(
            RingStateRestorePlan.make(from: state(phase: .wakeCheckPending, firedAgo: 600, wakeCheckIn: 120), now: now),
            .resume(.wakeCheckPending, restartAudio: false)
        )
        XCTAssertEqual(
            RingStateRestorePlan.make(from: state(phase: .wakeCheckRinging, firedAgo: 900, wakeCheckDeadlineIn: 30), now: now),
            .resume(.wakeCheckRinging, restartAudio: true)
        )
    }

    func testIdleStateIsNothingAndAFutureFireDateIsDiscarded() {
        XCTAssertEqual(RingStateRestorePlan.make(from: state(phase: .idle, firedAgo: 10), now: now), .nothing)
        XCTAssertEqual(
            RingStateRestorePlan.make(from: state(phase: .ringing, firedAgo: -3600), now: now),
            .discardAsStale,
            "A clock jump must not resurrect an alarm"
        )
    }

    func testAStateFileMissingOptionalKeysOrWithAnUnknownPhaseStillResumes() throws {
        // A newer build's phase name, and none of the defaulted keys.
        let json = """
        {
          "alarmID": "1B4E28BA-2FA1-11D2-883F-B9A761BDE3FB",
          "occurrenceDate": 1800000000,
          "firedAt": 1800000000,
          "snoozeCount": 0,
          "phase": "somethingNew"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let state = try decoder.decode(PersistedRingState.self, from: Data(json.utf8))
        XCTAssertEqual(state.phase, .ringing, "An unknown phase must resume as a ring, never drop the alarm")
        XCTAssertTrue(state.handledOccurrences.isEmpty)
    }

    func testOlderStateFilesWithoutMissionFieldsStillDecode() throws {
        // Written by a build that predates mission persistence.
        let json = """
        {
          "alarmID": "1B4E28BA-2FA1-11D2-883F-B9A761BDE3FB",
          "occurrenceDate": 1800000000,
          "firedAt": 1800000000,
          "snoozeCount": 1,
          "phase": "mission",
          "handledOccurrences": {}
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let state = try decoder.decode(PersistedRingState.self, from: Data(json.utf8))

        XCTAssertEqual(state.phase, .mission)
        XCTAssertNil(state.missionStartedAt)
        XCTAssertNil(state.missionCompletedRounds)
        XCTAssertEqual(
            RingStateRestorePlan.make(from: state, now: Date(timeIntervalSince1970: 1_800_000_100)),
            .resume(.mission, restartAudio: true)
        )
    }
}

final class StepCountModelTests: XCTestCase {

    func testCountNeverGoesBackwardsAcrossSources() {
        var model = StepCountModel(goal: 100)
        XCTAssertTrue(model.ingest(total: 3, from: .liveUpdate).countChanged)
        XCTAssertEqual(model.count, 3)

        // A query knows about steps the live stream has not reported yet.
        XCTAssertTrue(model.ingest(total: 8, from: .query).countChanged)
        XCTAssertEqual(model.count, 8)

        // The live stream catching up with a lower total must not regress.
        XCTAssertFalse(model.ingest(total: 5, from: .liveUpdate).countChanged)
        XCTAssertEqual(model.count, 8)

        // Nor may a query that reports fewer than before.
        XCTAssertFalse(model.ingest(total: 6, from: .query).countChanged)
        XCTAssertEqual(model.count, 8)
    }

    func testBatchesInTypicalPedometerShapeReachTheGoalOnce() {
        var model = StepCountModel(goal: 30)
        var completions = 0
        for total in [0, 0, 7, 7, 15, 22, 22, 31, 40] {
            if model.ingest(total: total, from: .liveUpdate).justCompleted { completions += 1 }
        }
        XCTAssertEqual(completions, 1)
        XCTAssertTrue(model.isComplete)
        XCTAssertEqual(model.count, 30, "Clamped to the goal")
        XCTAssertEqual(model.remaining, 0)
        XCTAssertEqual(model.progress, 1.0, accuracy: 0.0001)
    }

    func testNegativeAndZeroTotalsAreHarmless() {
        var model = StepCountModel(goal: 10)
        XCTAssertFalse(model.ingest(total: -4, from: .query).countChanged)
        XCTAssertFalse(model.ingest(total: 0, from: .liveUpdate).countChanged)
        XCTAssertEqual(model.count, 0)
        XCTAssertFalse(model.isComplete)
    }

    func testMovementIsDetectedBeforeAnyStepsArriveAndDecaysWhenStill() {
        var model = StepCountModel(goal: 50)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)

        model.ingestAcceleration(magnitude: 1.0, at: t0)
        XCTAssertFalse(model.isMoving)
        XCTAssertEqual(model.hint, "Get up and start walking")

        model.ingestAcceleration(magnitude: 1.3, at: t0.addingTimeInterval(0.5))
        XCTAssertTrue(model.isMoving)
        XCTAssertEqual(model.hint, "Movement detected — counting…")

        // Still within the hold window: keep saying so.
        model.ingestAcceleration(magnitude: 1.0, at: t0.addingTimeInterval(1.0))
        XCTAssertTrue(model.isMoving)

        model.ingestAcceleration(magnitude: 1.0, at: t0.addingTimeInterval(0.5 + StepCountModel.movementHold + 0.1))
        XCTAssertFalse(model.isMoving)
    }

    func testHintCountsDownWhileWalking() {
        var model = StepCountModel(goal: 20)
        model.ingest(total: 5, from: .query)
        XCTAssertEqual(model.hint, "15 to go")
        model.ingestAcceleration(magnitude: 1.4, at: Date())
        XCTAssertEqual(model.hint, "15 to go — keep walking")
        model.ingest(total: 25, from: .liveUpdate)
        XCTAssertEqual(model.hint, "Done")
    }

    func testWalkGoalMinimumClearsThePedometerBatchSize() {
        // A goal below one batch of steps reads as a stuck counter.
        XCTAssertGreaterThanOrEqual(MissionType.walk.goalRange.min, 30)
    }
}

final class MissionResumeTests: XCTestCase {

    @MainActor
    func testASessionResumesFromPersistedRoundsAndReportsProgress() {
        var settings = MissionSettings(type: .math)
        settings.rounds = 3
        let startedAt = Date().addingTimeInterval(-45)
        let session = MissionSession(settings: settings, now: startedAt, completedRounds: 2)

        var progress: [Int] = []
        var completions = 0
        session.onProgress = { progress.append($0) }
        session.onComplete = { completions += 1 }

        XCTAssertEqual(session.currentRound, 3)
        XCTAssertEqual(session.startedAt, startedAt, "Elapsed time and step counts continue from the original start")

        session.passRound()
        XCTAssertTrue(session.isComplete)
        XCTAssertEqual(progress, [3])
        XCTAssertEqual(completions, 1)
    }

    @MainActor
    func testResumedRoundsAreClampedToTheConfiguredTotal() {
        var settings = MissionSettings(type: .memory)
        settings.rounds = 2
        let session = MissionSession(settings: settings, completedRounds: 9)
        XCTAssertEqual(session.completedRounds, 2)
        XCTAssertFalse(session.isComplete, "Resuming must not complete a mission by itself")
    }

    @MainActor
    func testATimeLimitAccountsForTimeAlreadySpent() {
        var settings = MissionSettings(type: .typing)
        settings.timeLimitSeconds = 120
        let reference = Date(timeIntervalSince1970: 1_800_000_000)
        let session = MissionSession(
            settings: settings,
            now: reference.addingTimeInterval(-50),
            reference: reference
        )
        XCTAssertEqual(session.secondsRemaining, 70)
    }
}

final class DueDecisionTests: XCTestCase {

    private var calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    private func date(_ hour: Int, _ minute: Int) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 6
        components.hour = hour
        components.minute = minute
        return calendar.date(from: components)!
    }

    private func dailyAlarm() -> Alarm {
        var alarm = Alarm(hour: 7, minute: 0)
        alarm.repeatMode = .weekly
        alarm.repeatDays = Weekday.everyDay
        return alarm
    }

    func testAnAlarmThatJustPassedRings() {
        let decision = DueDecision.make(
            for: dailyAlarm(), reference: date(7, 2), catchUpWindow: 1800,
            alreadyHandled: { _ in false }, calendar: calendar
        )
        XCTAssertEqual(decision, .ring(date(7, 0)))
    }

    func testAnOccurrenceTheStoreAlreadyFiredIsIgnored() {
        // The in-memory bookkeeping dies with the process; the store's
        // last-fired stamp is what stops a dismissed alarm re-ringing.
        var alarm = dailyAlarm()
        alarm.lastFiredAt = date(7, 0)
        let decision = DueDecision.make(
            for: alarm, reference: date(7, 10), catchUpWindow: 1800,
            alreadyHandled: { _ in false }, calendar: calendar
        )
        XCTAssertEqual(decision, .none)
    }

    func testASafetyNetStampLaterThanTheOccurrenceStillCounts() {
        var alarm = dailyAlarm()
        alarm.lastFiredAt = date(7, 4)
        let decision = DueDecision.make(
            for: alarm, reference: date(7, 10), catchUpWindow: 1800,
            alreadyHandled: { _ in false }, calendar: calendar
        )
        XCTAssertEqual(decision, .none)
    }

    func testASkippedOccurrenceClearsTheSkipInsteadOfRinging() {
        var alarm = dailyAlarm()
        alarm.skipNextOccurrence = true
        let decision = DueDecision.make(
            for: alarm, reference: date(7, 1), catchUpWindow: 1800,
            alreadyHandled: { _ in false }, calendar: calendar
        )
        XCTAssertEqual(decision, .clearSkip(date(7, 0)), "Otherwise the skip swallows every later occurrence")
    }

    func testTooLateIsRecordedAsMissed() {
        var alarm = dailyAlarm()
        alarm.sound.autoStopMinutes = 5
        let decision = DueDecision.make(
            for: alarm, reference: date(7, 20), catchUpWindow: 1800,
            alreadyHandled: { _ in false }, calendar: calendar
        )
        XCTAssertEqual(decision, .missed(date(7, 0)))
    }

    func testHandledAndDisabledAlarmsDoNothing() {
        XCTAssertEqual(
            DueDecision.make(
                for: dailyAlarm(), reference: date(7, 2), catchUpWindow: 1800,
                alreadyHandled: { _ in true }, calendar: calendar
            ),
            .none
        )
        var off = dailyAlarm()
        off.isEnabled = false
        XCTAssertEqual(
            DueDecision.make(
                for: off, reference: date(7, 2), catchUpWindow: 1800,
                alreadyHandled: { _ in false }, calendar: calendar
            ),
            .none
        )
    }
}
