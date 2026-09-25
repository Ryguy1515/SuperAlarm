import SwiftUI
import UIKit

struct OnboardingView: View {
    @EnvironmentObject private var store: AlarmStore
    @EnvironmentObject private var coordinator: AlarmCoordinator

    @State private var step = 0
    @State private var firstAlarm = Alarm(hour: 7, minute: 0)
    @State private var isRequestingPermissions = false

    private let stepCount = 4

    var body: some View {
        ZStack {
            SABackground()

            VStack(spacing: 0) {
                progressBar

                TabView(selection: $step) {
                    welcomeStep.tag(0)
                    missionsStep.tag(1)
                    permissionsStep.tag(2)
                    firstAlarmStep.tag(3)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                controls
            }
        }
    }

    private var progressBar: some View {
        HStack(spacing: 6) {
            ForEach(0..<stepCount, id: \.self) { index in
                Capsule()
                    .fill(index <= step ? SAColor.accent : SAColor.separator)
                    .frame(height: 4)
            }
        }
        .padding(.horizontal, SAMetrics.screenPadding)
        .padding(.top, 16)
        .animation(.easeOut(duration: 0.25), value: step)
    }

    // MARK: Steps

    private var welcomeStep: some View {
        stepScaffold(
            icon: "alarm.waves.left.and.right.fill",
            title: "Your last alarm clock",
            body: "SuperAlarm is built for people who turn alarms off in their sleep. It rings loud, it rings through Silent mode, and it does not stop until you have proved you are actually awake."
        ) {
            VStack(spacing: 12) {
                featureRow("speaker.wave.3.fill", "Extra loud", "Sirens and klaxons that get through a pillow, with the volume forced up.")
                featureRow("figure.walk", "Wake-up missions", "Solve, scan, walk or shake to turn it off.")
                featureRow("eye.fill", "Wake-up check", "Comes back if you turn it off and roll over.")
            }
        }
    }

    private var missionsStep: some View {
        stepScaffold(
            icon: "square.grid.2x2.fill",
            title: "Complete a mission to turn off the alarm",
            body: "Pick a mission that gets you out of bed. The alarm keeps going until it is done — and follow-up alarms are armed the whole time, so silencing the phone or closing the app will not save you."
        ) {
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                spacing: 10
            ) {
                ForEach(MissionType.selectable.prefix(6)) { type in
                    HStack(spacing: 9) {
                        Image(systemName: type.symbolName)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(SAColor.accent)
                            .frame(width: 22)
                        Text(type.displayName)
                            .font(SAFont.body(13))
                            .foregroundStyle(SAColor.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 11)
                    .padding(.horizontal, 12)
                    .background(SAColor.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }

            Text("There are \(MissionType.selectable.count) in total, and every one has an escape hatch if it will not recognise you.")
                .font(SAFont.body(12))
                .foregroundStyle(SAColor.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.top, 10)
        }
    }

    private var permissionsStep: some View {
        stepScaffold(
            icon: "checkmark.shield.fill",
            title: coordinator.systemBackend?.isSupported == true ? "Two quick permissions" : "One permission to grant",
            body: coordinator.systemBackend?.isSupported == true
                ? "SuperAlarm uses the system alarm service, the same one the built-in Clock uses. That is what lets it ring through Silent mode, Do Not Disturb and every Focus mode — even if the app is closed or the phone has been restarted."
                : "This device does not support system alarms, so SuperAlarm needs notification permission and will keep itself running in the background near an alarm."
        ) {
            VStack(spacing: 12) {
                permissionStatus(
                    "System alarms",
                    granted: coordinator.systemAlarmsAuthorized,
                    available: coordinator.systemBackend?.isSupported == true
                )
                permissionStatus("Notifications", granted: coordinator.notificationsAuthorized, available: true)

                if coordinator.systemAlarmsDenied {
                    // iOS answers a repeated request silently; the only way
                    // back is Settings.
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Text("Open iPhone Settings to allow alarms")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .padding(.top, 6)
                } else {
                    Button {
                        Task {
                            isRequestingPermissions = true
                            await coordinator.requestAllAuthorizations()
                            isRequestingPermissions = false
                        }
                    } label: {
                        Text(isRequestingPermissions ? "Asking…" : "Allow alarms")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(isRequestingPermissions)
                    .padding(.top, 6)
                }

                Text("Camera, motion and location are only asked for later, and only if you pick a mission that needs them.")
                    .font(SAFont.body(12))
                    .foregroundStyle(SAColor.textTertiary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var firstAlarmStep: some View {
        stepScaffold(
            icon: "alarm.fill",
            title: "Set your first alarm",
            body: "You can change everything about it later."
        ) {
            VStack(spacing: 14) {
                DatePicker("", selection: firstAlarmTimeBinding, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.wheel)
                    .labelsHidden()

                HStack(spacing: 6) {
                    ForEach(Weekday.orderedForLocale()) { day in
                        let selected = firstAlarm.repeatDays.contains(day)
                        Button {
                            HapticEngine.shared.selection()
                            if selected { firstAlarm.repeatDays.remove(day) } else { firstAlarm.repeatDays.insert(day) }
                            firstAlarm.repeatMode = firstAlarm.repeatDays.isEmpty ? .once : .weekly
                        } label: {
                            Text(day.minimalName)
                                .font(SAFont.caption(13))
                                .foregroundStyle(selected ? SAColor.onAccent : SAColor.textSecondary)
                                .frame(maxWidth: .infinity)
                                .frame(minHeight: 40)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(selected ? SAColor.accent : SAColor.surface)
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(day.fullName)
                        .accessibilityAddTraits(selected ? [.isSelected] : [])
                    }
                }
            }
        }
    }

    private var firstAlarmTimeBinding: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(
                    bySettingHour: firstAlarm.hour, minute: firstAlarm.minute, second: 0, of: Date()
                ) ?? Date()
            },
            set: { newValue in
                let components = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                firstAlarm.hour = components.hour ?? 7
                firstAlarm.minute = components.minute ?? 0
            }
        )
    }

    // MARK: Scaffolding

    @ViewBuilder
    private func stepScaffold<Content: View>(
        icon: String,
        title: String,
        body: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.system(size: 46, weight: .bold))
                    .foregroundStyle(SAColor.accent)
                    .padding(.top, 30)

                Text(title)
                    .font(SAFont.display(31))
                    .foregroundStyle(SAColor.textPrimary)
                    .multilineTextAlignment(.center)

                Text(body)
                    .font(SAFont.body(15))
                    .foregroundStyle(SAColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 6)

                content()
                    .padding(.top, 8)

                Color.clear.frame(height: 20)
            }
            .padding(.horizontal, SAMetrics.screenPadding)
        }
    }

    private func featureRow(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(SAColor.accent)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(SAFont.emphasis(16))
                    .foregroundStyle(SAColor.textPrimary)
                Text(detail)
                    .font(SAFont.body(13))
                    .foregroundStyle(SAColor.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(SAColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func permissionStatus(_ title: String, granted: Bool, available: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: !available ? "minus.circle.fill" : (granted ? "checkmark.circle.fill" : "circle"))
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(!available ? SAColor.textTertiary : (granted ? SAColor.success : SAColor.textTertiary))
            Text(title)
                .font(SAFont.emphasis(16))
                .foregroundStyle(SAColor.textPrimary)
            Spacer()
            Text(!available ? "Not on this device" : (granted ? "Allowed" : "Not yet"))
                .font(SAFont.body(13))
                .foregroundStyle(SAColor.textSecondary)
        }
        .padding(14)
        .background(SAColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 10) {
            Button(step == stepCount - 1 ? "Create alarm" : "Continue") {
                advance()
            }
            .buttonStyle(PrimaryButtonStyle())

            if step < stepCount - 1 {
                Button("Skip") { finish(createAlarm: false) }
                    .font(SAFont.body(15))
                    .foregroundStyle(SAColor.textTertiary)
            } else {
                Button("Skip for now") { finish(createAlarm: false) }
                    .font(SAFont.body(15))
                    .foregroundStyle(SAColor.textTertiary)
            }
        }
        .padding(.horizontal, SAMetrics.screenPadding)
        .padding(.bottom, 18)
    }

    private func advance() {
        HapticEngine.shared.impact(.light)
        if step < stepCount - 1 {
            withAnimation { step += 1 }
        } else {
            finish(createAlarm: true)
        }
    }

    private func finish(createAlarm: Bool) {
        if createAlarm {
            var alarm = firstAlarm
            store.settings.applyDefaults(to: &alarm)
            alarm.isEnabled = true
            store.add(alarm)
        }
        store.settings.hasCompletedOnboarding = true
        Task {
            await coordinator.rebuildNow(alarms: store.alarms, settings: store.settings)
        }
    }
}
