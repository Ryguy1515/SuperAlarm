import XCTest
@testable import SuperAlarm

/// Scheduling maths is the part of this app that absolutely must be right —
/// an off-by-one-day bug here is a missed flight. Every test pins a fixed
/// calendar and a fixed "now" so results never depend on when CI runs.
final class AlarmSchedulingTests: XCTestCase {

    private var calendar: Calendar!

    override func setUp() {
        super.setUp()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        cal.firstWeekday = 1
        calendar = cal
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = 0
        return calendar.date(from: components)!
    }

    /// Guards the fixtures below. Every weekday assertion in this file assumes
    /// 6 August 2026 is a Thursday; if that is wrong, the rest is meaningless.
    func testCalendarFixtureIsCorrect() {
        XCTAssertEqual(calendar.component(.weekday, from: date(2026, 8, 6, 12, 0)), Weekday.thursday.rawValue)
        XCTAssertEqual(calendar.component(.weekday, from: date(2026, 8, 7, 12, 0)), Weekday.friday.rawValue)
        XCTAssertEqual(calendar.component(.weekday, from: date(2026, 8, 8, 12, 0)), Weekday.saturday.rawValue)
        XCTAssertEqual(calendar.component(.weekday, from: date(2026, 8, 3, 12, 0)), Weekday.monday.rawValue)
    }

    // MARK: One-shot

    func testOneShotFiresLaterToday() {
        var alarm = Alarm(hour: 7, minute: 0)
        alarm.repeatMode = .once

        // Thursday 6 August 2026, 06:00.
        let now = date(2026, 8, 6, 6, 0)
        let next = alarm.nextFireDate(after: now, calendar: calendar)

        XCTAssertEqual(next, date(2026, 8, 6, 7, 0))
    }

    func testOneShotRollsToTomorrowOncePassed() {
        var alarm = Alarm(hour: 7, minute: 0)
        alarm.repeatMode = .once

        let now = date(2026, 8, 6, 8, 0)
        let next = alarm.nextFireDate(after: now, calendar: calendar)

        XCTAssertEqual(next, date(2026, 8, 7, 7, 0))
    }

    func testOneShotProducesExactlyOneOccurrence() {
        var alarm = Alarm(hour: 7, minute: 0)
        alarm.repeatMode = .once

        let now = date(2026, 8, 6, 8, 0)
        let dates = alarm.upcomingFireDates(after: now, limit: 5, calendar: calendar)

        XCTAssertEqual(dates.count, 1, "A non-repeating alarm must never schedule more than once")
    }

    func testAlarmExactlyAtNowDoesNotCountAsUpcoming() {
        var alarm = Alarm(hour: 7, minute: 0)
        alarm.repeatMode = .once

        // Firing must be strictly in the future, otherwise an alarm that just
        // rang would immediately re-arm for the same instant.
        let now = date(2026, 8, 6, 7, 0)
        XCTAssertEqual(alarm.nextFireDate(after: now, calendar: calendar), date(2026, 8, 7, 7, 0))
    }

    // MARK: Weekly

    func testWeeklyPicksNextSelectedDay() {
        var alarm = Alarm(hour: 7, minute: 0)
        alarm.repeatMode = .weekly
        alarm.repeatDays = [.monday, .wednesday, .friday]

        // Thursday 6 August 2026 at 08:00. Thursday is not selected, so the
        // next hit is Friday.
        let now = date(2026, 8, 6, 8, 0)
        let next = alarm.nextFireDate(after: now, calendar: calendar)

        XCTAssertEqual(next, date(2026, 8, 7, 7, 0))
    }

    func testWeeklyIncludesTodayWhenTimeHasNotPassed() {
        var alarm = Alarm(hour: 7, minute: 0)
        alarm.repeatMode = .weekly
        // Thursday is selected, and it is only 05:00, so today still counts.
        alarm.repeatDays = [.monday, .thursday, .friday]

        let now = date(2026, 8, 6, 5, 0)
        XCTAssertEqual(alarm.nextFireDate(after: now, calendar: calendar), date(2026, 8, 6, 7, 0))
    }

    func testWeeklySkipsTodayOnceTheTimeHasPassed() {
        var alarm = Alarm(hour: 7, minute: 0)
        alarm.repeatMode = .weekly
        alarm.repeatDays = [.monday, .thursday, .friday]

        // Same Thursday, but 08:00 — today's 07:00 slot is gone.
        let now = date(2026, 8, 6, 8, 0)
        XCTAssertEqual(alarm.nextFireDate(after: now, calendar: calendar), date(2026, 8, 7, 7, 0))
    }

