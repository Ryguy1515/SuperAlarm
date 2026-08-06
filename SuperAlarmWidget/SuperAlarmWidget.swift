import WidgetKit
import SwiftUI

// MARK: - Palette
//
// Kept local to the widget target so the extension does not have to pull in
// the whole app's design system.

private enum WColor {
    static let accent = Color(red: 1.0, green: 0.831, blue: 0.0)      // #FFD400
    static let ink = Color(red: 0.04, green: 0.04, blue: 0.04)
    static let surface = Color(red: 0.08, green: 0.08, blue: 0.08)
}

private extension Color {
    init(widgetHex hex: String) {
        var cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("#") { cleaned.removeFirst() }
        let value = UInt32(cleaned, radix: 16) ?? 0xFFD400
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            opacity: 1
        )
    }
}

private func rounded(_ size: CGFloat, _ weight: Font.Weight) -> Font {
    .system(size: size, weight: weight, design: .rounded)
}

// MARK: - Timeline

struct AlarmEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
    /// False when the App Group container is unavailable, which is the case
    /// under free-team signing.
    let hasSharedData: Bool

    static let placeholder = AlarmEntry(
        date: Date(),
        snapshot: WidgetSnapshot(
            upcoming: [
                WidgetSnapshot.Entry(
                    id: UUID(),
                    label: "Wake up",
                    fireDate: Date().addingTimeInterval(8 * 3600),
                    missionSymbol: "figure.walk",
                    missionName: "Walk",
                    colorHex: "7C5CFF",
                    repeatDescription: "Weekdays"
                )
            ],
            enabledCount: 2,
            currentStreak: 12
        ),
        hasSharedData: true
    )
}

struct AlarmProvider: TimelineProvider {
    func placeholder(in context: Context) -> AlarmEntry {
        .placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (AlarmEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AlarmEntry>) -> Void) {
        let entry = currentEntry()

        // Refresh when the next alarm fires, or hourly if nothing is scheduled.
        let next = entry.snapshot.upcoming.first?.fireDate
        let refresh = next.map { min($0.addingTimeInterval(60), Date().addingTimeInterval(3600)) }
            ?? Date().addingTimeInterval(3600)

        completion(Timeline(entries: [entry], policy: .after(refresh)))
    }

    private func currentEntry() -> AlarmEntry {
        guard StorageLocation.hasSharedContainer else {
            return AlarmEntry(date: Date(), snapshot: .empty, hasSharedData: false)
        }
        let snapshot = WidgetSnapshot.load() ?? .empty
        // Drop anything that has already fired since the app last wrote.
        let upcoming = snapshot.upcoming.filter { $0.fireDate > Date() }
        return AlarmEntry(
            date: Date(),
            snapshot: WidgetSnapshot(
                upcoming: upcoming,
                enabledCount: snapshot.enabledCount,
                currentStreak: snapshot.currentStreak
            ),
            hasSharedData: true
        )
    }
}

// MARK: - Shared pieces

private struct NoDataView: View {
    var compact = false

