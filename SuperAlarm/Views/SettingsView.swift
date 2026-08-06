import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var store: AlarmStore
    @EnvironmentObject private var coordinator: AlarmCoordinator
    @EnvironmentObject private var runtime: AlarmRuntime

    @State private var showingPermissions = false
    @State private var showingPaywall = false
    @State private var showingResetConfirm = false

    var body: some View {
        NavigationStack {
            ZStack {
                SABackground()

                ScrollView {
                    VStack(spacing: 18) {
                        reliabilityCard
                        appearanceSection
                        defaultsSection
                        guardsSection
                        backgroundSection
                        weatherSection
                        aboutSection
                        Color.clear.frame(height: 60)
                    }
                    .padding(.horizontal, SAMetrics.screenPadding)
                    .padding(.top, 8)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showingPermissions) {
                PermissionHelpView().environmentObject(coordinator)
            }
            .sheet(isPresented: $showingPaywall) {
                PaywallView().environmentObject(store)
            }
            .confirmationDialog(
                "Reset everything?",
                isPresented: $showingResetConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete all alarms and history", role: .destructive) {
                    store.deleteAll()
                    store.clearHistory()
                    Task { await coordinator.cancelEverything() }
                }
            } message: {
                Text("This removes every alarm, all history, and cancels all scheduled alerts.")
            }
            .onChange(of: store.settings.hapticFeedback) { _, newValue in
                HapticEngine.shared.uiFeedbackEnabled = newValue
            }
        }
    }

    // MARK: Reliability

    private var reliabilityCard: some View {
        Button {
            showingPermissions = true
        } label: {
            SACard(background: coordinator.usesSystemAlarms ? SAColor.success.opacity(0.16) : SAColor.surface) {
                HStack(spacing: 14) {
                    Image(systemName: coordinator.usesSystemAlarms ? "checkmark.shield.fill" : "shield.lefthalf.filled")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(coordinator.usesSystemAlarms ? SAColor.success : SAColor.warning)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(coordinator.usesSystemAlarms ? "System alarms active" : "Notification fallback")
                            .font(SAFont.emphasis(16))
                            .foregroundStyle(SAColor.textPrimary)
                        Text(coordinator.usesSystemAlarms
                             ? "Alarms ring through Silent mode, Do Not Disturb and Focus."
                             : "This device cannot use system alarms, so notifications and background audio are used instead.")
                            .font(SAFont.body(12))
                            .foregroundStyle(SAColor.textSecondary)
                    }

                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(SAColor.textTertiary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: Appearance

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SASectionHeader("Appearance")

            VStack(spacing: 0) {
                SARow(icon: "paintbrush.fill", title: "Theme", showsChevron: false) {
                    Picker("", selection: $store.settings.theme) {
                        ForEach(AppTheme.allCases) { theme in
                            Text(theme.displayName).tag(theme)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(SAColor.accent)
                }

                SADivider()

                SARow(icon: "clock.fill", title: "24-hour clock", showsChevron: false) {
                    Toggle("", isOn: $store.settings.use24HourClock)
                        .labelsHidden()
                        .tint(SAColor.accent)
                }

                SADivider()

                SARow(icon: "hand.tap.fill", title: "Haptic feedback", showsChevron: false) {
                    Toggle("", isOn: $store.settings.hapticFeedback)
                        .labelsHidden()
                        .tint(SAColor.accent)
                }
            }
            .saGroupedCard()
        }
    }

    // MARK: Defaults

    private var defaultsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SASectionHeader("Defaults for new alarms", subtitle: "Applied whenever you create an alarm")

            VStack(spacing: 0) {
                NavigationLink {
                    SoundPickerView(sound: $store.settings.defaultSound)
                } label: {
                    SARow(
                        icon: "speaker.wave.3.fill",
                        title: "Sound",
                        subtitle: ToneResolver.displayName(for: store.settings.defaultSound.toneID)
                    )
                }

                SADivider()

                NavigationLink {
                    MissionPickerView(mission: $store.settings.defaultMission)
                        .environmentObject(store)
                } label: {
                    SARow(
                        icon: store.settings.defaultMission.type.symbolName,
                        title: "Mission",
                        subtitle: store.settings.defaultMission.summary
                    )
                }

                SADivider()

                NavigationLink {
                    SnoozeSettingsView(snooze: $store.settings.defaultSnooze)
                } label: {
                    SARow(icon: "zzz", title: "Snooze", subtitle: store.settings.defaultSnooze.summary)
                }

                SADivider()

                NavigationLink {
                    WakeUpCheckSettingsView(check: $store.settings.defaultWakeUpCheck)
                } label: {
                    SARow(
                        icon: "eye.fill",
                        title: "Wake-up check",
                        subtitle: store.settings.defaultWakeUpCheck.summary
                    )
                }
            }
            .saGroupedCard()
        }
    }

    // MARK: Guards

    private var guardsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SASectionHeader("While the alarm rings")

            VStack(spacing: 0) {
                SARow(
                    icon: "speaker.slash.fill",
                    title: "Lock the volume",
                    subtitle: "Restores the level if the side buttons lower it",
                    showsChevron: false
                ) {
                    Toggle("", isOn: $store.settings.lockVolumeWhileRinging)
                        .labelsHidden()
                        .tint(SAColor.accent)
                }

                SADivider()

                SARow(
                    icon: "lock.iphone",
                    title: "Keep the alarm on screen",
                    subtitle: "Puts the alarm back in front whenever you return to the app",
                    showsChevron: false
                ) {
                    Toggle("", isOn: $store.settings.deletionGuard)
                        .labelsHidden()
                        .tint(SAColor.accent)
                }
            }
            .saGroupedCard()

            Text("iOS does not let any third-party app block itself from being deleted or stop the phone being powered off. What keeps you honest instead is that alarms are owned by the system, so they keep firing even if the app is closed — and a follow-up alarm is armed every time one starts, cancelled only once a mission is actually completed.")
                .font(SAFont.body(12))
                .foregroundStyle(SAColor.textTertiary)
                .padding(.horizontal, 4)
        }
    }

    // MARK: Background

    private var backgroundSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SASectionHeader("Reliability", subtitle: "Trade battery for certainty")

            VStack(spacing: 0) {
                SARow(
                    icon: "battery.100.bolt",
                    title: "Background keep-alive",
                    subtitle: coordinator.usesSystemAlarms
                        ? "Not needed — system alarms are handling this"
                        : "Keeps the app running near an alarm so it can ring",
                    showsChevron: false
                ) {
                    Toggle("", isOn: $store.settings.backgroundKeepAlive)
                        .labelsHidden()
                        .tint(SAColor.accent)
                        .disabled(coordinator.usesSystemAlarms)
                }

                if store.settings.backgroundKeepAlive && !coordinator.usesSystemAlarms {
                    SADivider()
                    SARow(icon: "clock.arrow.circlepath", title: "Start before alarm", showsChevron: false) {
                        Picker("", selection: $store.settings.keepAliveWindowHours) {
                            ForEach([2, 4, 8, 12, 24], id: \.self) { hours in
                                Text("\(hours)h").tag(hours)
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(SAColor.accent)
                    }
                }

                SADivider()

                SARow(
                    icon: "bell.badge",
                    title: "Extra notification backup",
                    subtitle: "Also rings via notifications. May double up with system alarms.",
                    showsChevron: false
                ) {
                    Toggle("", isOn: $store.settings.redundantNotificationBackup)
                        .labelsHidden()
                        .tint(SAColor.accent)
                }
            }
            .saGroupedCard()
        }
    }

    // MARK: Weather

    private var weatherSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SASectionHeader("Weather")

            VStack(spacing: 0) {
                SARow(icon: "cloud.sun.fill", title: "Show weather", showsChevron: false) {
                    Toggle("", isOn: $store.settings.showWeather)
                        .labelsHidden()
                        .tint(SAColor.accent)
                }

                if store.settings.showWeather {
                    SADivider()
                    SARow(icon: "thermometer.medium", title: "Units", showsChevron: false) {
                        Picker("", selection: $store.settings.temperatureUnit) {
                            ForEach(TemperatureUnit.allCases) { unit in
                                Text(unit.symbol).tag(unit)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 110)
                    }
                }
            }
            .saGroupedCard()
        }
    }

    // MARK: About

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SASectionHeader("About")

            VStack(spacing: 0) {
                Button { showingPaywall = true } label: {
                    SARow(
                        icon: "crown.fill",
                        title: "Membership",
                        subtitle: store.settings.isPro ? "All features unlocked" : "Free tier"
                    )
                }

                SADivider()

                NavigationLink {
                    DiagnosticsView()
                        .environmentObject(store)
                        .environmentObject(coordinator)
                        .environmentObject(runtime)
                } label: {
                    SARow(icon: "stethoscope", title: "Diagnostics", subtitle: "Check that alarms are really scheduled")
                }

                SADivider()

                Button { showingPermissions = true } label: {
                    SARow(icon: "checkmark.shield.fill", title: "Permissions")
                }

                SADivider()

                Button(role: .destructive) { showingResetConfirm = true } label: {
                    SARow(
                        icon: "trash.fill",
                        title: "Reset everything",
                        iconTint: SAColor.danger,
                        showsChevron: false
                    )
                }
            }
            .saGroupedCard()

            Text("SuperAlarm · version \(Bundle.appVersion)")
                .font(SAFont.caption(12))
                .foregroundStyle(SAColor.textTertiary)
                .frame(maxWidth: .infinity)
                .padding(.top, 6)
        }
    }
}

