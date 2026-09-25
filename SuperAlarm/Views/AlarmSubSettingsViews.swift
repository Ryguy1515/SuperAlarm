import SwiftUI
import UIKit

// MARK: - Snooze

struct SnoozeSettingsView: View {
    @Binding var snooze: SnoozeSettings

    var body: some View {
        ZStack {
            SABackground()

            ScrollView {
                VStack(spacing: 16) {
                    SACard(padding: 0) {
                        SARow(icon: "zzz", title: "Allow snooze", showsChevron: false) {
                            Toggle("Snooze", isOn: $snooze.isEnabled)
                                .labelsHidden()
                                .tint(SAColor.accent)
                        }
                    }

                    if snooze.isEnabled {
                        SACard {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Snooze length")
                                    .font(SAFont.headline(17))
                                    .foregroundStyle(SAColor.textPrimary)
                                Picker("Interval", selection: $snooze.intervalMinutes) {
                                    ForEach(SnoozeSettings.intervalOptions, id: \.self) { minutes in
                                        Text("\(minutes)m").tag(minutes)
                                    }
                                }
                                .pickerStyle(.segmented)
                            }
                        }

                        SACard {
                            VStack(alignment: .leading, spacing: 14) {
                                Toggle(isOn: $snooze.isUnlimited) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Unlimited snoozes")
                                            .font(SAFont.emphasis(16))
                                            .foregroundStyle(SAColor.textPrimary)
                                        Text("Keeps coming back until you actually get up")
                                            .font(SAFont.body(12))
                                            .foregroundStyle(SAColor.textSecondary)
                                    }
                                }
                                .tint(SAColor.accent)

                                if !snooze.isUnlimited {
                                    Divider().overlay(SAColor.separator)
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text("Maximum snoozes")
                                            .font(SAFont.emphasis(15))
                                            .foregroundStyle(SAColor.textPrimary)
                                        Picker("Max", selection: $snooze.maxCount) {
                                            ForEach(SnoozeSettings.countOptions, id: \.self) { count in
                                                Text("\(count)").tag(count)
                                            }
                                        }
                                        .pickerStyle(.segmented)
                                    }
                                }
                            }
                        }

                        SACard {
                            VStack(alignment: .leading, spacing: 14) {
                                Toggle(isOn: $snooze.shortenEachTime) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Shorten each time")
                                            .font(SAFont.emphasis(16))
                                            .foregroundStyle(SAColor.textPrimary)
                                        Text("Halves the gap on every snooze, so lie-ins get harder")
                                            .font(SAFont.body(12))
                                            .foregroundStyle(SAColor.textSecondary)
                                    }
                                }
                                .tint(SAColor.accent)

                                Divider().overlay(SAColor.separator)

                                Toggle(isOn: $snooze.requireMissionToSnooze) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Mission to snooze")
                                            .font(SAFont.emphasis(16))
                                            .foregroundStyle(SAColor.textPrimary)
                                        Text("Makes snoozing as much work as getting up")
                                            .font(SAFont.body(12))
                                            .foregroundStyle(SAColor.textSecondary)
                                    }
                                }
                                .tint(SAColor.accent)
                            }
                        }
                    }

                    Color.clear.frame(height: 24)
                }
                .padding(.horizontal, SAMetrics.screenPadding)
                .padding(.top, 8)
            }
        }
        .navigationTitle("Snooze")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Wake-up check

struct WakeUpCheckSettingsView: View {
    @Binding var check: WakeUpCheckSettings