    var body: some View {
        VStack(spacing: compact ? 2 : 6) {
            Image(systemName: "alarm.fill")
                .font(rounded(compact ? 15 : 22, .bold))
                .foregroundStyle(WColor.accent)
            Text("Open SuperAlarm")
                .font(rounded(compact ? 10 : 13, .semibold))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}

private func relativeText(_ date: Date) -> String {
    let seconds = Int(date.timeIntervalSinceNow)
    guard seconds > 0 else { return "now" }
    let days = seconds / 86_400
    let hours = (seconds % 86_400) / 3_600
    let minutes = (seconds % 3_600) / 60
    if days > 0 { return "in \(days)d \(hours)h" }
    if hours > 0 { return "in \(hours)h \(minutes)m" }
    return "in \(max(1, minutes))m"
}

private func timeText(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .none
    formatter.timeStyle = .short
    return formatter.string(from: date)
}

// MARK: - Next alarm widget

struct NextAlarmWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: AlarmEntry

    var body: some View {
        Group {
            switch family {
            case .systemSmall: small
            case .systemMedium: medium
            case .accessoryCircular: circular
            case .accessoryRectangular: rectangular
            case .accessoryInline: inline
            default: small
            }
        }
        .containerBackground(for: .widget) {
            if family == .systemSmall || family == .systemMedium {
                WColor.ink
            } else {
                Color.clear
            }
        }
    }

    private var first: WidgetSnapshot.Entry? { entry.snapshot.upcoming.first }

    // MARK: Small

    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: "alarm.fill")
                    .font(rounded(11, .bold))
                    .foregroundStyle(WColor.accent)
                Text("NEXT")
                    .font(rounded(10, .heavy))
                    .foregroundStyle(.white.opacity(0.5))
                Spacer()
                if entry.snapshot.currentStreak > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "flame.fill").font(rounded(9, .bold))
                        Text("\(entry.snapshot.currentStreak)").font(rounded(10, .heavy))
                    }
                    .foregroundStyle(WColor.accent)
                }
            }

            Spacer(minLength: 4)

            if let first {
                Text(timeText(first.fireDate))
                    .font(rounded(30, .black))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)

                Text(relativeText(first.fireDate))
                    .font(rounded(11, .semibold))
                    .foregroundStyle(WColor.accent)

                Spacer(minLength: 4)

                HStack(spacing: 4) {
                    Image(systemName: first.missionSymbol)
                        .font(rounded(9, .bold))
                    Text(first.label)
                        .font(rounded(11, .medium))
                        .lineLimit(1)
                }
                .foregroundStyle(.white.opacity(0.65))
            } else if !entry.hasSharedData {
                Spacer()
                NoDataView(compact: true)
                Spacer()
            } else {
                Spacer()
                Text("No alarms")
                    .font(rounded(15, .bold))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer()
            }
        }
    }

    // MARK: Medium

    private var medium: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Image(systemName: "alarm.fill")
                        .font(rounded(11, .bold))
                        .foregroundStyle(WColor.accent)
                    Text("NEXT ALARM")
                        .font(rounded(10, .heavy))
                        .foregroundStyle(.white.opacity(0.5))
                }

                if let first {
                    Text(timeText(first.fireDate))
                        .font(rounded(36, .black))
                        .foregroundStyle(.white)
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                    Text(relativeText(first.fireDate))
                        .font(rounded(12, .semibold))
                        .foregroundStyle(WColor.accent)
                    Text("\(first.label) · \(first.repeatDescription)")
                        .font(rounded(11, .medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                } else if !entry.hasSharedData {
                    NoDataView()
                } else {
                    Text("No alarms set")
                        .font(rounded(18, .bold))
                        .foregroundStyle(.white.opacity(0.55))
                }

                Spacer(minLength: 0)
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 8) {
                if entry.snapshot.currentStreak > 0 {
                    VStack(spacing: 1) {
                        Image(systemName: "flame.fill")
                            .font(rounded(15, .bold))
                            .foregroundStyle(WColor.accent)
                        Text("\(entry.snapshot.currentStreak)")
                            .font(rounded(19, .black))
                            .foregroundStyle(.white)
                        Text("streak")
                            .font(rounded(9, .semibold))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }

                Spacer(minLength: 0)

                ForEach(entry.snapshot.upcoming.dropFirst().prefix(2)) { item in
                    HStack(spacing: 5) {
                        Circle()
                            .fill(Color(widgetHex: item.colorHex))
                            .frame(width: 5, height: 5)
                        Text(timeText(item.fireDate))
                            .font(rounded(11, .semibold))
                            .foregroundStyle(.white.opacity(0.65))
                    }
                }
            }
        }
    }

    // MARK: Lock screen

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            if let first {
                VStack(spacing: -1) {
                    Image(systemName: "alarm.fill").font(rounded(11, .bold))
                    Text(timeText(first.fireDate))
                        .font(rounded(12, .heavy))
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                }
            } else {
                Image(systemName: "alarm.slash").font(rounded(15, .bold))
            }
        }
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let first {
                HStack(spacing: 4) {
                    Image(systemName: "alarm.fill").font(rounded(11, .bold))
                    Text(timeText(first.fireDate)).font(rounded(15, .heavy))
                }
                Text(first.label).font(rounded(12, .medium)).lineLimit(1)
                Text(relativeText(first.fireDate))
                    .font(rounded(11, .regular))
                    .foregroundStyle(.secondary)
            } else {
                Text("SuperAlarm").font(rounded(14, .heavy))
                Text(entry.hasSharedData ? "No alarms set" : "Open the app")
                    .font(rounded(12, .regular))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var inline: some View {
        if let first {
            Label("\(timeText(first.fireDate)) · \(first.label)", systemImage: "alarm.fill")
        } else {
            Label("No alarms", systemImage: "alarm.slash")
        }
    }
}

struct NextAlarmWidget: Widget {
    let kind = "NextAlarmWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: AlarmProvider()) { entry in
            NextAlarmWidgetView(entry: entry)
        }
        .configurationDisplayName("Next Alarm")
        .description("Shows when your next alarm rings and how long you have left.")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline,
        ])
    }
}

// MARK: - Streak widget

struct StreakWidgetView: View {
    let entry: AlarmEntry

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "flame.fill")
                .font(rounded(26, .bold))
                .foregroundStyle(WColor.accent)
            Text("\(entry.snapshot.currentStreak)")
                .font(rounded(40, .black))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            Text(entry.snapshot.currentStreak == 1 ? "day streak" : "day streak")
                .font(rounded(11, .semibold))
                .foregroundStyle(.white.opacity(0.6))
            if entry.snapshot.enabledCount > 0 {
                Text("\(entry.snapshot.enabledCount) alarm\(entry.snapshot.enabledCount == 1 ? "" : "s") on")
                    .font(rounded(10, .medium))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .containerBackground(for: .widget) { WColor.ink }
    }
}

struct StreakWidget: Widget {
    let kind = "StreakWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: AlarmProvider()) { entry in
            StreakWidgetView(entry: entry)
        }
        .configurationDisplayName("Wake-up Streak")
        .description("How many days running you have beaten your alarm.")
        .supportedFamilies([.systemSmall])
    }
}

// MARK: - Bundle

@main
struct SuperAlarmWidgetBundle: WidgetBundle {
    var body: some Widget {
        NextAlarmWidget()
        StreakWidget()
    }
}
