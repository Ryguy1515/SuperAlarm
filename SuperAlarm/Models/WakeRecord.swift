import Foundation

// MARK: - Wake record

/// One entry in the wake-up history: what was scheduled, what actually
/// happened, and how hard you fought it.
public struct WakeRecord: Identifiable, Codable, Hashable, Sendable {
    public enum Outcome: String, Codable, CaseIterable, Sendable {
        /// Mission completed and the alarm was turned off properly.
        case dismissed
        /// Rang for the full auto-stop window without being dismissed.
        case rangOut
        /// Never acknowledged at all — detected on next launch.
        case missed
        /// User had marked the occurrence as skipped.
        case skipped

        public var displayName: String {
            switch self {
            case .dismissed: return "Woke up"
            case .rangOut: return "Rang out"
            case .missed: return "Missed"
            case .skipped: return "Skipped"
            }
        }

        public var symbolName: String {
            switch self {
            case .dismissed: return "checkmark.circle.fill"
            case .rangOut: return "bell.slash.fill"
            case .missed: return "exclamationmark.triangle.fill"
            case .skipped: return "forward.end.fill"
            }
        }

        /// Counts toward the streak.
        public var isSuccess: Bool { self == .dismissed }
    }

    public var id: UUID = UUID()
    public var alarmID: UUID?
    public var alarmLabel: String = "Alarm"
    /// The time the alarm was set for.
    public var scheduledFor: Date
    /// When it actually started ringing.
    public var firedAt: Date
    /// When it was finally turned off.
    public var dismissedAt: Date?
    public var snoozeCount: Int = 0
    public var missionType: MissionType = .none
    /// Wall-clock seconds spent inside the mission.
    public var missionSeconds: Double = 0
    /// Wrong answers / failed attempts before completing.
    public var missionFailures: Int = 0
    /// Nil when no wake-up check was configured.
    public var wakeUpCheckPassed: Bool?
    public var outcome: Outcome = .dismissed

    public init(
        alarmID: UUID?,
        alarmLabel: String,
        scheduledFor: Date,
        firedAt: Date
    ) {
        self.alarmID = alarmID
        self.alarmLabel = alarmLabel
        self.scheduledFor = scheduledFor
        self.firedAt = firedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decodeOr(.id, UUID())
        alarmID = try? c.decodeIfPresent(UUID.self, forKey: .alarmID)
        alarmLabel = c.decodeOr(.alarmLabel, "Alarm")
        scheduledFor = c.decodeOr(.scheduledFor, Date())
        firedAt = c.decodeOr(.firedAt, scheduledFor)
        dismissedAt = try? c.decodeIfPresent(Date.self, forKey: .dismissedAt)
        snoozeCount = c.decodeOr(.snoozeCount, 0)
        missionType = c.decodeOr(.missionType, MissionType.none)
        missionSeconds = c.decodeOr(.missionSeconds, 0)
        missionFailures = c.decodeOr(.missionFailures, 0)
        wakeUpCheckPassed = try? c.decodeIfPresent(Bool.self, forKey: .wakeUpCheckPassed)
        outcome = c.decodeOr(.outcome, Outcome.dismissed)
    }

    /// How long from first ring to final dismissal.
    public var secondsToDismiss: Double? {
        guard let dismissedAt else { return nil }
        return dismissedAt.timeIntervalSince(firedAt)
    }

    /// Up within five minutes of the scheduled time.
    public var wasPunctual: Bool {
        guard let dismissedAt else { return false }
        return dismissedAt.timeIntervalSince(scheduledFor) <= 300
    }

    public var day: Date { Calendar.current.startOfDay(for: scheduledFor) }

    /// "4 min 12 s" style formatting for the history row.
    public var durationLabel: String {
        guard let seconds = secondsToDismiss, seconds > 0 else { return "—" }
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        let minutes = total / 60
        let rest = total % 60
        return rest == 0 ? "\(minutes)m" : "\(minutes)m \(rest)s"
    }
}

// MARK: - Aggregated statistics

