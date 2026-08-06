import Foundation

// MARK: - Decoding helper

/// Every stored model decodes field-by-field with a fallback so that adding a
/// setting in a later build never invalidates alarms already on the device.
extension KeyedDecodingContainer {
    func decodeOr<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        if let value = try? decodeIfPresent(T.self, forKey: key) { return value ?? fallback }
        return fallback
    }
}

// MARK: - Weekday

public enum Weekday: Int, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case sunday = 1, monday, tuesday, wednesday, thursday, friday, saturday

    public var id: Int { rawValue }

    /// Monday–Friday.
    public static let workdays: Set<Weekday> = [.monday, .tuesday, .wednesday, .thursday, .friday]
    /// Saturday and Sunday.
    public static let weekend: Set<Weekday> = [.saturday, .sunday]
    public static let everyDay: Set<Weekday> = Set(Weekday.allCases)

    /// Locale-aware short symbol, e.g. "Mon".
    public var shortName: String {
        let symbols = Calendar.current.shortWeekdaySymbols
        let index = rawValue - 1
        return symbols.indices.contains(index) ? symbols[index] : ""
    }

    /// Single/double letter used on the day-picker chips.
    public var minimalName: String {
        let symbols = Calendar.current.veryShortWeekdaySymbols
        let index = rawValue - 1
        return symbols.indices.contains(index) ? symbols[index] : ""
    }

    public var fullName: String {
        let symbols = Calendar.current.weekdaySymbols
        let index = rawValue - 1
        return symbols.indices.contains(index) ? symbols[index] : ""
    }

    /// All weekdays ordered starting at the user's configured first day of week.
    public static func orderedForLocale(_ calendar: Calendar = .current) -> [Weekday] {
        let first = calendar.firstWeekday
        return (0..<7).compactMap { Weekday(rawValue: ((first - 1 + $0) % 7) + 1) }
    }
}

// MARK: - Sound

public struct SoundSettings: Codable, Hashable, Sendable {
    /// When false the alarm wakes you with vibration alone.
    public var isEnabled: Bool = true
    /// Identifier into `SoundCatalog`, or a random/custom identifier.
    public var toneID: String = SoundCatalog.defaultToneID
    /// Playback level, 0...1, applied on top of the device volume.
    public var volume: Double = 1.0
    /// Ramp from quiet up to `volume` instead of starting at full blast.
    public var gradualIncrease: Bool = true
    /// How long the ramp takes.
    public var gradualRampSeconds: Double = 30
    public var vibrate: Bool = true
    /// Push the hardware output volume up when the alarm starts so a phone left
    /// on 10% still wakes you.
    public var overrideSystemVolume: Bool = true
    /// Give up after this many minutes of ringing. 0 means never stop.
    public var autoStopMinutes: Int = 15

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = c.decodeOr(.isEnabled, true)
        toneID = c.decodeOr(.toneID, SoundCatalog.defaultToneID)
        volume = c.decodeOr(.volume, 1.0)
        gradualIncrease = c.decodeOr(.gradualIncrease, true)
        gradualRampSeconds = c.decodeOr(.gradualRampSeconds, 30)
        vibrate = c.decodeOr(.vibrate, true)
        overrideSystemVolume = c.decodeOr(.overrideSystemVolume, true)
        autoStopMinutes = c.decodeOr(.autoStopMinutes, 15)
    }

    public var tone: AlarmTone { SoundCatalog.tone(id: toneID) }

    public static let rampOptions: [Double] = [10, 20, 30, 60, 120, 180, 300]
    public static let autoStopOptions: [Int] = [0, 1, 3, 5, 10, 15, 30, 60]
}

// MARK: - Snooze