    var body: some View {
        ZStack {
            SABackground()

            ScrollView {
                VStack(spacing: 16) {
                    SACard {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Stop yourself falling back asleep")
                                .font(SAFont.title(20))
                                .foregroundStyle(SAColor.textPrimary)
                            Text("A while after you turn the alarm off, the app checks that you are really up. Miss the countdown and the alarm comes straight back.")
                                .font(SAFont.body(14))
                                .foregroundStyle(SAColor.textSecondary)
                        }
                    }

                    SACard(padding: 0) {
                        SARow(icon: "eye.fill", title: "Wake-up check", showsChevron: false) {
                            Toggle("Wake-up check", isOn: $check.isEnabled)
                                .labelsHidden()
                                .tint(SAColor.accent)
                        }
                    }

                    if check.isEnabled {
                        SACard {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Check after")
                                    .font(SAFont.headline(17))
                                    .foregroundStyle(SAColor.textPrimary)
                                Picker("Delay", selection: $check.delayMinutes) {
                                    ForEach(WakeUpCheckSettings.delayOptions, id: \.self) { minutes in
                                        Text("\(minutes)m").tag(minutes)
                                    }
                                }
                                .pickerStyle(.segmented)

                                Divider().overlay(SAColor.separator)

                                Text("Time to confirm")
                                    .font(SAFont.headline(17))
                                    .foregroundStyle(SAColor.textPrimary)
                                Picker("Window", selection: $check.confirmWindowSeconds) {
                                    ForEach(WakeUpCheckSettings.windowOptions, id: \.self) { seconds in
                                        Text("\(seconds)s").tag(seconds)
                                    }
                                }
                                .pickerStyle(.segmented)
                            }
                        }

                        SACard {
                            VStack(alignment: .leading, spacing: 14) {
                                Toggle(isOn: $check.repeatUntilConfirmed) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Keep checking")
                                            .font(SAFont.emphasis(16))
                                            .foregroundStyle(SAColor.textPrimary)
                                        Text("Repeats the check until you confirm, rather than only once")
                                            .font(SAFont.body(12))
                                            .foregroundStyle(SAColor.textSecondary)
                                    }
                                }
                                .tint(SAColor.accent)

                                Divider().overlay(SAColor.separator)

                                Toggle(isOn: $check.requireMission) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Mission to confirm")
                                            .font(SAFont.emphasis(16))
                                            .foregroundStyle(SAColor.textPrimary)
                                        Text("Tapping \"I'm up\" is not enough on its own")
                                            .font(SAFont.body(12))
                                            .foregroundStyle(SAColor.textSecondary)
                                    }
                                }
                                .tint(SAColor.accent)
                            }
                        }
                    }

                    Color.clear.frame(height: 24)
                }
                .padding(.horizontal, SAMetrics.screenPadding)
                .padding(.top, 8)
            }
        }
        .navigationTitle("Wake-up check")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Pre-alarm

struct PreAlarmSettingsView: View {
    @Binding var preAlarm: PreAlarmSettings
    @StateObject private var audio = AlarmAudioEngine.shared

