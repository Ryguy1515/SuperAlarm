import SwiftUI

struct AlarmEditorView: View {
    @EnvironmentObject private var store: AlarmStore
    @EnvironmentObject private var runtime: AlarmRuntime
    @Environment(\.dismiss) private var dismiss

    @State private var draft: Alarm
    @State private var showingDeleteConfirm = false

    init(alarm: Alarm) {
        _draft = State(initialValue: alarm)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                SABackground()

                ScrollView {
                    VStack(spacing: 16) {
                        timeSection
                        repeatSection
                        labelSection
                        behaviourSection
                        extrasSection
                        colourSection
                        actionsSection
                        Color.clear.frame(height: 24)
                    }
                    .padding(.horizontal, SAMetrics.screenPadding)
                    .padding(.top, 6)
                }
            }
            .navigationTitle(existsInStore ? "Edit alarm" : "New alarm")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(SAColor.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .font(SAFont.emphasis(16))
                        .foregroundStyle(SAColor.accent)
                }
            }
            .confirmationDialog(
                "Delete this alarm?",
                isPresented: $showingDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    store.delete(draft)
                    dismiss()
                }
            }
        }
    }

    private var existsInStore: Bool {
        store.alarm(with: draft.id) != nil
    }

    // MARK: Time

    private var timeSection: some View {
        SACard(padding: 8) {
            VStack(spacing: 0) {
                DatePicker(
                    "",
                    selection: timeBinding,
                    displayedComponents: .hourAndMinute
                )
                .datePickerStyle(.wheel)
                .labelsHidden()
                .environment(\.locale, store.settings.use24HourClock ? Locale(identifier: "en_GB") : Locale(identifier: "en_US"))

                Text(draft.timeUntilDescription(from: Date()).map { "Rings \($0)" } ?? "Currently off")
                    .font(SAFont.body(13))
                    .foregroundStyle(SAColor.textSecondary)
                    .padding(.bottom, 8)
            }
        }
    }

    private var timeBinding: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(
                    bySettingHour: draft.hour, minute: draft.minute, second: 0, of: Date()
                ) ?? Date()
            },
            set: { newValue in
                let components = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                draft.hour = components.hour ?? draft.hour
                draft.minute = components.minute ?? draft.minute
            }
        )
    }

    // MARK: Repeat

    private var repeatSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SASectionHeader("Repeat")

            SACard(padding: 14) {
                VStack(spacing: 14) {
                    Picker("Repeat", selection: $draft.repeatMode) {
                        ForEach(RepeatMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    switch draft.repeatMode {
                    case .once:
                        Text("Rings once at the next occurrence of this time, then switches itself off.")
                            .font(SAFont.body(13))
                            .foregroundStyle(SAColor.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                    case .weekly:
                        weekdayPicker

                    case .dates:
                        datePicker
                    }
                }
            }
        }
    }

    private var weekdayPicker: some View {
        VStack(spacing: 12) {
            HStack(spacing: 6) {
                ForEach(Weekday.orderedForLocale()) { day in
                    let selected = draft.repeatDays.contains(day)
                    Button {
                        HapticEngine.shared.selection()
                        if selected {
                            draft.repeatDays.remove(day)
                        } else {
                            draft.repeatDays.insert(day)
                        }
                    } label: {
                        Text(day.minimalName)
                            .font(SAFont.caption(14))
                            .foregroundStyle(selected ? SAColor.onAccent : SAColor.textSecondary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 42)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(selected ? SAColor.accent : SAColor.surfaceElevated)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 8) {
                presetButton("Every day", days: Weekday.everyDay)
                presetButton("Weekdays", days: Weekday.workdays)
                presetButton("Weekends", days: Weekday.weekend)
            }
        }
    }

    private func presetButton(_ title: String, days: Set<Weekday>) -> some View {
        Button {
            HapticEngine.shared.selection()
            draft.repeatDays = days
        } label: {
            Text(title)
                .font(SAFont.caption(12))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(PillButtonStyle(filled: draft.repeatDays == days))
    }

    private var datePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            MultiDatePicker("Pick dates", selection: specificDatesBinding, in: Date()...)
                .frame(minHeight: 320)

            Text(draft.specificDates.isEmpty
                 ? "Pick one or more dates for this alarm."
                 : "\(draft.specificDates.count) date\(draft.specificDates.count == 1 ? "" : "s") selected.")
                .font(SAFont.body(13))
                .foregroundStyle(SAColor.textSecondary)
        }
    }

    private var specificDatesBinding: Binding<Set<DateComponents>> {
        Binding(
            get: {
                Set(draft.specificDates.map {
                    Calendar.current.dateComponents([.year, .month, .day], from: $0)
                })
            },
            set: { components in
                draft.specificDates = components
                    .compactMap { Calendar.current.date(from: $0) }
                    .sorted()
            }
        )
    }

    // MARK: Label

    private var labelSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SASectionHeader("Name and note")

            SACard(padding: 0) {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Image(systemName: "textformat")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(SAColor.accent)
                            .frame(width: 24)
                        TextField("Alarm name", text: $draft.label)
                            .font(SAFont.body(16))
                            .foregroundStyle(SAColor.textPrimary)
                    }
                    .padding(16)

                    SADivider()

                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "note.text")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(SAColor.accent)
                            .frame(width: 24)
                            .padding(.top, 2)
                        TextField("Memo shown when it rings", text: $draft.memo, axis: .vertical)
                            .font(SAFont.body(16))
                            .foregroundStyle(SAColor.textPrimary)
                            .lineLimit(1...4)
                    }
                    .padding(16)
                }
            }
        }
    }

    // MARK: Behaviour

    private var behaviourSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SASectionHeader("How it wakes you")

            VStack(spacing: 0) {
                NavigationLink {
                    SoundPickerView(sound: $draft.sound)
                } label: {
                    SARow(
                        icon: "speaker.wave.3.fill",
                        title: "Sound",
                        subtitle: ToneResolver.displayName(for: draft.sound.toneID)
                    )
                }

                SADivider()

                NavigationLink {
                    MissionPickerView(mission: $draft.mission)
                        .environmentObject(store)
                } label: {
                    SARow(
                        icon: draft.mission.type.symbolName,
                        title: "Mission",
                        subtitle: draft.mission.summary,
                        iconTint: draft.mission.type == .none ? SAColor.textTertiary : SAColor.accent
                    )
                }

                SADivider()

                NavigationLink {
                    SnoozeSettingsView(snooze: $draft.snooze)
                } label: {
                    SARow(icon: "zzz", title: "Snooze", subtitle: draft.snooze.summary)
                }

                SADivider()

                NavigationLink {
                    WakeUpCheckSettingsView(check: $draft.wakeUpCheck)
                } label: {
                    SARow(
                        icon: "eye.fill",
                        title: "Wake-up check",
                        subtitle: draft.wakeUpCheck.summary,
                        iconTint: draft.wakeUpCheck.isEnabled ? SAColor.accent : SAColor.textTertiary
                    )
                }
            }
            .saGroupedCard()
        }
    }

    // MARK: Extras

    private var extrasSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SASectionHeader("Extras")

            VStack(spacing: 0) {
                NavigationLink {
                    PreAlarmSettingsView(preAlarm: $draft.preAlarm)
                } label: {
                    SARow(
                        icon: "bell.badge.fill",
                        title: "Pre-alarm",
                        subtitle: draft.preAlarm.summary,
                        iconTint: draft.preAlarm.isEnabled ? SAColor.accent : SAColor.textTertiary
                    )
                }

                SADivider()

                NavigationLink {
                    VoiceBriefingSettingsView(briefing: $draft.voiceBriefing, alarm: draft)
                        .environmentObject(store)
                } label: {
                    SARow(
                        icon: "waveform.and.mic",
                        title: "Voice briefing",
                        subtitle: draft.voiceBriefing.summary,
                        iconTint: draft.voiceBriefing.isEnabled ? SAColor.accent : SAColor.textTertiary
                    )
                }

                if draft.isRepeating {
                    SADivider()

                    HStack {
                        SARow(
                            icon: "forward.end.fill",
                            title: "Skip next occurrence",
                            subtitle: draft.skipNextOccurrence ? "The next one will be skipped" : nil,
                            iconTint: draft.skipNextOccurrence ? SAColor.warning : SAColor.textTertiary,
                            showsChevron: false
                        ) {
                            Toggle("", isOn: $draft.skipNextOccurrence)
                                .labelsHidden()
                                .tint(SAColor.accent)
                        }
                    }
                }
            }
            .saGroupedCard()
        }
    }

    // MARK: Colour

    private var colourSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SASectionHeader("Colour tag")

            SACard(padding: 14) {
                HStack(spacing: 12) {
                    ForEach(Array(AlarmPalette.tags.enumerated()), id: \.offset) { index, hex in
                        Button {
                            HapticEngine.shared.selection()
                            draft.colorTag = index
                        } label: {
                            Circle()
                                .fill(Color(hexString: hex))
                                .frame(width: 30, height: 30)
                                .overlay {
                                    if draft.colorTag == index {
                                        Circle()
                                            .strokeBorder(SAColor.textPrimary, lineWidth: 2.5)
                                            .padding(-4)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    // MARK: Actions

    private var actionsSection: some View {
        VStack(spacing: 12) {
            Button {
                testAlarm()
            } label: {
                Label("Test this alarm now", systemImage: "play.fill")
            }
            .buttonStyle(SecondaryButtonStyle())

            if existsInStore {
                Button(role: .destructive) {
                    showingDeleteConfirm = true
                } label: {
                    Label("Delete alarm", systemImage: "trash")
                        .font(SAFont.emphasis(16))
                        .foregroundStyle(SAColor.danger)
                        .frame(maxWidth: .infinity)
                        .frame(height: SAMetrics.buttonHeight)
                }
                .background(
                    RoundedRectangle(cornerRadius: SAMetrics.buttonRadius, style: .continuous)
                        .fill(SAColor.danger.opacity(0.12))
                )
            }
        }
    }

    // MARK: Actions

    private func save() {
        var alarm = draft
        alarm.isEnabled = true
        // A mission that was never finished being set up would lock the user
        // out of their own alarm, so fall back to no mission.
        if !alarm.mission.isReady {
            alarm.mission = MissionSettings()
        }
        store.update(alarm)
        HapticEngine.shared.success()
        dismiss()
    }

    /// Rings this alarm immediately so the whole flow can be rehearsed at a
    /// sensible hour rather than discovered at 6am.
    private func testAlarm() {
        var alarm = draft
        if !alarm.mission.isReady { alarm.mission = MissionSettings() }
        store.update(alarm)
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            runtime.startRinging(alarm: alarm, occurrence: Date())
        }
    }
}