/// Everything the stats screen shows, derived from the raw history in one pass.
public struct WakeStatistics: Sendable {
    public var currentStreak: Int = 0
    public var longestStreak: Int = 0
    public var totalWakeUps: Int = 0
    public var successCount: Int = 0
    public var totalSnoozes: Int = 0
    /// Mean seconds from ring to dismissal across successful wake-ups.
    public var averageDismissSeconds: Double = 0
    /// Mean minutes late relative to the scheduled time.
    public var averageLatenessMinutes: Double = 0
    public var punctualCount: Int = 0
    /// Successful wake-ups per weekday, indexed by `Weekday.rawValue`.
    public var byWeekday: [Int: Int] = [:]
    /// Most-used mission across the history.
    public var favouriteMission: MissionType?
    /// Last 30 days, oldest first, for the bar chart.
    public var recentDays: [DaySummary] = []

    public struct DaySummary: Identifiable, Sendable {
        public var id: Date { date }
        public var date: Date
        public var succeeded: Bool
        public var hasRecord: Bool
        public var snoozes: Int
        public var dismissSeconds: Double?
    }

    public var successRate: Double {
        totalWakeUps == 0 ? 0 : Double(successCount) / Double(totalWakeUps)
    }

    public init() {}

    /// Builds the full statistics set. `now` is injected so this is testable.
    public init(records: [WakeRecord], now: Date = Date(), calendar: Calendar = .current) {
        let sorted = records.sorted { $0.scheduledFor < $1.scheduledFor }
        totalWakeUps = sorted.count
        successCount = sorted.filter { $0.outcome.isSuccess }.count
        totalSnoozes = sorted.reduce(0) { $0 + $1.snoozeCount }
        punctualCount = sorted.filter(\.wasPunctual).count

        let dismissTimes = sorted.compactMap { $0.outcome.isSuccess ? $0.secondsToDismiss : nil }
        averageDismissSeconds = dismissTimes.isEmpty ? 0 : dismissTimes.reduce(0, +) / Double(dismissTimes.count)

        let lateness = sorted
            .filter { $0.outcome.isSuccess }
            .compactMap { $0.dismissedAt?.timeIntervalSince($0.scheduledFor) }
        averageLatenessMinutes = lateness.isEmpty ? 0 : (lateness.reduce(0, +) / Double(lateness.count)) / 60

        for record in sorted where record.outcome.isSuccess {
            let weekday = calendar.component(.weekday, from: record.scheduledFor)
            byWeekday[weekday, default: 0] += 1
        }

        var missionCounts: [MissionType: Int] = [:]
        for record in sorted where record.missionType != .none {
            missionCounts[record.missionType, default: 0] += 1
        }
        favouriteMission = missionCounts.max { $0.value < $1.value }?.key

        // Group successes by calendar day for streak maths.
        var successDays = Set<Date>()
        var dayRecords: [Date: [WakeRecord]] = [:]
        for record in sorted {
            let day = calendar.startOfDay(for: record.scheduledFor)
            dayRecords[day, default: []].append(record)
            if record.outcome.isSuccess { successDays.insert(day) }
        }

        // Longest run of consecutive successful days anywhere in the history.
        let orderedDays = successDays.sorted()
        var run = 0
        var previous: Date?
        for day in orderedDays {
            if let previous, let next = calendar.date(byAdding: .day, value: 1, to: previous), next == day {
                run += 1
            } else {
                run = 1
            }
            longestStreak = max(longestStreak, run)
            previous = day
        }

        // Current streak walks backwards from today. Today not yet being done
        // does not break the streak — yesterday's absence does.
        let today = calendar.startOfDay(for: now)
        var cursor = successDays.contains(today)
            ? today
            : (calendar.date(byAdding: .day, value: -1, to: today) ?? today)
        while successDays.contains(cursor) {
            currentStreak += 1
            guard let previousDay = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previousDay
        }

        // Trailing 30-day window for the chart.
        var days: [DaySummary] = []
        for offset in stride(from: 29, through: 0, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            let entries = dayRecords[day] ?? []
            let best = entries.first { $0.outcome.isSuccess } ?? entries.first
            days.append(
                DaySummary(
                    date: day,
                    succeeded: successDays.contains(day),
                    hasRecord: !entries.isEmpty,
                    snoozes: entries.reduce(0) { $0 + $1.snoozeCount },
                    dismissSeconds: best?.secondsToDismiss
                )
            )
        }
        recentDays = days
    }
}