public struct SnoozeSettings: Codable, Hashable, Sendable {
    public var isEnabled: Bool = true
    public var intervalMinutes: Int = 5
    /// "Infinite snooze until you wake up" — the app's headline snooze mode.
    public var isUnlimited: Bool = true
    /// Only consulted when `isUnlimited` is false.
    public var maxCount: Int = 3
    /// Force the mission to be completed before a snooze is granted.
    public var requireMissionToSnooze: Bool = false
    /// Halve the interval on each successive snooze so lie-ins get harder.
    public var shortenEachTime: Bool = false

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = c.decodeOr(.isEnabled, true)
        intervalMinutes = c.decodeOr(.intervalMinutes, 5)
        isUnlimited = c.decodeOr(.isUnlimited, true)
        maxCount = c.decodeOr(.maxCount, 3)
        requireMissionToSnooze = c.decodeOr(.requireMissionToSnooze, false)
        shortenEachTime = c.decodeOr(.shortenEachTime, false)
    }

    public static let intervalOptions: [Int] = [1, 3, 5, 10, 15, 20, 30]
    public static let countOptions: [Int] = [1, 2, 3, 5, 10]

    /// Interval for the Nth snooze (0-based), honouring `shortenEachTime`.
    public func interval(forSnoozeIndex index: Int) -> TimeInterval {
        guard shortenEachTime, index > 0 else { return TimeInterval(intervalMinutes * 60) }
        let minutes = max(1, Int((Double(intervalMinutes) / pow(2, Double(index))).rounded()))
        return TimeInterval(minutes * 60)
    }

    public var summary: String {
        guard isEnabled else { return "Off" }
        let base = "\(intervalMinutes) min"
        return isUnlimited ? "\(base), unlimited" : "\(base), \(maxCount)×"
    }
}

// MARK: - Wake-up check

/// After the alarm is dismissed the app can circle back a few minutes later and
/// demand confirmation that you are actually up. Miss the window and the alarm
/// fires again — this is the feature that stops "dismiss and roll over".
public struct WakeUpCheckSettings: Codable, Hashable, Sendable {
    public var isEnabled: Bool = false
    /// Minutes after dismissal before the check fires.
    public var delayMinutes: Int = 3
    /// How long you get to confirm before the alarm re-rings.
    public var confirmWindowSeconds: Int = 100
    /// Require the mission again to pass the check.
    public var requireMission: Bool = false
    /// Keep checking until confirmed rather than only once.
    public var repeatUntilConfirmed: Bool = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = c.decodeOr(.isEnabled, false)
        delayMinutes = c.decodeOr(.delayMinutes, 3)
        confirmWindowSeconds = c.decodeOr(.confirmWindowSeconds, 100)
        requireMission = c.decodeOr(.requireMission, false)
        repeatUntilConfirmed = c.decodeOr(.repeatUntilConfirmed, true)
    }

    public static let delayOptions: [Int] = [1, 2, 3, 5, 10, 15, 30]
    public static let windowOptions: [Int] = [30, 60, 100, 180, 300]

    public var summary: String {
        isEnabled ? "After \(delayMinutes) min" : "Off"
    }
}

// MARK: - Pre-alarm

/// A quiet heads-up a while before the real alarm, so you surface from deep
/// sleep gradually instead of being torn out of it.
public struct PreAlarmSettings: Codable, Hashable, Sendable {
    public var isEnabled: Bool = false
    public var minutesBefore: Int = 30
    /// When false the pre-alarm is a silent banner only.
    public var playSound: Bool = true
    public var toneID: String = "morning_dew"
    /// Fraction of the main alarm's volume.
    public var volumeScale: Double = 0.35

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = c.decodeOr(.isEnabled, false)
        minutesBefore = c.decodeOr(.minutesBefore, 30)
        playSound = c.decodeOr(.playSound, true)
        toneID = c.decodeOr(.toneID, "morning_dew")
        volumeScale = c.decodeOr(.volumeScale, 0.35)
    }

    public static let minuteOptions: [Int] = [5, 10, 15, 20, 30, 45, 60, 90]

    public var summary: String { isEnabled ? "\(minutesBefore) min before" : "Off" }
}

// MARK: - Voice briefing

