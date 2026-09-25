import SwiftUI
import UIKit

struct AlarmListView: View {
    @EnvironmentObject private var store: AlarmStore
    @EnvironmentObject private var coordinator: AlarmCoordinator
    @EnvironmentObject private var runtime: AlarmRuntime

    @State private var editingAlarm: Alarm?
    @State private var showingQuickAlarm = false
    @State private var showingPermissionHelp = false
    @State private var alarmPendingDelete: Alarm?

    var body: some View {
        NavigationStack {
            ZStack {
                SABackground()

                ScrollView {
                    VStack(spacing: 18) {
                        header
                        if shouldShowPermissionWarning { permissionBanner }
                        nextAlarmCard
                        quickActions
                        alarmSection
                        Color.clear.frame(height: 60)
                    }
                    .padding(.horizontal, SAMetrics.screenPadding)
                    .padding(.top, 8)
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Text("SuperAlarm")
                        .font(SAFont.title(22))
                        .foregroundStyle(SAColor.textPrimary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        HapticEngine.shared.impact(.light)
                        editingAlarm = newAlarm()
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .black))
                            .foregroundStyle(SAColor.onAccent)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(SAColor.accent))
                    }
                    .accessibilityLabel("Add alarm")
                }
            }
            .sheet(item: $editingAlarm) { alarm in
                AlarmEditorView(alarm: alarm)
                    .environmentObject(store)
            }
            .sheet(isPresented: $showingQuickAlarm) {
                QuickAlarmView()
                    .environmentObject(store)
                    .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showingPermissionHelp) {
                PermissionHelpView()
                    .environmentObject(coordinator)
            }
            .confirmationDialog(
                "Delete this alarm?",
                isPresented: Binding(get: { alarmPendingDelete != nil }, set: { if !$0 { alarmPendingDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let alarm = alarmPendingDelete { store.delete(alarm) }
                    alarmPendingDelete = nil
                }
            }
            // An alarm coming due while a sheet is up: the sheet has to go so
            // the ring cover can present over the root.
            .onChange(of: runtime.isPresenting) { _, presenting in
                if presenting {
                    editingAlarm = nil
                    showingQuickAlarm = false
                    showingPermissionHelp = false
                }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 6) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(spacing: 2) {
                    Text(timeString(context.date))
                        .font(SAFont.clock(58))
                        .foregroundStyle(SAColor.textPrimary)
                    Text(dateString(context.date))
                        .font(SAFont.body(15))
                        .foregroundStyle(SAColor.textSecondary)
                }
            }

            if store.settings.showWeather {
                WeatherChip()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }

    private func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = store.settings.use24HourClock ? "HH:mm" : "h:mm"
        return formatter.string(from: date)
    }

    private func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, d MMMM"
        return formatter.string(from: date)
    }

    // MARK: Permission banner

    private var shouldShowPermissionWarning: Bool {
        !coordinator.usesSystemAlarms && (!coordinator.notificationsAuthorized || coordinator.systemAlarmsDenied)
    }

    private var permissionWarningTitle: String {
        coordinator.systemAlarmsDenied ? "System alarms are turned off" : "Alarms can't ring"
    }

    private var permissionBanner: some View {
        Button {
            showingPermissionHelp = true
        } label: {
            SACard(background: SAColor.danger.opacity(0.15)) {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(SAColor.danger)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(permissionWarningTitle)
                            .font(SAFont.emphasis(16))
                            .foregroundStyle(SAColor.textPrimary)
                        Text("Permission is off. Tap to fix it.")
                            .font(SAFont.body(13))
                            .foregroundStyle(SAColor.textSecondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(SAColor.textTertiary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: Next alarm

    @ViewBuilder
    private var nextAlarmCard: some View {
        if let next = store.nextAlarm {
            SACard(background: SAColor.accent) {
                HStack(alignment: .center, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("NEXT ALARM")
                            .font(SAFont.caption(11))
                            .kerning(1.2)
                            .foregroundStyle(SAColor.onAccent.opacity(0.65))
                        Text(next.alarm.timeString(use24Hour: store.settings.use24HourClock)
                            + (store.settings.use24HourClock ? "" : " \(next.alarm.meridiemString)"))
                            .font(SAFont.display(34))
                            .foregroundStyle(SAColor.onAccent)
                        Text(countdownText(to: next.date))
                            .font(SAFont.emphasis(14))
                            .foregroundStyle(SAColor.onAccent.opacity(0.8))
                    }
                    Spacer()
                    VStack(spacing: 6) {
                        Image(systemName: next.alarm.mission.type.symbolName)
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(SAColor.onAccent)
                            .accessibilityHidden(true)
                        Text(next.alarm.mission.type.displayName)
                            .font(SAFont.caption(11))
                            .foregroundStyle(SAColor.onAccent.opacity(0.75))
                            .multilineTextAlignment(.center)
                    }
                    .frame(minWidth: 84)
                }
                .accessibilityElement(children: .combine)
            }
        } else {
            SACard {
                HStack(spacing: 12) {
                    Image(systemName: "moon.zzz.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(SAColor.textTertiary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No alarms set")
                            .font(SAFont.emphasis(16))
                            .foregroundStyle(SAColor.textPrimary)
                        Text("Tap + to add your first one.")
                            .font(SAFont.body(13))
                            .foregroundStyle(SAColor.textSecondary)
                    }
                    Spacer()
                }
            }
        }
    }

    private func countdownText(to date: Date) -> String {
        let seconds = Int(date.timeIntervalSinceNow)
        guard seconds > 0 else { return "Ringing now" }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return "Rings in \(days) d \(hours) hr" }
        if hours > 0 { return "Rings in \(hours) hr \(minutes) min" }
        if minutes > 0 { return "Rings in \(minutes) min" }
        return "Rings in under a minute"
    }

    // MARK: Quick actions

    private var quickActions: some View {
        HStack(spacing: 12) {
            quickActionButton(
                title: "Quick alarm",
                subtitle: "Nap or reminder",
                icon: "timer"
            ) {
                showingQuickAlarm = true
            }

            quickActionButton(
                title: "Weekday set",
                subtitle: "Mon–Fri",
                icon: "briefcase.fill"
            ) {
                var alarm = newAlarm()
                alarm.repeatMode = .weekly
                alarm.repeatDays = Weekday.workdays
                alarm.label = "Weekdays"
                editingAlarm = alarm
            }
        }
    }

    private func quickActionButton(
        title: String,
        subtitle: String,
        icon: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            HapticEngine.shared.impact(.light)
            action()
        } label: {
            SACard(background: SAColor.surface, padding: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(SAColor.accent)
                        .accessibilityHidden(true)
                    Text(title)
                        .font(SAFont.emphasis(15))
                        .foregroundStyle(SAColor.textPrimary)
                    Text(subtitle)
                        .font(SAFont.body(12))
                        .foregroundStyle(SAColor.textSecondary)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    // MARK: Alarm list

    private var alarmSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !store.alarms.isEmpty {
                SASectionHeader("All alarms", subtitle: "\(store.enabledAlarms.count) of \(store.alarms.count) on")
            }

            VStack(spacing: 10) {
                ForEach(store.sortedAlarms) { alarm in
                    AlarmRowView(alarm: alarm)
                        .onTapGesture {
                            HapticEngine.shared.impact(.light)
                            editingAlarm = alarm
                        }
                        .contextMenu {
                            Button {
                                editingAlarm = alarm
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }

                            if alarm.isRepeating {
                                Button {
                                    store.setSkipNext(!alarm.skipNextOccurrence, for: alarm.id)
                                } label: {
                                    Label(
                                        alarm.skipNextOccurrence ? "Don't skip next" : "Skip next occurrence",
                                        systemImage: "forward.end.fill"
                                    )
                                }
                            }

                            Button {
                                duplicate(alarm)
                            } label: {
                                Label("Duplicate", systemImage: "plus.square.on.square")
                            }

                            Button(role: .destructive) {
                                alarmPendingDelete = alarm
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .accessibilityAction(named: "Edit") { editingAlarm = alarm }
                        .accessibilityAction(named: "Delete") { alarmPendingDelete = alarm }
                }
            }
        }
    }

    private func duplicate(_ alarm: Alarm) {
        var copy = alarm
        copy.id = UUID()
        copy.createdAt = Date()
        copy.lastFiredAt = nil
        // A registered photo or code belongs to the original alarm; the copy
        // gets no mission rather than a half-configured one that would slide
        // straight off at ring time.
        if copy.mission.type.requiresSetup {
            copy.mission = MissionSettings()
        }
        store.add(copy)
    }

    private func newAlarm() -> Alarm {
        var alarm = Alarm(hour: 7, minute: 0)
        store.settings.applyDefaults(to: &alarm)
        return alarm
    }
}

// MARK: - Row

struct AlarmRowView: View {
    @EnvironmentObject private var store: AlarmStore
    let alarm: Alarm

    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color(hexString: AlarmPalette.hex(for: alarm.colorTag)))
                .frame(width: 4, height: 44)
                .opacity(alarm.isEnabled ? 1 : 0.3)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(alarm.timeString(use24Hour: store.settings.use24HourClock))
                        .font(SAFont.clock(32))
                        .foregroundStyle(alarm.isEnabled ? SAColor.textPrimary : SAColor.textTertiary)
                    if !store.settings.use24HourClock {
                        Text(alarm.meridiemString)
                            .font(SAFont.emphasis(14))
                            .foregroundStyle(alarm.isEnabled ? SAColor.textSecondary : SAColor.textTertiary)
                    }
                }

                Text("\(alarm.displayLabel) · \(alarm.repeatDescription)")
                    .font(SAFont.body(13))
                    .foregroundStyle(alarm.isEnabled ? SAColor.textSecondary : SAColor.textTertiary)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    if alarm.mission.type != .none {
                        badge(icon: alarm.mission.type.symbolName, text: alarm.mission.type.displayName)
                    }
                    if alarm.wakeUpCheck.isEnabled {
                        badge(icon: "eye.fill", text: "Wake check")
                    }
                    if alarm.skipNextOccurrence {
                        badge(icon: "forward.end.fill", text: "Skipping next", tint: SAColor.warning)
                    }
                }
            }

            Spacer(minLength: 4)

            Toggle("Alarm at \(alarm.timeString(use24Hour: store.settings.use24HourClock))", isOn: Binding(
                get: { alarm.isEnabled },
                set: { newValue in
                    HapticEngine.shared.impact(.light)
                    store.setEnabled(newValue, for: alarm.id)
                }
            ))
            .labelsHidden()
            .tint(SAColor.accent)
        }
        .padding(14)
        .background(SAColor.surface, in: RoundedRectangle(cornerRadius: SAMetrics.cardRadius, style: .continuous))
        .opacity(alarm.isEnabled ? 1 : 0.62)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(rowAccessibilityLabel)
        .accessibilityHint("Double-tap to edit")
    }

    private var rowAccessibilityLabel: String {
        var parts = [
            "\(alarm.timeString(use24Hour: store.settings.use24HourClock)) \(store.settings.use24HourClock ? "" : alarm.meridiemString)",
            alarm.displayLabel,
            alarm.repeatDescription,
        ]
        if alarm.mission.type != .none { parts.append("\(alarm.mission.type.displayName) mission") }
        if alarm.wakeUpCheck.isEnabled { parts.append("wake-up check") }
        if alarm.skipNextOccurrence { parts.append("skipping next") }
        return parts.joined(separator: ", ")
    }

    private func badge(icon: String, text: String, tint: Color = SAColor.accent) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
            Text(text)
                .font(SAFont.caption(11))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(tint.opacity(0.15)))
    }
}

