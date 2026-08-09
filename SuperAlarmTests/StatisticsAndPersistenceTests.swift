import XCTest
@testable import SuperAlarm

final class StatisticsTests: XCTestCase {

    private var calendar: Calendar!

    override func setUp() {
        super.setUp()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        calendar = cal
    }

    private func day(_ year: Int, _ month: Int, _ dayOfMonth: Int, hour: Int = 7) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = dayOfMonth
        components.hour = hour
        return calendar.date(from: components)!
    }

    private func record(
        on date: Date,
        outcome: WakeRecord.Outcome = .dismissed,
        snoozes: Int = 0,
        dismissAfter seconds: TimeInterval = 60
    ) -> WakeRecord {
        var entry = WakeRecord(alarmID: UUID(), alarmLabel: "Test", scheduledFor: date, firedAt: date)
        entry.outcome = outcome
        entry.snoozeCount = snoozes
        entry.dismissedAt = date.addingTimeInterval(seconds)
        return entry
    }

    func testEmptyHistoryProducesZeroes() {
        let stats = WakeStatistics(records: [], now: day(2026, 8, 6), calendar: calendar)
        XCTAssertEqual(stats.currentStreak, 0)
        XCTAssertEqual(stats.longestStreak, 0)
        XCTAssertEqual(stats.totalWakeUps, 0)
        XCTAssertEqual(stats.successRate, 0)
        XCTAssertEqual(stats.recentDays.count, 30)
    }

    func testConsecutiveSuccessesBuildAStreak() {
        let records = [
            record(on: day(2026, 8, 4)),
            record(on: day(2026, 8, 5)),
            record(on: day(2026, 8, 6)),
        ]
        let stats = WakeStatistics(records: records, now: day(2026, 8, 6, hour: 12), calendar: calendar)

        XCTAssertEqual(stats.currentStreak, 3)
        XCTAssertEqual(stats.longestStreak, 3)
        XCTAssertEqual(stats.totalWakeUps, 3)
        XCTAssertEqual(stats.successCount, 3)
        XCTAssertEqual(stats.successRate, 1.0, accuracy: 0.0001)
    }

    func testTodayNotDoneYetDoesNotBreakTheStreak() {
        // Yesterday and the day before succeeded; today has not happened yet.
        let records = [
            record(on: day(2026, 8, 4)),
            record(on: day(2026, 8, 5)),
        ]
        let stats = WakeStatistics(records: records, now: day(2026, 8, 6, hour: 3), calendar: calendar)

        XCTAssertEqual(stats.currentStreak, 2, "A streak should survive until a whole day is missed")
    }

    func testAMissedDayBreaksTheStreak() {
        let records = [
            record(on: day(2026, 8, 1)),
            record(on: day(2026, 8, 2)),
            // 3 August missing entirely.
            record(on: day(2026, 8, 4)),
            record(on: day(2026, 8, 5)),
        ]
        let stats = WakeStatistics(records: records, now: day(2026, 8, 5, hour: 12), calendar: calendar)

        XCTAssertEqual(stats.currentStreak, 2)
        XCTAssertEqual(stats.longestStreak, 2)
    }

    func testFailedOutcomesDoNotCountTowardStreaks() {
        let records = [
            record(on: day(2026, 8, 4)),
            record(on: day(2026, 8, 5), outcome: .missed),
            record(on: day(2026, 8, 6)),
        ]
        let stats = WakeStatistics(records: records, now: day(2026, 8, 6, hour: 12), calendar: calendar)

        XCTAssertEqual(stats.currentStreak, 1)
        XCTAssertEqual(stats.successCount, 2)
        XCTAssertEqual(stats.totalWakeUps, 3)
        XCTAssertEqual(stats.successRate, 2.0 / 3.0, accuracy: 0.0001)
    }

    func testLongestStreakSurvivesLaterBreaks() {
        var records: [WakeRecord] = []
        // A five-day run in July.
        for offset in 1...5 { records.append(record(on: day(2026, 7, offset))) }
        // A two-day run in August.
        records.append(record(on: day(2026, 8, 5)))
        records.append(record(on: day(2026, 8, 6)))

        let stats = WakeStatistics(records: records, now: day(2026, 8, 6, hour: 12), calendar: calendar)
        XCTAssertEqual(stats.longestStreak, 5)
        XCTAssertEqual(stats.currentStreak, 2)
    }

    func testSnoozeAndTimingAggregates() {
        let records = [
            record(on: day(2026, 8, 5), snoozes: 2, dismissAfter: 120),
            record(on: day(2026, 8, 6), snoozes: 4, dismissAfter: 240),
        ]
        let stats = WakeStatistics(records: records, now: day(2026, 8, 6, hour: 12), calendar: calendar)

        XCTAssertEqual(stats.totalSnoozes, 6)
        XCTAssertEqual(stats.averageDismissSeconds, 180, accuracy: 0.001)
    }

    func testWeekdayBreakdownCountsOnlySuccesses() {
        // 3 August 2026 is a Monday.
        let records = [
            record(on: day(2026, 8, 3)),
            record(on: day(2026, 8, 10)),
            record(on: day(2026, 8, 17), outcome: .missed),
        ]
        let stats = WakeStatistics(records: records, now: day(2026, 8, 20), calendar: calendar)

        XCTAssertEqual(stats.byWeekday[Weekday.monday.rawValue], 2)
    }

    func testRecentDaysWindowIsAlwaysThirtyDaysEndingToday() {
        let stats = WakeStatistics(
            records: [record(on: day(2026, 8, 6))],
            now: day(2026, 8, 6, hour: 12),
            calendar: calendar
        )

        XCTAssertEqual(stats.recentDays.count, 30)
        XCTAssertEqual(stats.recentDays.last?.date, calendar.startOfDay(for: day(2026, 8, 6)))
        XCTAssertTrue(stats.recentDays.last?.succeeded ?? false)
        XCTAssertEqual(stats.recentDays.map(\.date), stats.recentDays.map(\.date).sorted())
    }

    func testPunctualityUsesDismissalNotFireTime() {
        var late = WakeRecord(
            alarmID: UUID(), alarmLabel: "Late",
            scheduledFor: day(2026, 8, 6), firedAt: day(2026, 8, 6)
        )
        late.dismissedAt = day(2026, 8, 6).addingTimeInterval(20 * 60)
        XCTAssertFalse(late.wasPunctual)

        var prompt = late
        prompt.dismissedAt = day(2026, 8, 6).addingTimeInterval(90)
        XCTAssertTrue(prompt.wasPunctual)
    }

    func testDurationLabelFormatting() {
        var entry = WakeRecord(
            alarmID: nil, alarmLabel: "x",
            scheduledFor: day(2026, 8, 6), firedAt: day(2026, 8, 6)
        )
        XCTAssertEqual(entry.durationLabel, "—")

        entry.dismissedAt = day(2026, 8, 6).addingTimeInterval(45)
        XCTAssertEqual(entry.durationLabel, "45s")

        entry.dismissedAt = day(2026, 8, 6).addingTimeInterval(120)
        XCTAssertEqual(entry.durationLabel, "2m")

        entry.dismissedAt = day(2026, 8, 6).addingTimeInterval(135)
        XCTAssertEqual(entry.durationLabel, "2m 15s")
    }
}

