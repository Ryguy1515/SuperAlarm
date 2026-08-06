import SwiftUI

/// One-tap countdown alarm for naps and short reminders.
struct QuickAlarmView: View {
    @EnvironmentObject private var store: AlarmStore
    @Environment(\.dismiss) private var dismiss

    @State private var minutes: Int = 20
    @State private var label = ""
    @State private var useMission = false

    private let presets = [5, 10, 15, 20, 30, 45, 60, 90]
    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                SABackground()

                ScrollView {
                    VStack(spacing: 18) {
                        header
                        presetGrid
                        fineTune
                        options
                        Color.clear.frame(height: 90)
                    }
                    .padding(.horizontal, SAMetrics.screenPadding)
                    .padding(.top, 8)
                }

                VStack {
                    Spacer()
                    Button("Set alarm for \(ringsAtText)") { createAlarm() }
                        .buttonStyle(PrimaryButtonStyle())
                        .padding(.horizontal, SAMetrics.screenPadding)
                        .padding(.bottom, 14)
                        .background(
                            LinearGradient(
                                colors: [SAColor.background.opacity(0), SAColor.background],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            .ignoresSafeArea()
                        )
                }
            }
            .navigationTitle("Quick alarm")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(SAColor.textSecondary)
                }
            }
        }
    }

    private var header: some View {
        SACard {
            VStack(spacing: 6) {
                Text("\(minutes)")
                    .font(SAFont.display(64))
                    .foregroundStyle(SAColor.accent)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: minutes)
                Text(minutes == 1 ? "minute from now" : "minutes from now")
                    .font(SAFont.body(15))
                    .foregroundStyle(SAColor.textSecondary)
                Text("Rings at \(ringsAtText)")
                    .font(SAFont.emphasis(16))
                    .foregroundStyle(SAColor.textPrimary)
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var ringsAtText: String {
        let target = Date().addingTimeInterval(TimeInterval(minutes * 60))
        let formatter = DateFormatter()
        formatter.dateFormat = store.settings.use24HourClock ? "HH:mm" : "h:mm a"
        return formatter.string(from: target)
    }

    private var presetGrid: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(presets, id: \.self) { preset in
                Button {
                    HapticEngine.shared.selection()
                    minutes = preset
                } label: {
                    Text("\(preset)m")
                        .font(SAFont.emphasis(16))
                        .foregroundStyle(minutes == preset ? SAColor.onAccent : SAColor.textPrimary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(
                            RoundedRectangle(cornerRadius: 15, style: .continuous)
                                .fill(minutes == preset ? SAColor.accent : SAColor.surface)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var fineTune: some View {
        SACard {
            SABigStepper(
                value: $minutes,
                range: 1...720,
                step: 1,
                caption: "Fine tune"
            )
            .frame(maxWidth: .infinity)
        }
    }

    private var options: some View {
        SACard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "textformat")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(SAColor.accent)
                        .frame(width: 22)
                    TextField("What is this for?", text: $label)
                        .font(SAFont.body(16))
                        .foregroundStyle(SAColor.textPrimary)
                }

                Divider().overlay(SAColor.separator)

                Toggle(isOn: $useMission) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Use my default mission")
                            .font(SAFont.emphasis(16))
                            .foregroundStyle(SAColor.textPrimary)
                        Text(store.settings.defaultMission.type == .none
                             ? "No default mission is set"
                             : store.settings.defaultMission.summary)
                            .font(SAFont.body(12))
                            .foregroundStyle(SAColor.textSecondary)
                    }
                }
                .tint(SAColor.accent)
                .disabled(store.settings.defaultMission.type == .none)
            }
        }
    }

    private func createAlarm() {
        var alarm = Alarm.quick(
            minutesFromNow: minutes,
            label: label.isEmpty ? "Quick alarm" : label
        )
        alarm.sound = store.settings.defaultSound
        if useMission, store.settings.defaultMission.isReady {
            alarm.mission = store.settings.defaultMission
        }
        store.add(alarm)
        HapticEngine.shared.success()
        dismiss()
    }
}