    func testWeeklyOccurrencesAreAscendingAndOnSelectedDaysOnly() {
        var alarm = Alarm(hour: 6, minute: 30)
        alarm.repeatMode = .weekly
        alarm.repeatDays = [.saturday, .sunday]

        let now = date(2026, 8, 6, 12, 0)
        let dates = alarm.upcomingFireDates(after: now, limit: 6, calendar: calendar)

        XCTAssertEqual(dates.count, 6)
        XCTAssertEqual(dates, dates.sorted(), "Occurrences must come back in ascending order")

        for fire in dates {
            let weekday = calendar.component(.weekday, from: fire)
            XCTAssertTrue(
                weekday == Weekday.saturday.rawValue || weekday == Weekday.sunday.rawValue,
                "Fired on weekday \(weekday), which was not selected"
            )
            XCTAssertEqual(calendar.component(.hour, from: fire), 6)
            XCTAssertEqual(calendar.component(.minute, from: fire), 30)
        }
    }

    func testEveryDayRepeatsDaily() {
        var alarm = Alarm(hour: 9, minute: 15)
        alarm.repeatMode = .weekly
        alarm.repeatDays = Weekday.everyDay

        let now = date(2026, 8, 6, 10, 0)
        let dates = alarm.upcomingFireDates(after: now, limit: 3, calendar: calendar)

        XCTAssertEqual(dates, [
            date(2026, 8, 7, 9, 15),
            date(2026, 8, 8, 9, 15),
            date(2026, 8, 9, 9, 15),
        ])
    }

    // MARK: Skip

    func testSkipNextOccurrenceSkipsExactlyOne() {
        var alarm = Alarm(hour: 7, minute: 0)
        alarm.repeatMode = .weekly
        alarm.repeatDays = Weekday.everyDay
        alarm.skipNextOccurrence = true

        let now = date(2026, 8, 6, 8, 0)
        let dates = alarm.upcomingFireDates(after: now, limit: 2, calendar: calendar)

        // 7 August is skipped; the next two are the 8th and 9th.
        XCTAssertEqual(dates, [date(2026, 8, 8, 7, 0), date(2026, 8, 9, 7, 0)])
    }

    // MARK: Specific dates

    func testSpecificDatesFireOnlyOnThoseDays() {
        var alarm = Alarm(hour: 5, minute: 45)
        alarm.repeatMode = .dates
        alarm.specificDates = [
            date(2026, 8, 10, 0, 0),
            date(2026, 8, 20, 0, 0),
            date(2026, 9, 1, 0, 0),
        ]

        let now = date(2026, 8, 6, 12, 0)
        let dates = alarm.upcomingFireDates(after: now, limit: 10, calendar: calendar)

        XCTAssertEqual(dates, [
            date(2026, 8, 10, 5, 45),
            date(2026, 8, 20, 5, 45),
            date(2026, 9, 1, 5, 45),
        ])
    }

    func testSpecificDatesInThePastAreIgnored() {
        var alarm = Alarm(hour: 5, minute: 45)
        alarm.repeatMode = .dates
        alarm.specificDates = [date(2026, 8, 1, 0, 0), date(2026, 8, 20, 0, 0)]

        let now = date(2026, 8, 6, 12, 0)
        XCTAssertEqual(alarm.nextFireDate(after: now, calendar: calendar), date(2026, 8, 20, 5, 45))
    }

    func testSpecificDatesWithNothingLeftReturnsNil() {
        var alarm = Alarm(hour: 5, minute: 45)
        alarm.repeatMode = .dates
        alarm.specificDates = [date(2026, 8, 1, 0, 0)]

        XCTAssertNil(alarm.nextFireDate(after: date(2026, 8, 6, 12, 0), calendar: calendar))
    }

    // MARK: Quick alarms

    func testQuickAlarmFiresAtItsFixedInstant() {
        var alarm = Alarm(hour: 0, minute: 0)
        alarm.isQuickAlarm = true
        let fire = date(2026, 8, 6, 13, 20)
        alarm.quickAlarmFireDate = fire

        XCTAssertEqual(alarm.nextFireDate(after: date(2026, 8, 6, 13, 0), calendar: calendar), fire)
        XCTAssertNil(alarm.nextFireDate(after: date(2026, 8, 6, 13, 30), calendar: calendar))
    }

    func testQuickAlarmHelperSetsFutureFireDate() {
        let alarm = Alarm.quick(minutesFromNow: 20)
        XCTAssertTrue(alarm.isQuickAlarm)
        XCTAssertNotNil(alarm.quickAlarmFireDate)
        XCTAssertGreaterThan(alarm.quickAlarmFireDate!.timeIntervalSinceNow, 19 * 60)
        XCTAssertFalse(alarm.snooze.isEnabled, "A nap timer should not snooze by default")
    }