/// Spoken announcement of the time, date and weather when the alarm fires.
public struct VoiceBriefingSettings: Codable, Hashable, Sendable {
    public var isEnabled: Bool = false
    public var announceTime: Bool = true
    public var announceDate: Bool = false
    public var announceWeather: Bool = true
    public var announceLabel: Bool = false
    /// Repeat the briefing every N seconds while the alarm rings. 0 = once.
    public var repeatIntervalSeconds: Int = 0
    /// 0.0...1.0, mapped onto AVSpeechUtterance rate.
    public var speechRate: Double = 0.5

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = c.decodeOr(.isEnabled, false)
        announceTime = c.decodeOr(.announceTime, true)
        announceDate = c.decodeOr(.announceDate, false)
        announceWeather = c.decodeOr(.announceWeather, true)
        announceLabel = c.decodeOr(.announceLabel, false)
        repeatIntervalSeconds = c.decodeOr(.repeatIntervalSeconds, 0)
        speechRate = c.decodeOr(.speechRate, 0.5)
    }

    public static let repeatOptions: [Int] = [0, 15, 30, 60, 120]

    public var summary: String { isEnabled ? "On" : "Off" }
}

// MARK: - Repeat mode

public enum RepeatMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Fires once at the next occurrence of the time, then switches off.
    case once
    /// Fires on the selected weekdays, every week.
    case weekly
    /// Fires only on an explicit list of calendar dates.
    case dates

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .once: return "Once"
        case .weekly: return "Weekly"
        case .dates: return "Specific dates"
        }
    }

    public var symbolName: String {
        switch self {
        case .once: return "1.circle.fill"
        case .weekly: return "repeat"
        case .dates: return "calendar"
        }
    }
}

// MARK: - Alarm