    var body: some View {
        ZStack {
            SABackground()

            ScrollView {
                VStack(spacing: 16) {
                    SACard {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Surface gently first")
                                .font(SAFont.title(20))
                                .foregroundStyle(SAColor.textPrimary)
                            Text("A quiet heads-up before the real alarm lifts you out of deep sleep, so the main alarm is less of a shock.")
                                .font(SAFont.body(14))
                                .foregroundStyle(SAColor.textSecondary)
                        }
                    }

                    SACard(padding: 0) {
                        SARow(icon: "bell.badge.fill", title: "Pre-alarm", showsChevron: false) {
                            Toggle("Pre-alarm", isOn: $preAlarm.isEnabled)
                                .labelsHidden()
                                .tint(SAColor.accent)
                        }
                    }

                    if preAlarm.isEnabled {
                        SACard {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("How long before")
                                    .font(SAFont.headline(17))
                                    .foregroundStyle(SAColor.textPrimary)
                                Picker("Minutes", selection: $preAlarm.minutesBefore) {
                                    ForEach(PreAlarmSettings.minuteOptions, id: \.self) { minutes in
                                        Text("\(minutes)m").tag(minutes)
                                    }
                                }
                                .pickerStyle(.menu)
                                .tint(SAColor.accent)

                                Divider().overlay(SAColor.separator)

                                Toggle("Play a sound", isOn: $preAlarm.playSound)
                                    .font(SAFont.emphasis(16))
                                    .tint(SAColor.accent)

                                if preAlarm.playSound {
                                    Text("Tone")
                                        .font(SAFont.emphasis(15))
                                        .foregroundStyle(SAColor.textPrimary)

                                    Picker("Tone", selection: $preAlarm.toneID) {
                                        ForEach(SoundCatalog.tones(in: .calm)) { tone in
                                            Text(tone.name).tag(tone.id)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .tint(SAColor.accent)

                                    Button {
                                        audio.preview(
                                            tone: SoundCatalog.tone(id: preAlarm.toneID),
                                            volume: preAlarm.volumeScale,
                                            seconds: 6
                                        )
                                    } label: {
                                        Label("Preview", systemImage: "play.fill")
                                    }
                                    .buttonStyle(PillButtonStyle())

                                    VStack(alignment: .leading, spacing: 6) {
                                        Text("Volume")
                                            .font(SAFont.emphasis(15))
                                            .foregroundStyle(SAColor.textPrimary)
                                        Slider(value: $preAlarm.volumeScale, in: 0.05...1.0)
                                            .tint(SAColor.accent)
                                    }
                                }
                            }
                        }
                    }

                    Color.clear.frame(height: 24)
                }
                .padding(.horizontal, SAMetrics.screenPadding)
                .padding(.top, 8)
            }
        }
        .navigationTitle("Pre-alarm")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { audio.stopPreview() }
    }
}

// MARK: - Voice briefing

struct VoiceBriefingSettingsView: View {
    @Binding var briefing: VoiceBriefingSettings
    let alarm: Alarm

    @EnvironmentObject private var store: AlarmStore

    var body: some View {
        ZStack {
            SABackground()

            ScrollView {
                VStack(spacing: 16) {
                    SACard {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Hear the morning")
                                .font(SAFont.title(20))
                                .foregroundStyle(SAColor.textPrimary)
                            Text("The app speaks the time and forecast over the alarm, so you know where you stand before your eyes are open.")
                                .font(SAFont.body(14))
                                .foregroundStyle(SAColor.textSecondary)
                        }
                    }

                    SACard(padding: 0) {
                        SARow(icon: "waveform.and.mic", title: "Voice briefing", showsChevron: false) {
                            Toggle("Voice briefing", isOn: $briefing.isEnabled)
                                .labelsHidden()
                                .tint(SAColor.accent)
                        }
                    }

                    if briefing.isEnabled {
                        SACard {
                            VStack(alignment: .leading, spacing: 12) {
                                Toggle("Time", isOn: $briefing.announceTime).tint(SAColor.accent)
                                Divider().overlay(SAColor.separator)
                                Toggle("Date", isOn: $briefing.announceDate).tint(SAColor.accent)
                                Divider().overlay(SAColor.separator)
                                Toggle("Weather", isOn: $briefing.announceWeather).tint(SAColor.accent)
                                Divider().overlay(SAColor.separator)
                                Toggle("Alarm name", isOn: $briefing.announceLabel).tint(SAColor.accent)
                            }
                            .font(SAFont.emphasis(16))
                        }

                        SACard {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Speed")
                                    .font(SAFont.emphasis(15))
                                    .foregroundStyle(SAColor.textPrimary)
                                Slider(value: $briefing.speechRate, in: 0.2...0.9)
                                    .tint(SAColor.accent)

                                Divider().overlay(SAColor.separator)

                                Text("Repeat every")
                                    .font(SAFont.emphasis(15))
                                    .foregroundStyle(SAColor.textPrimary)
                                Picker("Repeat", selection: $briefing.repeatIntervalSeconds) {
                                    ForEach(VoiceBriefingSettings.repeatOptions, id: \.self) { seconds in
                                        Text(seconds == 0 ? "Once" : "\(seconds)s").tag(seconds)
                                    }
                                }
                                .pickerStyle(.segmented)
                            }
                        }

                        SACard {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Preview")
                                    .font(SAFont.emphasis(15))
                                    .foregroundStyle(SAColor.textPrimary)
                                Text(previewText)
                                    .font(SAFont.body(14))
                                    .foregroundStyle(SAColor.textSecondary)
                                Button {
                                    var preview = alarm
                                    preview.voiceBriefing = briefing
                                    VoiceBriefing.shared.preview(for: preview, settings: store.settings)
                                } label: {
                                    Label("Play briefing", systemImage: "play.fill")
                                }
                                .buttonStyle(PillButtonStyle())
                            }
                        }
                    }

                    Color.clear.frame(height: 24)
                }
                .padding(.horizontal, SAMetrics.screenPadding)
                .padding(.top, 8)
            }
        }
        .navigationTitle("Voice briefing")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { VoiceBriefing.shared.stop() }
    }

    private var previewText: String {
        var preview = alarm
        preview.voiceBriefing = briefing
        let text = VoiceBriefing.briefingText(
            for: preview,
            settings: store.settings,
            weather: WeatherService.shared.snapshot
        )
        return text.isEmpty ? "Nothing selected." : "\"\(text)\""
    }
}