// MARK: - Diagnostics

/// Surfaces the state that actually determines whether an alarm will fire.
/// Being able to check this at 11pm is the difference between trusting the app
/// and hoping.
struct DiagnosticsView: View {
    @EnvironmentObject private var store: AlarmStore
    @EnvironmentObject private var coordinator: AlarmCoordinator
    @EnvironmentObject private var runtime: AlarmRuntime

    @State private var missingTones: [String] = []

    var body: some View {
        ZStack {
            SABackground()

            ScrollView {
                VStack(spacing: 16) {
                    SACard {
                        // Built from data rather than as 17 literal children:
                        // ViewBuilder only has overloads up to 10.
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(diagnosticRows.enumerated()), id: \.offset) { index, item in
                                row(item.title, item.value)
                                if index < diagnosticRows.count - 1 {
                                    SADivider(inset: 0)
                                }
                            }
                        }
                    }

                    if !missingTones.isEmpty {
                        SACard(background: SAColor.danger.opacity(0.15)) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Missing audio files")
                                    .font(SAFont.emphasis(15))
                                    .foregroundStyle(SAColor.textPrimary)
                                Text(missingTones.joined(separator: ", "))
                                    .font(SAFont.body(12))
                                    .foregroundStyle(SAColor.textSecondary)
                            }
                        }
                    }