public struct Alarm: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var hour: Int = 7
    public var minute: Int = 0
    public var isEnabled: Bool = true
    /// Shown as the alarm's title in the list and on the ring screen.
    public var label: String = ""
    /// Longer note surfaced when the alarm goes off — "take your medication",
    /// "leave by 7:20", and so on.
    public var memo: String = ""
    public var repeatMode: RepeatMode = .once
    public var repeatDays: Set<Weekday> = []
    /// Explicit calendar days, normalised to start-of-day. Used when
    /// `repeatMode` is `.dates`.
    public var specificDates: [Date] = []
    public var sound = SoundSettings()
    public var snooze = SnoozeSettings()
    public var mission = MissionSettings()
    public var wakeUpCheck = WakeUpCheckSettings()
    public var preAlarm = PreAlarmSettings()
    public var voiceBriefing = VoiceBriefingSettings()
    /// Skip exactly one upcoming occurrence, then resume as normal.
    public var skipNextOccurrence: Bool = false
    /// Quick alarms are one-shot countdowns created from the nap timer.
    public var isQuickAlarm: Bool = false
    public var quickAlarmFireDate: Date?
    public var createdAt: Date = Date()
    public var lastFiredAt: Date?
    /// Index into `AlarmPalette.tags`.
    public var colorTag: Int = 0

    public init() {}

    public init(hour: Int, minute: Int) {
        self.hour = hour
        self.minute = minute
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decodeOr(.id, UUID())
        hour = min(23, max(0, c.decodeOr(.hour, 7)))
        minute = min(59, max(0, c.decodeOr(.minute, 0)))
        isEnabled = c.decodeOr(.isEnabled, true)
        label = c.decodeOr(.label, "")
        memo = c.decodeOr(.memo, "")
        repeatDays = c.decodeOr(.repeatDays, Set<Weekday>())
        specificDates = c.decodeOr(.specificDates, [Date]())
        // Older records predate `repeatMode`; infer it from what they stored.
        repeatMode = c.decodeOr(.repeatMode, specificDates.isEmpty ? (repeatDays.isEmpty ? RepeatMode.once : .weekly) : .dates)
        sound = c.decodeOr(.sound, SoundSettings())
        snooze = c.decodeOr(.snooze, SnoozeSettings())
        mission = c.decodeOr(.mission, MissionSettings())
        wakeUpCheck = c.decodeOr(.wakeUpCheck, WakeUpCheckSettings())
        preAlarm = c.decodeOr(.preAlarm, PreAlarmSettings())
        voiceBriefing = c.decodeOr(.voiceBriefing, VoiceBriefingSettings())
        skipNextOccurrence = c.decodeOr(.skipNextOccurrence, false)
        isQuickAlarm = c.decodeOr(.isQuickAlarm, false)
        quickAlarmFireDate = try? c.decodeIfPresent(Date.self, forKey: .quickAlarmFireDate)
        createdAt = c.decodeOr(.createdAt, Date())
        lastFiredAt = try? c.decodeIfPresent(Date.self, forKey: .lastFiredAt)
        colorTag = c.decodeOr(.colorTag, 0)
    }

    // MARK: Display

    public var isRepeating: Bool {
        switch repeatMode {
        case .once: return false
        case .weekly: return !repeatDays.isEmpty
        case .dates: return specificDates.count > 1
        }
    }

    public var displayLabel: String {
        if !label.isEmpty { return label }
        return isQuickAlarm ? "Quick Alarm" : "Alarm"
    }

    /// "Every day" / "Weekdays" / "Mon Wed Fri" / "3 dates" / "Never".
    public var repeatDescription: String {
        if isQuickAlarm { return "Once" }

        switch repeatMode {
        case .once:
            return "Never"

        case .weekly:
            if repeatDays.isEmpty { return "Never" }
            if repeatDays == Weekday.everyDay { return "Every day" }
            if repeatDays == Weekday.workdays { return "Weekdays" }
            if repeatDays == Weekday.weekend { return "Weekends" }
            return Weekday.orderedForLocale()
                .filter { repeatDays.contains($0) }
                .map(\.shortName)
                .joined(separator: " ")

        case .dates:
            let upcoming = specificDates.filter { $0 >= Calendar.current.startOfDay(for: Date()) }
            if upcoming.isEmpty { return "No dates left" }
            if upcoming.count == 1 {
                let formatter = DateFormatter()
                formatter.dateFormat = "MMM d"
                return formatter.string(from: upcoming[0])
            }
            return "\(upcoming.count) dates"
        }
    }

    public func timeString(use24Hour: Bool) -> String {
        if use24Hour {
            return String(format: "%02d:%02d", hour, minute)
        }
        let displayHour = hour % 12 == 0 ? 12 : hour % 12
        return String(format: "%d:%02d", displayHour, minute)
    }

    public var meridiemString: String { hour < 12 ? "AM" : "PM" }

    // MARK: Scheduling

    /// The next moment this alarm should ring, or nil if it never will again.
    public func nextFireDate(after reference: Date = Date(), calendar: Calendar = .current) -> Date? {
        if isQuickAlarm {
            guard let fire = quickAlarmFireDate, fire > reference else { return nil }
            return fire
        }

        let occurrences = upcomingFireDates(after: reference, limit: 1, calendar: calendar)
        return occurrences.first
    }

    /// Upcoming fire dates in ascending order. Used both for the UI and to fan
    /// out the notification chain that backs alarms on pre-AlarmKit systems.
    public func upcomingFireDates(
        after reference: Date = Date(),
        limit: Int,
        calendar: Calendar = .current
    ) -> [Date] {
        guard limit > 0 else { return [] }

        if isQuickAlarm {
            guard let fire = quickAlarmFireDate, fire > reference else { return [] }
            return [fire]
        }

        var skipsRemaining = skipNextOccurrence ? 1 : 0

        // Explicit calendar dates: just stamp the time onto each stored day.
        if repeatMode == .dates {
            var results: [Date] = []
            for day in specificDates.sorted() {
                guard
                    let candidate = calendar.date(
                        bySettingHour: hour, minute: minute, second: 0, of: day, matchingPolicy: .nextTime
                    ),
                    candidate > reference
                else { continue }

                if skipsRemaining > 0 { skipsRemaining -= 1; continue }
                results.append(candidate)
                if results.count >= limit { break }
            }
            return results
        }

        var results: [Date] = []

        // Walk forward day by day. 371 days covers a full year plus a week,
        // which is far more than any caller needs.
        var cursor = calendar.startOfDay(for: reference)
        let onlyOnce = repeatMode == .once || repeatDays.isEmpty

        for _ in 0..<371 {
            guard
                let candidate = calendar.date(
                    bySettingHour: hour, minute: minute, second: 0, of: cursor, matchingPolicy: .nextTime
                )
            else {
                cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? cursor
                continue
            }

            if candidate > reference {
                let weekdayValue = calendar.component(.weekday, from: candidate)
                let matches = onlyOnce
                    ? true
                    : Weekday(rawValue: weekdayValue).map { repeatDays.contains($0) } ?? false

                if matches {
                    if skipsRemaining > 0 {
                        skipsRemaining -= 1
                    } else {
                        results.append(candidate)
                        // A non-repeating alarm only ever fires once.
                        if onlyOnce { break }
                        if results.count >= limit { break }
                    }
                }
            }

            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }

        return results
    }

    /// The most recent time this alarm should have gone off, looking back no
    /// further than `window`. Used on launch to detect an alarm that came due
    /// while the app was not running.
    public func mostRecentFireDate(
        before reference: Date = Date(),
        within window: TimeInterval,
        calendar: Calendar = .current
    ) -> Date? {
        let start = reference.addingTimeInterval(-window)
        return upcomingFireDates(after: start, limit: 40, calendar: calendar)
            .last { $0 <= reference }
    }

    /// When the pre-alarm heads-up should fire, if enabled.
    public func nextPreAlarmDate(after reference: Date = Date(), calendar: Calendar = .current) -> Date? {
        guard preAlarm.isEnabled, isEnabled else { return nil }
        // Look a couple of occurrences ahead: the main alarm may be soon enough
        // that its own pre-alarm has already passed.
        for fire in upcomingFireDates(after: reference, limit: 3, calendar: calendar) {
            let pre = fire.addingTimeInterval(TimeInterval(-preAlarm.minutesBefore * 60))
            if pre > reference { return pre }
        }
        return nil
    }

    /// Human-readable countdown used on the list screen: "in 7 hr 12 min".
    public func timeUntilDescription(from reference: Date = Date()) -> String? {
        guard isEnabled, let fire = nextFireDate(after: reference) else { return nil }
        let seconds = Int(fire.timeIntervalSince(reference))
        guard seconds > 0 else { return nil }

        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60

        if days > 0 {
            return hours > 0 ? "in \(days) d \(hours) hr" : "in \(days) d"
        }
        if hours > 0 {
            return minutes > 0 ? "in \(hours) hr \(minutes) min" : "in \(hours) hr"
        }
        if minutes > 0 { return "in \(minutes) min" }
        return "in less than a minute"
    }

    // MARK: Presets

    public static func preset(hour: Int, minute: Int, days: Set<Weekday>, label: String) -> Alarm {
        var alarm = Alarm(hour: hour, minute: minute)
        alarm.repeatMode = days.isEmpty ? .once : .weekly
        alarm.repeatDays = days
        alarm.label = label
        return alarm
    }

    /// One-shot countdown alarm, e.g. a 20 minute nap.
    public static func quick(minutesFromNow: Int, label: String = "Quick Alarm") -> Alarm {
        let fire = Date().addingTimeInterval(TimeInterval(minutesFromNow * 60))
        let comps = Calendar.current.dateComponents([.hour, .minute], from: fire)
        var alarm = Alarm(hour: comps.hour ?? 0, minute: comps.minute ?? 0)
        alarm.isQuickAlarm = true
        alarm.quickAlarmFireDate = fire
        alarm.label = label
        alarm.mission = MissionSettings()
        alarm.snooze.isEnabled = false
        return alarm
    }
}

// MARK: - Colour tags

public enum AlarmPalette {
    /// Hex values for the colour dot users can pin to an alarm.
    public static let tags: [String] = [
        "7C5CFF", // violet — default
        "FF5C7C", // rose
        "FF9F0A", // amber
        "32D74B", // green
        "0A84FF", // blue
        "FF453A", // red
        "64D2FF", // cyan
        "BF5AF2", // purple
    ]

    public static func hex(for index: Int) -> String {
        guard tags.indices.contains(index) else { return tags[0] }
        return tags[index]
    }
}