// MARK: - Permission help

struct PermissionHelpView: View {
    @EnvironmentObject private var coordinator: AlarmCoordinator
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                SABackground()

                ScrollView {
                    VStack(spacing: 16) {
                        SACard {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Permissions")
                                    .font(SAFont.title(21))
                                    .foregroundStyle(SAColor.textPrimary)
                                Text("An alarm app is only as reliable as the permissions it has. Everything here can be changed later in Settings.")
                                    .font(SAFont.body(14))
                                    .foregroundStyle(SAColor.textSecondary)
                            }
                        }

                        statusCard(
                            title: "System alarms",
                            detail: coordinator.systemBackend?.isSupported == true
                                ? "Lets alarms ring through Silent mode, Do Not Disturb and every Focus mode, and show on the Lock Screen."
                                : "Needs iOS 26 or later. On this device the app falls back to notifications and background audio.",
                            granted: coordinator.systemAlarmsAuthorized,
                            available: coordinator.systemBackend?.isSupported == true
                        )

                        statusCard(
                            title: "Notifications",
                            detail: "Used to sound the alarm and to deliver the wake-up check.",
                            granted: coordinator.notificationsAuthorized,
                            available: true
                        )

                        Button("Grant permissions") {
                            Task { await coordinator.requestAllAuthorizations() }
                        }
                        .buttonStyle(PrimaryButtonStyle())

                        Button("Open iPhone Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                        .buttonStyle(SecondaryButtonStyle())

                        Color.clear.frame(height: 20)
                    }
                    .padding(.horizontal, SAMetrics.screenPadding)
                    .padding(.top, 8)
                }
            }
            .navigationTitle("Permissions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(SAColor.accent)
                }
            }
            .task { await coordinator.refreshAuthorizationStatus() }
        }
    }

    private func statusCard(title: String, detail: String, granted: Bool, available: Bool) -> some View {
        SACard {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: !available ? "minus.circle.fill" : (granted ? "checkmark.circle.fill" : "xmark.circle.fill"))
                    .font(.system(size: 21, weight: .bold))
                    .foregroundStyle(!available ? SAColor.textTertiary : (granted ? SAColor.success : SAColor.danger))

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(SAFont.emphasis(16))
                        .foregroundStyle(SAColor.textPrimary)
                    Text(detail)
                        .font(SAFont.body(13))
                        .foregroundStyle(SAColor.textSecondary)
                }
            }
        }
    }
}
