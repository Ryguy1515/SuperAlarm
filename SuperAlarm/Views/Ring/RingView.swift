import SwiftUI
import UIKit

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
        // A propped-up phone counting push-ups must not auto-lock halfway.
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
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
                // Running out of time is not a way out: back to ringing.
                onTimeout: { runtime.cancelMission() },
                onProgress: { runtime.noteMissionProgress(completedRounds: $0) },
                onFailure: { runtime.registerMissionFailure() }
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
    @EnvironmentObject private var runtime: AlarmRuntime
    @State private var flash = false

    private var lockAvailable: Bool { SystemVolume.shared.isReady }

    var body: some View {
        if audio.isVolumeLocked {
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: flash ? "speaker.wave.3.fill" : (lockAvailable ? "lock.fill" : "lock.open.fill"))
                        .font(.system(size: 13, weight: .bold))
                    Text(flash ? "Volume restored" : (lockAvailable ? "Volume locked" : "Volume lock unavailable"))
                        .font(SAFont.caption(14))
                }
                .foregroundStyle(flash ? SAColor.onAccent : SAColor.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(flash ? SAColor.accent : SAColor.surface))

                if runtime.phase == .ringing {
                    Text("Leaving the app won't stop it")
                        .font(SAFont.caption(13))
                        .foregroundStyle(SAColor.textSecondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(flash
                ? "Volume restored to full"
                : (lockAvailable ? "Volume is locked; pressing the side buttons snaps it back up" : "Volume lock unavailable on this phone"))
            .onChange(of: audio.volumeRestoreCount) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) { flash = true }
                AccessibilityNotification.Announcement("Volume restored").post()
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 20)

            VStack(spacing: 14) {
                Image(systemName: "alarm.fill")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(SAColor.accent)
                    .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
                    .accessibilityHidden(true)

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
                    // Muted on purpose: the way off this screen is the
                    // slider, and snoozing must not look like the main event.
                    Button {
                        HapticEngine.shared.impact(.medium)
                        runtime.snooze()
                    } label: {
                        VStack(spacing: 2) {
                            Text("Snooze")
                            if let interval = snoozeIntervalText {
                                Text(interval)
                                    .font(SAFont.caption(13))
                                    .foregroundStyle(SAColor.textSecondary)
                            }
                        }
                    }
                    .buttonStyle(SecondaryButtonStyle(height: 66))

                    if let remaining = runtime.snoozesRemainingText {
                        Text(remaining)
                            .font(SAFont.caption(13))
                            .foregroundStyle(SAColor.textSecondary)
                    }
                } else if runtime.activeAlarm?.snooze.isEnabled == true {
                    Text("No snoozes left")
                        .font(SAFont.caption(14))
                        .foregroundStyle(SAColor.textSecondary)
                        .padding(.bottom, 4)
                }

                SlideToUnlock(title: turnOffTitle) {
                    HapticEngine.shared.impact(.heavy)
                    runtime.beginTurnOff()
                }

                if let mission = runtime.activeAlarm?.mission, mission.type != .none {
                    Label(
                        "Complete the \(mission.type.sentenceNoun) mission to turn off",
                        systemImage: mission.type.symbolName
                    )
                    .font(SAFont.caption(14))
                    .foregroundStyle(SAColor.textSecondary)
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

    private let thumbSize: CGFloat = 60
    private let trackHeight: CGFloat = 72
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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

                // Accent-filled rather than white: on the cream light theme a
                // white thumb on a white track was invisible.
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(SAColor.accent)
                    .frame(width: thumbSize, height: thumbSize)
                    .overlay {
                        Image(systemName: "chevron.right.2")
                            .font(.system(size: 18, weight: .black))
                            .foregroundStyle(SAColor.onAccent)
                    }
                    .offset(x: offset + 6)
                    .allowsHitTesting(false)
            }
            .frame(height: trackHeight)
            .contentShape(Rectangle())
            // The whole track takes the drag, seeded from where the finger
            // landed, so a thumb that starts a little off the knob still works.
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDragging = true
                        let grabOffset = max(0, min(value.startLocation.x - thumbSize / 2 - 6, maxOffset))
                        let seed = value.startLocation.x > thumbSize + 12 ? 0 : grabOffset
                        offset = min(max(0, seed + value.translation.width), maxOffset)
                    }
                    .onEnded { _ in
                        isDragging = false
                        if offset >= maxOffset * 0.88 {
                            offset = maxOffset
                            onUnlock()
                        } else {
                            withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 0.7)) {
                                offset = 0
                            }
                        }
                    }
            )
        }
        .frame(height: trackHeight)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 2.2).repeatForever(autoreverses: false)) {
                shimmer = 1.4
            }
        }
        .accessibilityElement()
        .accessibilityLabel(title)
        .accessibilityHint("Double-tap to \(title.lowercased().replacingOccurrences(of: "slide to ", with: ""))")
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
                .accessibilityHidden(true)

            Text("Snoozing")
                .font(SAFont.title(28))
                .foregroundStyle(SAColor.textPrimary)

            if let ends = runtime.snoozeEndsAt {
                VStack(spacing: 6) {
                    Text(countdown(to: ends))
                        .font(SAFont.clock(56))
                        .foregroundStyle(SAColor.accentText)
                    Text("until it rings again")
                        .font(SAFont.body(15))
                        .foregroundStyle(SAColor.textSecondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Time until it rings again")
                .accessibilityValue(countdown(to: ends))
                .accessibilityAddTraits(.updatesFrequently)
            }

            Text("Snoozed \(runtime.snoozeCount)×")
                .font(SAFont.caption(14))
                .foregroundStyle(SAColor.textSecondary)

            Spacer()

            VStack(spacing: 8) {
                Button("Ring now") {
                    HapticEngine.shared.impact(.medium)
                    runtime.wakeNow()
                }
                .buttonStyle(PrimaryButtonStyle(height: 66))

                Text("The mission still applies.")
                    .font(SAFont.caption(13))
                    .foregroundStyle(SAColor.textSecondary)
            }
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

            Text("Tap I'm up within \(runtime.activeAlarm?.wakeUpCheck.confirmWindowSeconds ?? 100) seconds or the alarm rings again.")
                .font(SAFont.body(17))
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
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Seconds to confirm")
            .accessibilityValue("\(runtime.wakeCheckSecondsRemaining)")
            .accessibilityAddTraits(.updatesFrequently)

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
