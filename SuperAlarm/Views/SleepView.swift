import SwiftUI

struct SleepView: View {
    @EnvironmentObject private var store: AlarmStore
    @StateObject private var player = SleepSoundPlayer.shared

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                SABackground()

                ScrollView {
                    VStack(spacing: 18) {
                        goodNightCard
                        nowPlayingCard
                        soundGrid
                        durationCard
                        bedtimeCard
                        Color.clear.frame(height: 60)
                    }
                    .padding(.horizontal, SAMetrics.screenPadding)
                    .padding(.top, 8)
                }
            }
            .navigationTitle("Sleep")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: Good night

    private var goodNightCard: some View {
        SACard(background: SAColor.surface) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "moon.stars.fill")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(SAColor.accent)
                    Text("Good night & sleep tight")
                        .font(SAFont.title(21))
                        .foregroundStyle(SAColor.textPrimary)
                }

                Divider().overlay(SAColor.separator)

                if let next = store.nextAlarm {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("UPCOMING ALARM")
                            .font(SAFont.caption(11))
                            .kerning(1.1)
                            .foregroundStyle(SAColor.textTertiary)
                        Text(next.alarm.timeString(use24Hour: store.settings.use24HourClock)
                             + (store.settings.use24HourClock ? "" : " \(next.alarm.meridiemString)"))
                            .font(SAFont.display(32))
                            .foregroundStyle(SAColor.textPrimary)
                        Text(willRingText(next.date))
                            .font(SAFont.body(14))
                            .foregroundStyle(SAColor.textSecondary)

                        if let sleep = sleepDurationText(next.date) {
                            Text(sleep)
                                .font(SAFont.caption(13))
                                .foregroundStyle(SAColor.accent)
                                .padding(.top, 2)
                        }
                    }
                } else {
                    Text("No alarm set. Add one before you turn in.")
                        .font(SAFont.body(15))
                        .foregroundStyle(SAColor.textSecondary)
                }
            }
        }
    }

    private func willRingText(_ date: Date) -> String {
        let formatter = DateFormatter()
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Will ring today" }
        if calendar.isDateInTomorrow(date) { return "Will ring tomorrow" }
        let days = calendar.dateComponents([.day], from: Date(), to: date).day ?? 0
        if days <= 6 {
            formatter.dateFormat = "EEEE"
            return "Will ring on \(formatter.string(from: date))"
        }
        formatter.dateFormat = "d MMMM"
        return "Will ring on \(formatter.string(from: date))"
    }

    private func sleepDurationText(_ date: Date) -> String? {
        let seconds = date.timeIntervalSinceNow
        guard seconds > 0, seconds < 20 * 3600 else { return nil }
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        return "\(hours)h \(minutes)m of sleep if you fall asleep now"
    }

    // MARK: Now playing

    @ViewBuilder
    private var nowPlayingCard: some View {
        let selected = SleepSoundCatalog.sound(id: store.settings.sleepSound.soundID)

        SACard(background: SAColor.surfaceElevated) {
            HStack(spacing: 14) {
                Image(systemName: "waveform")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(player.isPlaying ? SAColor.accent : SAColor.textTertiary)
                    .symbolEffect(.variableColor, options: .repeating, isActive: player.isPlaying)

                VStack(alignment: .leading, spacing: 3) {
                    Text(selected?.name ?? "No sound selected")
                        .font(SAFont.emphasis(17))
                        .foregroundStyle(SAColor.textPrimary)
                    Text(player.remainingLabel
                         ?? (player.isPlaying ? "Playing until your alarm" : "Tap play to start"))
                        .font(SAFont.body(13))
                        .foregroundStyle(SAColor.textSecondary)
                }

                Spacer()

                Button {
                    togglePlayback(selected)
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18, weight: .black))
                        .foregroundStyle(SAColor.onAccent)
                        .frame(width: 48, height: 48)
                        .background(Circle().fill(selected == nil ? SAColor.textTertiary : SAColor.accent))
                }
                .buttonStyle(.plain)
                .disabled(selected == nil)
            }
        }
    }

    private func togglePlayback(_ sound: SleepSound?) {
        guard let sound else { return }
        if player.isPlaying {
            player.stop()
            return
        }
        HapticEngine.shared.impact(.light)
        let stopAt = store.settings.sleepSound.durationMinutes == 0 ? store.nextAlarm?.date : nil
        player.play(sound, settings: store.settings.sleepSound, stopAt: stopAt)
    }

    // MARK: Sound grid

    private var soundGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            SASectionHeader("Sleep sounds", subtitle: "Ambience to fall asleep to")

            LazyVGrid(columns: columns, spacing: 12) {
                noneTile

                ForEach(SleepSoundCatalog.all) { sound in
                    soundTile(sound)
                }
            }
        }
    }

    private var noneTile: some View {
        let isSelected = store.settings.sleepSound.soundID == nil

        return Button {
            HapticEngine.shared.selection()
            store.settings.sleepSound.soundID = nil
            player.stop()
        } label: {
            VStack(spacing: 8) {
                Image(systemName: "circle.dashed")
                    .font(.system(size: 22, weight: .bold))
                Text("None")
                    .font(SAFont.caption(12))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? SAColor.onAccent : SAColor.textSecondary)
            .frame(maxWidth: .infinity)
            .frame(height: 88)
            .background(
                RoundedRectangle(cornerRadius: SAMetrics.tileRadius, style: .continuous)
                    .fill(isSelected ? SAColor.accent : SAColor.surface)
            )
        }
        .buttonStyle(.plain)
    }

    private func soundTile(_ sound: SleepSound) -> some View {
        let isSelected = store.settings.sleepSound.soundID == sound.id
        let isPlaying = player.playingID == sound.id

        return Button {
            HapticEngine.shared.selection()
            store.settings.sleepSound.soundID = sound.id
            let stopAt = store.settings.sleepSound.durationMinutes == 0 ? store.nextAlarm?.date : nil
            player.play(sound, settings: store.settings.sleepSound, stopAt: stopAt)
        } label: {
            VStack(spacing: 8) {
                Image(systemName: sound.symbolName)
                    .font(.system(size: 22, weight: .bold))
                    .symbolEffect(.variableColor, options: .repeating, isActive: isPlaying)
                Text(sound.name)
                    .font(SAFont.caption(12))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(isSelected ? SAColor.onAccent : SAColor.textSecondary)
            .frame(maxWidth: .infinity)
            .frame(height: 88)
            .background(
                RoundedRectangle(cornerRadius: SAMetrics.tileRadius, style: .continuous)
                    .fill(isSelected ? SAColor.accent : SAColor.surface)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: Duration

    private var durationCard: some View {
        SACard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Playback duration")
                        .font(SAFont.emphasis(16))
                        .foregroundStyle(SAColor.textPrimary)
                    Spacer()
                    Text(store.settings.sleepSound.durationLabel)
                        .font(SAFont.emphasis(16))
                        .foregroundStyle(SAColor.accent)
                }

                Picker("Duration", selection: $store.settings.sleepSound.durationMinutes) {
                    ForEach(SleepSoundCatalog.durationOptions, id: \.self) { minutes in
                        Text(minutes == 0 ? "Until alarm" : "\(minutes)m").tag(minutes)
                    }
                }
                .pickerStyle(.menu)
                .tint(SAColor.accent)

                Divider().overlay(SAColor.separator)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Volume")
                        .font(SAFont.emphasis(15))
                        .foregroundStyle(SAColor.textPrimary)
                    Slider(value: $store.settings.sleepSound.volume, in: 0.05...1.0)
                        .tint(SAColor.accent)
                }

                Toggle("Fade out at the end", isOn: $store.settings.sleepSound.fadeOut)
                    .font(SAFont.emphasis(15))
                    .tint(SAColor.accent)
            }
        }
    }

    // MARK: Bedtime

    private var bedtimeCard: some View {
        SACard {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: $store.settings.bedtimeReminderEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Bedtime reminder")
                            .font(SAFont.emphasis(16))
                            .foregroundStyle(SAColor.textPrimary)
                        Text("A nightly nudge to start winding down")
                            .font(SAFont.body(12))
                            .foregroundStyle(SAColor.textSecondary)
                    }
                }
                .tint(SAColor.accent)

                if store.settings.bedtimeReminderEnabled {
                    Divider().overlay(SAColor.separator)
                    DatePicker(
                        "Remind me at",
                        selection: bedtimeBinding,
                        displayedComponents: .hourAndMinute
                    )
                    .font(SAFont.emphasis(15))
                    .tint(SAColor.accent)
                }
            }
        }
    }

    private var bedtimeBinding: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(
                    bySettingHour: store.settings.bedtimeHour,
                    minute: store.settings.bedtimeMinute,
                    second: 0,
                    of: Date()
                ) ?? Date()
            },
            set: { newValue in
                let components = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                store.settings.bedtimeHour = components.hour ?? 23
                store.settings.bedtimeMinute = components.minute ?? 0
            }
        )
    }
}