    // MARK: Catch-up

    func testMostRecentFireDateFindsAnAlarmThatJustPassed() {
        var alarm = Alarm(hour: 7, minute: 0)
        alarm.repeatMode = .weekly
        alarm.repeatDays = Weekday.everyDay

        // Ten minutes after it should have gone off.
        let now = date(2026, 8, 6, 7, 10)
        let recent = alarm.mostRecentFireDate(before: now, within: 30 * 60, calendar: calendar)

        XCTAssertEqual(recent, date(2026, 8, 6, 7, 0))
    }

    func testMostRecentFireDateIgnoresAnythingOutsideTheWindow() {
        var alarm = Alarm(hour: 7, minute: 0)
        alarm.repeatMode = .weekly
        alarm.repeatDays = Weekday.everyDay

        // Two hours late, with a 30 minute window.
        let now = date(2026, 8, 6, 9, 0)
        XCTAssertNil(alarm.mostRecentFireDate(before: now, within: 30 * 60, calendar: calendar))
    }

    // MARK: Pre-alarm

    func testPreAlarmLandsBeforeTheAlarm() {
        var alarm = Alarm(hour: 7, minute: 0)
        alarm.repeatMode = .weekly
        alarm.repeatDays = Weekday.everyDay
        alarm.isEnabled = true
        alarm.preAlarm.isEnabled = true
        alarm.preAlarm.minutesBefore = 30

        let now = date(2026, 8, 6, 5, 0)
        XCTAssertEqual(alarm.nextPreAlarmDate(after: now, calendar: calendar), date(2026, 8, 6, 6, 30))
    }

    func testPreAlarmSkipsToTomorrowWhenItsWindowHasPassed() {
        var alarm = Alarm(hour: 7, minute: 0)
        alarm.repeatMode = .weekly
        alarm.repeatDays = Weekday.everyDay
        alarm.isEnabled = true
        alarm.preAlarm.isEnabled = true
        alarm.preAlarm.minutesBefore = 30

        // 06:45 — today's pre-alarm at 06:30 has already gone.
        let now = date(2026, 8, 6, 6, 45)
        XCTAssertEqual(alarm.nextPreAlarmDate(after: now, calendar: calendar), date(2026, 8, 7, 6, 30))
    }

    func testDisabledAlarmHasNoPreAlarm() {
        var alarm = Alarm(hour: 7, minute: 0)
        alarm.isEnabled = false
        alarm.preAlarm.isEnabled = true
        XCTAssertNil(alarm.nextPreAlarmDate(after: date(2026, 8, 6, 5, 0), calendar: calendar))
    }

    // MARK: Snooze intervals

    func testSnoozeIntervalIsConstantByDefault() {
        var snooze = SnoozeSettings()
        snooze.intervalMinutes = 10
        snooze.shortenEachTime = false

        XCTAssertEqual(snooze.interval(forSnoozeIndex: 0), 600)
        XCTAssertEqual(snooze.interval(forSnoozeIndex: 3), 600)
    }

    func testSnoozeIntervalHalvesWhenShortening() {
        var snooze = SnoozeSettings()
        snooze.intervalMinutes = 8
        snooze.shortenEachTime = true

        XCTAssertEqual(snooze.interval(forSnoozeIndex: 0), 8 * 60)
        XCTAssertEqual(snooze.interval(forSnoozeIndex: 1), 4 * 60)
        XCTAssertEqual(snooze.interval(forSnoozeIndex: 2), 2 * 60)
        // Never drops below one minute.
        XCTAssertEqual(snooze.interval(forSnoozeIndex: 9), 60)
    }

    // MARK: Display

    func testTimeStringFormatsBothClocks() {
        let alarm = Alarm(hour: 7, minute: 5)
        XCTAssertEqual(alarm.timeString(use24Hour: true), "07:05")
        XCTAssertEqual(alarm.timeString(use24Hour: false), "7:05")
        XCTAssertEqual(alarm.meridiemString, "AM")

        let evening = Alarm(hour: 19, minute: 30)
        XCTAssertEqual(evening.timeString(use24Hour: true), "19:30")
        XCTAssertEqual(evening.timeString(use24Hour: false), "7:30")
        XCTAssertEqual(evening.meridiemString, "PM")

        let midnight = Alarm(hour: 0, minute: 0)
        XCTAssertEqual(midnight.timeString(use24Hour: false), "12:00", "Midnight must read as 12, not 0")

        let noon = Alarm(hour: 12, minute: 0)
        XCTAssertEqual(noon.timeString(use24Hour: false), "12:00")
        XCTAssertEqual(noon.meridiemString, "PM")
    }
}