                    if let next = store.nextAlarm {
                        SACard {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Next alarm")
                                    .font(SAFont.emphasis(15))
                                    .foregroundStyle(SAColor.textPrimary)
                                Text(next.alarm.displayLabel)
                                    .font(SAFont.body(14))
                                    .foregroundStyle(SAColor.textSecondary)
                                Text(fullDateString(next.date))
                                    .font(SAFont.body(14))
                                    .foregroundStyle(SAColor.accent)
                            }
                        }
                    }

                    Button("Rebuild schedule now") {
                        Task { await coordinator.rebuildNow(alarms: store.alarms, settings: store.settings) }
                    }
                    .buttonStyle(SecondaryButtonStyle())

                    Button("Force stop any active alarm") {
                        runtime.forceStop()
                    }
                    .buttonStyle(SecondaryButtonStyle())

                    Color.clear.frame(height: 30)
                }
                .padding(.horizontal, SAMetrics.screenPadding)
                .padding(.top, 8)
            }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            missingTones = SoundBundle.missingTones()
            await coordinator.refreshAuthorizationStatus()
        }
    }

    private var diagnosticRows: [(title: String, value: String)] {
        [
            ("Alarm mechanism", coordinator.systemBackendName),
            ("System alarms authorised", coordinator.systemAlarmsAuthorized ? "Yes" : "No"),
            ("Notifications authorised", coordinator.notificationsAuthorized ? "Yes" : "No"),
            ("Pending notifications", "\(coordinator.pendingNotificationCount)"),
            ("Enabled alarms", "\(store.enabledAlarms.count)"),
            ("Last rebuild", coordinator.lastRebuildAt.map(timeString) ?? "Never"),
            ("Shared container", StorageLocation.hasSharedContainer ? "Yes" : "No (widget data unavailable)"),
            ("Runtime phase", runtime.phase.rawValue),
            ("Bundled sounds", missingTones.isEmpty ? "All present" : "\(missingTones.count) missing"),
        ]
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(SAFont.body(14))
                .foregroundStyle(SAColor.textSecondary)
            Spacer()
            Text(value)
                .font(SAFont.emphasis(14))
                .foregroundStyle(SAColor.textPrimary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    private func fullDateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE d MMMM, HH:mm"
        return formatter.string(from: date)
    }
}

extension Bundle {
    static var appVersion: String {
        let version = main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}
