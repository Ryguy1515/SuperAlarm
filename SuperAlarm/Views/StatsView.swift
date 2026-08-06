import SwiftUI

struct StatsView: View {
    @EnvironmentObject private var store: AlarmStore
    @State private var showingClearConfirm = false

    private var stats: WakeStatistics { store.statistics }

    var body: some View {
        NavigationStack {
            ZStack {
                SABackground()

                ScrollView {
                    VStack(spacing: 18) {
                        if store.history.isEmpty {
                            emptyState
                        } else {
                            streakCard
                            summaryGrid
                            chartCard
                            weekdayCard
                            historySection
                        }
                        Color.clear.frame(height: 60)
                    }
                    .padding(.horizontal, SAMetrics.screenPadding)
                    .padding(.top, 8)
                }
            }
            .navigationTitle("Stats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !store.history.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showingClearConfirm = true
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(SAColor.textSecondary)
                        }
                    }
                }
            }
            .confirmationDialog(
                "Clear all wake-up history?",
                isPresented: $showingClearConfirm,
                titleVisibility: .visible
            ) {
                Button("Clear history", role: .destructive) { store.clearHistory() }
            }
        }
    }

    // MARK: Empty

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 46, weight: .bold))
                .foregroundStyle(SAColor.textTertiary)
            Text("No wake-ups yet")
                .font(SAFont.title(22))
                .foregroundStyle(SAColor.textPrimary)
            Text("Once your first alarm goes off, your streak and wake-up history will build up here.")
                .font(SAFont.body(15))
                .foregroundStyle(SAColor.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .padding(.top, 70)
    }

    // MARK: Streak

    private var streakCard: some View {
        SACard(background: SAColor.accent) {
            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("CURRENT STREAK")
                        .font(SAFont.caption(11))
                        .kerning(1.2)
                        .foregroundStyle(SAColor.onAccent.opacity(0.65))
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(stats.currentStreak)")
                            .font(SAFont.display(52))
                            .foregroundStyle(SAColor.onAccent)
                        Text(stats.currentStreak == 1 ? "day" : "days")
                            .font(SAFont.headline(18))
                            .foregroundStyle(SAColor.onAccent.opacity(0.75))
                    }
                    Text("Best: \(stats.longestStreak) \(stats.longestStreak == 1 ? "day" : "days")")
                        .font(SAFont.body(13))
                        .foregroundStyle(SAColor.onAccent.opacity(0.75))
                }

                Spacer()

                Image(systemName: "flame.fill")
                    .font(.system(size: 50, weight: .bold))
                    .foregroundStyle(SAColor.onAccent.opacity(0.9))
            }
        }
    }

    // MARK: Summary

    private var summaryGrid: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
            spacing: 12
        ) {
            statTile(
                value: "\(Int((stats.successRate * 100).rounded()))%",
                label: "Woke up on target",
                icon: "checkmark.circle.fill",
                tint: SAColor.success
            )
            statTile(
                value: "\(stats.totalWakeUps)",
                label: "Alarms recorded",
                icon: "alarm.fill",
                tint: SAColor.accent
            )
            statTile(
                value: formatDuration(stats.averageDismissSeconds),
                label: "Average to dismiss",
                icon: "timer",
                tint: SAColor.warning
            )
            statTile(
                value: "\(stats.totalSnoozes)",
                label: "Total snoozes",
                icon: "zzz",
                tint: SAColor.textSecondary
            )
        }
    }

    private func statTile(value: String, label: String, icon: String, tint: Color) -> some View {
        SACard(padding: 15) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(tint)
                Text(value)
                    .font(SAFont.display(27))
                    .foregroundStyle(SAColor.textPrimary)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                Text(label)
                    .font(SAFont.body(12))
                    .foregroundStyle(SAColor.textSecondary)
                    .lineLimit(2)
            }
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        guard seconds > 0 else { return "—" }
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        return "\(total / 60)m \(total % 60)s"
    }

    // MARK: Chart

    private var chartCard: some View {
        SACard {
            VStack(alignment: .leading, spacing: 14) {
                Text("Last 30 days")
                    .font(SAFont.headline(17))
                    .foregroundStyle(SAColor.textPrimary)

                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(stats.recentDays) { day in
                        VStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(barColour(day))
                                .frame(height: barHeight(day))
                                .frame(maxWidth: .infinity)
                        }
                        .frame(height: 90, alignment: .bottom)
                    }
                }

                HStack(spacing: 16) {
                    legend(colour: SAColor.success, text: "Woke up")
                    legend(colour: SAColor.warning, text: "Snoozed a lot")
                    legend(colour: SAColor.separator, text: "No alarm")
                }
            }
        }
    }

    private func barHeight(_ day: WakeStatistics.DaySummary) -> CGFloat {
        guard day.hasRecord else { return 6 }
        // Taller bars mean a slower, more reluctant wake-up.
        let seconds = day.dismissSeconds ?? 60
        let normalised = min(1, seconds / 600)
        return 20 + CGFloat(normalised) * 68
    }

    private func barColour(_ day: WakeStatistics.DaySummary) -> Color {
        guard day.hasRecord else { return SAColor.separator }
        if !day.succeeded { return SAColor.danger }
        return day.snoozes >= 3 ? SAColor.warning : SAColor.success
    }

    private func legend(colour: Color, text: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(colour).frame(width: 10, height: 10)
            Text(text)
                .font(SAFont.caption(11))
                .foregroundStyle(SAColor.textTertiary)
        }
    }

    // MARK: Weekday

    private var weekdayCard: some View {
        SACard {
            VStack(alignment: .leading, spacing: 14) {
                Text("Wake-ups by day")
                    .font(SAFont.headline(17))
                    .foregroundStyle(SAColor.textPrimary)

                let maximum = max(1, stats.byWeekday.values.max() ?? 1)

                HStack(alignment: .bottom, spacing: 8) {
                    ForEach(Weekday.orderedForLocale()) { day in
                        let count = stats.byWeekday[day.rawValue] ?? 0
                        VStack(spacing: 6) {
                            Text("\(count)")
                                .font(SAFont.caption(11))
                                .foregroundStyle(SAColor.textTertiary)
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(count > 0 ? SAColor.accent : SAColor.separator)
                                .frame(height: max(6, CGFloat(count) / CGFloat(maximum) * 70))
                            Text(day.minimalName)
                                .font(SAFont.caption(11))
                                .foregroundStyle(SAColor.textSecondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }

                if let favourite = stats.favouriteMission {
                    Divider().overlay(SAColor.separator)
                    HStack(spacing: 10) {
                        Image(systemName: favourite.symbolName)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(SAColor.accent)
                        Text("Most-used mission: \(favourite.displayName)")
                            .font(SAFont.body(14))
                            .foregroundStyle(SAColor.textSecondary)
                    }
                }
            }
        }
    }

    // MARK: History

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SASectionHeader("Recent wake-ups")

            VStack(spacing: 0) {
                let recent = store.history.sorted { $0.scheduledFor > $1.scheduledFor }.prefix(25)
                ForEach(Array(recent.enumerated()), id: \.element.id) { index, record in
                    historyRow(record)
                    if index < recent.count - 1 { SADivider() }
                }
            }
            .saGroupedCard()
        }
    }

    private func historyRow(_ record: WakeRecord) -> some View {
        HStack(spacing: 12) {
            Image(systemName: record.outcome.symbolName)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(outcomeColour(record.outcome))
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(record.alarmLabel)
                    .font(SAFont.emphasis(15))
                    .foregroundStyle(SAColor.textPrimary)
                    .lineLimit(1)
                Text(dateLabel(record.scheduledFor))
                    .font(SAFont.body(12))
                    .foregroundStyle(SAColor.textSecondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(record.durationLabel)
                    .font(SAFont.emphasis(14))
                    .foregroundStyle(SAColor.textPrimary)
                HStack(spacing: 6) {
                    if record.snoozeCount > 0 {
                        Label("\(record.snoozeCount)", systemImage: "zzz")
                            .font(SAFont.caption(11))
                            .foregroundStyle(SAColor.textTertiary)
                    }
                    if record.missionType != .none {
                        Image(systemName: record.missionType.symbolName)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(SAColor.textTertiary)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func outcomeColour(_ outcome: WakeRecord.Outcome) -> Color {
        switch outcome {
        case .dismissed: return SAColor.success
        case .rangOut: return SAColor.warning
        case .missed: return SAColor.danger
        case .skipped: return SAColor.textTertiary
        }
    }

    private func dateLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = store.settings.use24HourClock ? "EEE d MMM, HH:mm" : "EEE d MMM, h:mm a"
        return formatter.string(from: date)
    }
}
