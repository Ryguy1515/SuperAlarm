import SwiftUI

// MARK: - Container

/// Routes between the phases of a live alarm. Presented as a full-screen
/// cover that cannot be dismissed by gesture.
struct RingContainerView: View {
    @EnvironmentObject private var store: AlarmStore
    @EnvironmentObject private var runtime: AlarmRuntime

    var body: some View {
        ZStack {
            SAColor.background.ignoresSafeArea()

            switch runtime.phase {
            case .ringing:
                RingView()
            case .mission:
                missionRunner
            case .snoozed:
                SnoozeView()
            case .wakeCheckRinging:
                WakeCheckView()
            case .idle, .wakeCheckPending:
                Color.clear
            }
        }
        .overlay(alignment: .top) {
            if runtime.phase == .ringing || runtime.phase == .mission || runtime.phase == .wakeCheckRinging {
                VolumeLockBadge()
                    .padding(.top, 10)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: runtime.phase)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
    }

    @ViewBuilder
    private var missionRunner: some View {
        if let alarm = runtime.activeAlarm {
            MissionRunnerView(
                settings: alarm.mission,
                isPreview: false,
                startedAt: runtime.missionStartedAt ?? Date(),
                completedRounds: runtime.missionCompletedRounds,
                onComplete: { runtime.completeMission() },
                onGiveUp: {
                    // Giving up still stops the alarm — it is recorded as a
                    // failure but the user is never trapped.
                    runtime.registerMissionFailure()
                    runtime.completeMission()
                },
                onProgress: { runtime.noteMissionProgress(completedRounds: $0) }
            )
            // Keyed on the mission start so a resumed mission is built once,
            // from the persisted progress, rather than on every render.
            .id(runtime.missionStartedAt)
        } else {
            Color.clear
        }
    }
}

// MARK: - Volume lock badge

/// Tells the user the side buttons will not help. The hidden volume control
/// suppresses the system volume HUD, so this is the only feedback that a
/// button press was undone.
struct VolumeLockBadge: View {
    @ObservedObject private var audio = AlarmAudioEngine.shared
    @State private var flash = false

    var body: some View {
        if audio.isVolumeLocked {
            HStack(spacing: 6) {
                Image(systemName: flash ? "speaker.wave.3.fill" : "lock.fill")
                    .font(.system(size: 12, weight: .bold))
                Text(flash ? "Volume restored" : "Volume locked")
                    .font(SAFont.caption(12))
            }
            .foregroundStyle(flash ? SAColor.ink : SAColor.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(flash ? SAColor.accent : SAColor.surface))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(flash ? "Volume restored to full" : "Volume is locked; the side buttons will not lower it")
            .onChange(of: audio.volumeRestoreCount) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) { flash = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    Task { @MainActor in
                        withAnimation(.easeIn(duration: 0.3)) { flash = false }
                    }
                }
            }
        }
    }
}

// MARK: - Ringing