// MARK: - Weather chip

struct WeatherChip: View {
    @EnvironmentObject private var store: AlarmStore
    @StateObject private var weather = WeatherService.shared

    var body: some View {
        Group {
            if let snapshot = weather.snapshot {
                HStack(spacing: 7) {
                    Image(systemName: snapshot.symbolName)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(SAColor.accent)
                    Text("\(snapshot.temperature(in: store.settings.temperatureUnit))\(store.settings.temperatureUnit.symbol)")
                        .font(SAFont.emphasis(13))
                        .foregroundStyle(SAColor.textPrimary)
                    Text(snapshot.summary)
                        .font(SAFont.body(13))
                        .foregroundStyle(SAColor.textSecondary)
                    if !snapshot.locationName.isEmpty {
                        Text("· \(snapshot.locationName)")
                            .font(SAFont.body(13))
                            .foregroundStyle(SAColor.textTertiary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(SAColor.surface))
            } else if weather.authorizationStatus == .notDetermined {
                Button {
                    weather.requestAuthorization()
                } label: {
                    Text("Enable weather")
                        .font(SAFont.caption(13))
                }
                .buttonStyle(PillButtonStyle())
            } else if weather.authorizationStatus == .denied || weather.authorizationStatus == .restricted {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    Link(destination: url) {
                        Text("Weather needs location — open Settings")
                            .font(SAFont.caption(13))
                    }
                    .buttonStyle(PillButtonStyle())
                }
            }
        }
        .task {
            await weather.refreshIfNeeded()
        }
    }
}