// MARK: - Persistence

final class PersistenceTests: XCTestCase {

    /// Mirrors `JSONFileStore`'s strategy, which keeps milliseconds so that
    /// dates survive a round trip intact.
    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(PersistenceTests.iso.string(from: date))
        }
        return encoder
    }

    private func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = PersistenceTests.iso.date(from: text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: text)
            }
            return date
        }
        return decoder
    }

    func testAlarmSurvivesAFullRoundTrip() throws {
        var alarm = Alarm(hour: 6, minute: 45)
        alarm.label = "Gym"
        alarm.memo = "Kit is by the door"
        alarm.repeatMode = .weekly
        alarm.repeatDays = [.monday, .thursday]
        alarm.mission = MissionSettings(type: .walk)
        alarm.mission.goal = 750
        alarm.mission.rounds = 2
        alarm.sound.toneID = "police_siren"
        alarm.sound.volume = 0.8
        alarm.snooze.isUnlimited = false
        alarm.snooze.maxCount = 2
        alarm.wakeUpCheck.isEnabled = true
        alarm.wakeUpCheck.delayMinutes = 5
        alarm.preAlarm.isEnabled = true
        alarm.voiceBriefing.isEnabled = true
        alarm.colorTag = 3
        // Pinned to a millisecond boundary. `Date()` carries sub-millisecond
        // precision that no text format preserves, so comparing it for exact
        // equality after a round trip would be testing the formatter's
        // resolution rather than the model.
        alarm.createdAt = Date(timeIntervalSince1970: 1_770_000_000)

        let data = try makeEncoder().encode(alarm)
        let restored = try makeDecoder().decode(Alarm.self, from: data)

        XCTAssertEqual(restored, alarm)
    }

    func testDatesKeepMillisecondPrecisionThroughTheStore() throws {
        // Guards the reason the strategy is custom rather than `.iso8601`:
        // whole-second truncation would silently reorder alarms created in
        // the same second, since `createdAt` is the sort tiebreaker.
        var alarm = Alarm(hour: 7, minute: 0)
        alarm.createdAt = Date(timeIntervalSince1970: 1_770_000_000.125)

        let restored = try makeDecoder().decode(Alarm.self, from: try makeEncoder().encode(alarm))
        XCTAssertEqual(
            restored.createdAt.timeIntervalSince1970,
            1_770_000_000.125,
            accuracy: 0.0005
        )
    }

    func testAlarmDecodesFromMinimalJSONWithSensibleDefaults() throws {
        // Simulates an alarm written by an older build that predates several
        // settings. Losing a user's alarms on update is unacceptable.
        let json = Data(#"{"hour": 6, "minute": 30}"#.utf8)
        let alarm = try makeDecoder().decode(Alarm.self, from: json)

        XCTAssertEqual(alarm.hour, 6)
        XCTAssertEqual(alarm.minute, 30)
        XCTAssertTrue(alarm.isEnabled)
        XCTAssertEqual(alarm.repeatMode, .once)
        XCTAssertEqual(alarm.mission.type, .none)
        XCTAssertEqual(alarm.sound.toneID, SoundCatalog.defaultToneID)
        XCTAssertTrue(alarm.sound.isEnabled)
        XCTAssertEqual(alarm.snooze.intervalMinutes, 5)
        XCTAssertFalse(alarm.wakeUpCheck.isEnabled)
        XCTAssertGreaterThan(alarm.mission.escapeHatchAfterSeconds, 0)
    }

    func testLegacyAlarmWithRepeatDaysInfersWeeklyMode() throws {
        // `repeatMode` did not always exist; days alone used to imply weekly.
        let json = Data(#"{"hour": 7, "minute": 0, "repeatDays": [2, 4]}"#.utf8)
        let alarm = try makeDecoder().decode(Alarm.self, from: json)

        XCTAssertEqual(alarm.repeatMode, .weekly)
        XCTAssertEqual(alarm.repeatDays, [.monday, .wednesday])
        XCTAssertTrue(alarm.isRepeating)
    }

    func testOutOfRangeTimesAreClamped() throws {
        let json = Data(#"{"hour": 99, "minute": -5}"#.utf8)
        let alarm = try makeDecoder().decode(Alarm.self, from: json)

        XCTAssertEqual(alarm.hour, 23)
        XCTAssertEqual(alarm.minute, 0)
    }

    func testSettingsRoundTripAndDefaults() throws {
        var settings = AppSettings()
        settings.theme = .dark
        settings.use24HourClock = true
        settings.temperatureUnit = .fahrenheit
        settings.sleepSound.soundID = "campfire"
        settings.sleepSound.durationMinutes = 45
        settings.bedtimeReminderEnabled = true
        settings.keepAliveWindowHours = 8

        let data = try makeEncoder().encode(settings)
        let restored = try makeDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(restored, settings)

        let empty = try makeDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(empty.theme, .system)
        XCTAssertFalse(empty.use24HourClock)
        XCTAssertTrue(empty.lockVolumeWhileRinging)
        XCTAssertFalse(empty.redundantNotificationBackup)
        XCTAssertFalse(empty.hasCompletedOnboarding)
    }

    func testWakeRecordRoundTrip() throws {
        var entry = WakeRecord(
            alarmID: UUID(),
            alarmLabel: "Morning",
            scheduledFor: Date(timeIntervalSince1970: 1_770_000_000),
            firedAt: Date(timeIntervalSince1970: 1_770_000_000)
        )
        entry.dismissedAt = Date(timeIntervalSince1970: 1_770_000_180)
        entry.snoozeCount = 2
        entry.missionType = .memory
        entry.missionSeconds = 42.5
        entry.missionFailures = 1
        entry.wakeUpCheckPassed = true
        entry.outcome = .dismissed

        let data = try makeEncoder().encode(entry)
        let restored = try makeDecoder().decode(WakeRecord.self, from: data)
        XCTAssertEqual(restored, entry)
    }

    func testWidgetSnapshotRoundTrip() throws {
        let snapshot = WidgetSnapshot(
            upcoming: [
                WidgetSnapshot.Entry(
                    id: UUID(),
                    label: "Wake",
                    fireDate: Date(timeIntervalSince1970: 1_770_000_000),
                    missionSymbol: "figure.walk",
                    missionName: "Walk",
                    colorHex: "FFD400",
                    repeatDescription: "Weekdays"
                )
            ],
            enabledCount: 3,
            currentStreak: 9
        )

        let data = try makeEncoder().encode(snapshot)
        let restored = try makeDecoder().decode(WidgetSnapshot.self, from: data)

        XCTAssertEqual(restored.enabledCount, 3)
        XCTAssertEqual(restored.currentStreak, 9)
        XCTAssertEqual(restored.upcoming.count, 1)
        XCTAssertEqual(restored.upcoming.first?.label, "Wake")
    }

    // MARK: Store behaviour

    @MainActor
    func testStoreSortsEnabledAlarmsByNextFireTime() {
        let store = AlarmStore(loadFromDisk: false)

        var late = Alarm(hour: 23, minute: 0)
        late.repeatMode = .weekly
        late.repeatDays = Weekday.everyDay

        var early = Alarm(hour: 5, minute: 0)
        early.repeatMode = .weekly
        early.repeatDays = Weekday.everyDay

        var off = Alarm(hour: 1, minute: 0)
        off.isEnabled = false

        store.add(late)
        store.add(early)
        store.add(off)

        let sorted = store.sortedAlarms
        XCTAssertEqual(sorted.count, 3)
        XCTAssertFalse(sorted.last!.isEnabled, "Disabled alarms belong at the bottom")

        let enabledNext = sorted.prefix(2).compactMap { $0.nextFireDate() }
        XCTAssertEqual(enabledNext, enabledNext.sorted())
    }

    @MainActor
    func testTogglingAnAlarmClearsAPendingSkip() {
        let store = AlarmStore(loadFromDisk: false)
        var alarm = Alarm(hour: 7, minute: 0)
        alarm.repeatMode = .weekly
        alarm.repeatDays = Weekday.everyDay
        alarm.skipNextOccurrence = true
        alarm.isEnabled = false
        store.add(alarm)

        store.setEnabled(true, for: alarm.id)
        XCTAssertFalse(store.alarm(with: alarm.id)?.skipNextOccurrence ?? true)
    }

    @MainActor
    func testFiringAOneShotAlarmSwitchesItOff() {
        let store = AlarmStore(loadFromDisk: false)
        var once = Alarm(hour: 7, minute: 0)
        once.repeatMode = .once
        store.add(once)

        store.markFired(id: once.id)
        XCTAssertFalse(store.alarm(with: once.id)?.isEnabled ?? true)
    }

    @MainActor
    func testFiringARepeatingAlarmLeavesItOn() {
        let store = AlarmStore(loadFromDisk: false)
        var repeating = Alarm(hour: 7, minute: 0)
        repeating.repeatMode = .weekly
        repeating.repeatDays = Weekday.everyDay
        repeating.skipNextOccurrence = true
        store.add(repeating)

        store.markFired(id: repeating.id)
        let updated = store.alarm(with: repeating.id)
        XCTAssertTrue(updated?.isEnabled ?? false)
        XCTAssertFalse(updated?.skipNextOccurrence ?? true, "Firing consumes the pending skip")
    }

    @MainActor
    func testScheduleInvalidationFiresOnEveryMutation() {
        let store = AlarmStore(loadFromDisk: false)
        var invalidations = 0
        store.onScheduleInvalidated = { invalidations += 1 }

        let alarm = Alarm(hour: 7, minute: 0)
        store.add(alarm)
        store.setEnabled(false, for: alarm.id)
        store.delete(id: alarm.id)

        XCTAssertEqual(invalidations, 3)
    }

    @MainActor
    func testNextAlarmIgnoresDisabledOnes() {
        let store = AlarmStore(loadFromDisk: false)

        var disabledEarly = Alarm(hour: 4, minute: 0)
        disabledEarly.repeatMode = .weekly
        disabledEarly.repeatDays = Weekday.everyDay
        disabledEarly.isEnabled = false

        var enabledLater = Alarm(hour: 9, minute: 0)
        enabledLater.repeatMode = .weekly
        enabledLater.repeatDays = Weekday.everyDay

        store.add(disabledEarly)
        store.add(enabledLater)

        XCTAssertEqual(store.nextAlarm?.alarm.id, enabledLater.id)
    }
}