struct RingView: View {
    @EnvironmentObject private var store: AlarmStore
    @EnvironmentObject private var runtime: AlarmRuntime

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 20)

            VStack(spacing: 14) {
                Image(systemName: "alarm.fill")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(SAColor.accent)
                    .symbolEffect(.pulse, options: .repeating)

                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(clockString(context.date))
                        .font(SAFont.clock(76))
                        .foregroundStyle(SAColor.textPrimary)
                }

                Text(runtime.activeAlarm?.displayLabel ?? "Alarm")
                    .font(SAFont.headline(21))
                    .foregroundStyle(SAColor.textSecondary)

                if let memo = runtime.activeAlarm?.memo, !memo.isEmpty {
                    Text(memo)
                        .font(SAFont.body(16))
                        .foregroundStyle(SAColor.textPrimary)
                        .multilineTextAlignment(.center)
                        .padding(16)
                        .frame(maxWidth: .infinity)
                        .background(SAColor.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .padding(.horizontal, SAMetrics.screenPadding)
                        .padding(.top, 6)
                }
            }

            Spacer(minLength: 20)

            weatherLine

            Spacer(minLength: 20)

            VStack(spacing: 14) {
                if runtime.canSnooze {
                    Button {
                        HapticEngine.shared.impact(.medium)
                        runtime.snooze()
                    } label: {
                        VStack(spacing: 2) {
                            Text("Snooze")
                            if let interval = snoozeIntervalText {
                                Text(interval)
                                    .font(SAFont.caption(12))
                                    .foregroundStyle(SAColor.onAccent.opacity(0.7))
                            }
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle(height: 66))

                    if let remaining = runtime.snoozesRemainingText {
                        Text(remaining)
                            .font(SAFont.caption(12))
                            .foregroundStyle(SAColor.textTertiary)
                    }
                } else if runtime.activeAlarm?.snooze.isEnabled == true {
                    Text("No snoozes left")
                        .font(SAFont.caption(13))
                        .foregroundStyle(SAColor.textTertiary)
                        .padding(.bottom, 4)
                }

                SlideToUnlock(title: turnOffTitle) {
                    HapticEngine.shared.impact(.heavy)
                    runtime.beginTurnOff()
                }

                if let mission = runtime.activeAlarm?.mission, mission.type != .none {
                    Label(
                        "\(mission.type.displayName) mission to turn off",
                        systemImage: mission.type.symbolName
                    )
                    .font(SAFont.caption(12))
                    .foregroundStyle(SAColor.textTertiary)
                }
            }
            .padding(.horizontal, SAMetrics.screenPadding)
            .padding(.bottom, 26)
        }
    }

    private var turnOffTitle: String {
        guard let mission = runtime.activeAlarm?.mission, mission.type != .none else {
            return "Slide to turn off"
        }
        return "Slide to start mission"
    }

    private var snoozeIntervalText: String? {
        guard let alarm = runtime.activeAlarm, alarm.snooze.isEnabled else { return nil }
        let minutes = Int(alarm.snooze.interval(forSnoozeIndex: runtime.snoozeCount) / 60)
        return "\(minutes) min"
    }

    private func clockString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = store.settings.use24HourClock ? "HH:mm" : "h:mm"
        return formatter.string(from: date)
    }

    @ViewBuilder
    private var weatherLine: some View {
        if store.settings.showWeather, let snapshot = WeatherService.shared.snapshot {
            HStack(spacing: 10) {
                Image(systemName: snapshot.symbolName)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(SAColor.accent)
                Text("\(snapshot.temperature(in: store.settings.temperatureUnit))\(store.settings.temperatureUnit.symbol)")
                    .font(SAFont.headline(18))
                    .foregroundStyle(SAColor.textPrimary)
                Text(snapshot.summary)
                    .font(SAFont.body(15))
                    .foregroundStyle(SAColor.textSecondary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(Capsule().fill(SAColor.surface))
        }
    }
}

// MARK: - Slide to unlock

/// Deliberate friction on the turn-off control: a tap cannot do it, so it
/// cannot happen by accident while half asleep.
struct SlideToUnlock: View {
    let title: String
    var onUnlock: () -> Void

    @State private var offset: CGFloat = 0
    @State private var isDragging = false
    @State private var shimmer: CGFloat = -1

    private let thumbSize: CGFloat = 56
    private let trackHeight: CGFloat = 68

    var body: some View {
        GeometryReader { geometry in
            let maxOffset = max(0, geometry.size.width - thumbSize - 12)
            let progress = maxOffset > 0 ? offset / maxOffset : 0

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .fill(SAColor.surface)

                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .fill(SAColor.accent.opacity(0.18))
                    .frame(width: offset + thumbSize + 6)

                Text(title)
                    .font(SAFont.emphasis(17))
                    .foregroundStyle(SAColor.textSecondary.opacity(1 - progress * 0.8))
                    .frame(maxWidth: .infinity)
                    .overlay {
                        // Subtle sweep so the control reads as draggable.
                        LinearGradient(
                            colors: [.clear, SAColor.accent.opacity(0.9), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: 90)
                        .offset(x: shimmer * geometry.size.width)
                        .mask {
                            Text(title)
                                .font(SAFont.emphasis(17))
                                .frame(maxWidth: .infinity)
                        }
                        .allowsHitTesting(false)
                    }

                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.white)
                    .frame(width: thumbSize, height: thumbSize)
                    .overlay {
                        Image(systemName: "chevron.right.2")
                            .font(.system(size: 17, weight: .black))
                            .foregroundStyle(SAColor.ink)
                    }
                    .offset(x: offset + 6)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                isDragging = true
                                offset = min(max(0, value.translation.width), maxOffset)
                            }
                            .onEnded { _ in
                                isDragging = false
                                if offset >= maxOffset * 0.88 {
                                    offset = maxOffset
                                    onUnlock()
                                } else {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                        offset = 0
                                    }
                                }
                            }
                    )
            }
            .frame(height: trackHeight)
        }
        .frame(height: trackHeight)
        .onAppear {
            withAnimation(.linear(duration: 2.2).repeatForever(autoreverses: false)) {
                shimmer = 1.4
            }
        }
        .accessibilityElement()
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onUnlock() }
    }
}

// MARK: - Snoozed

struct SnoozeView: View {
    @EnvironmentObject private var store: AlarmStore
    @EnvironmentObject private var runtime: AlarmRuntime

    var body: some View {
        VStack(spacing: 26) {
            Spacer()

            Image(systemName: "zzz")
                .font(.system(size: 54, weight: .bold))
                .foregroundStyle(SAColor.accent)

            Text("Snoozing")
                .font(SAFont.title(28))
                .foregroundStyle(SAColor.textPrimary)

            if let ends = runtime.snoozeEndsAt {
                VStack(spacing: 6) {
                    Text(countdown(to: ends))
                        .font(SAFont.clock(56))
                        .foregroundStyle(SAColor.accent)
                    Text("until it rings again")
                        .font(SAFont.body(15))
                        .foregroundStyle(SAColor.textSecondary)
                }
            }

            Text("Snoozed \(runtime.snoozeCount)×")
                .font(SAFont.caption(13))
                .foregroundStyle(SAColor.textTertiary)

            Spacer()

            Button("Wake up now") {
                HapticEngine.shared.impact(.medium)
                runtime.wakeNow()
            }
            .buttonStyle(SecondaryButtonStyle())
            .padding(.horizontal, SAMetrics.screenPadding)
            .padding(.bottom, 30)
        }
    }

    private func countdown(to date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(runtime.now)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

// MARK: - Wake-up check

struct WakeCheckView: View {
    @EnvironmentObject private var runtime: AlarmRuntime

    var body: some View {
        VStack(spacing: 26) {
            Spacer(minLength: 10)

            Text("Are you sure you're awake?")
                .font(SAFont.title(28))
                .foregroundStyle(SAColor.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            Text("Please confirm you're awake by tapping the button below. If you don't respond within \(runtime.activeAlarm?.wakeUpCheck.confirmWindowSeconds ?? 100) seconds, the alarm will ring again.")
                .font(SAFont.body(16))
                .foregroundStyle(SAColor.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)

            ZStack {
                SAProgressRing(progress: runtime.wakeCheckProgress, lineWidth: 12)
                    .frame(width: 210, height: 210)

                Text("\(runtime.wakeCheckSecondsRemaining)")
                    .font(SAFont.clock(64))
                    .foregroundStyle(SAColor.textPrimary)
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.snappy, value: runtime.wakeCheckSecondsRemaining)
            }

            Spacer(minLength: 10)

            Button("I'm up") {
                HapticEngine.shared.success()
                runtime.confirmAwake()
            }
            .buttonStyle(PrimaryButtonStyle(height: 66))
            .padding(.horizontal, SAMetrics.screenPadding)
            .padding(.bottom, 30)
        }
    }
}
