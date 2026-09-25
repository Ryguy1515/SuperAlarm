import SwiftUI
import UIKit
import AVFoundation

// MARK: - Motion (walk / shake / push-up / squat)

struct MotionMissionView: View {
    @ObservedObject var session: MissionSession
    @StateObject private var engine = MotionMissionEngine()

    var body: some View {
        VStack(spacing: 26) {
            Spacer(minLength: 0)

            switch engine.availability {
            case .ready:
                counter
            case .unsupported(let message), .permissionDenied(let message):
                unavailable(message)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, SAMetrics.screenPadding)
        .onAppear(perform: start)
        .onChange(of: engine.availability) { _, availability in
            session.setBlocked(availability != .ready)
        }
        .onDisappear {
            engine.onComplete = nil
            engine.onIncrement = nil
            engine.stop()
        }
    }

    private var counter: some View {
        VStack(spacing: 22) {
            ZStack {
                SAProgressRing(progress: engine.progress, lineWidth: 14)
                    .frame(width: 230, height: 230)

                VStack(spacing: 4) {
                    Text("\(engine.count)")
                        .font(SAFont.clock(64))
                        .foregroundStyle(SAColor.textPrimary)
                        .contentTransition(.numericText())
                        .animation(.snappy, value: engine.count)
                    Text("of \(engine.goal)")
                        .font(SAFont.body(16))
                        .foregroundStyle(SAColor.textSecondary)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Progress")
            .accessibilityValue("\(engine.count) of \(engine.goal)")
            .accessibilityAddTraits(.updatesFrequently)

            Image(systemName: session.settings.type.symbolName)
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(SAColor.accent)
                .accessibilityHidden(true)

            Text(engine.hint.isEmpty ? session.settings.type.tagline : engine.hint)
                .font(SAFont.headline(19))
                .foregroundStyle(engine.isMoving ? SAColor.success : SAColor.textPrimary)
                .multilineTextAlignment(.center)
                .animation(.easeInOut(duration: 0.2), value: engine.isMoving)

            if session.settings.type == .walk {
                Text("Keep the phone with you. Steps arrive in batches a few seconds behind your feet, so keep walking.")
                    .font(SAFont.body(13))
                    .foregroundStyle(SAColor.textTertiary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private func unavailable(_ message: String) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 42, weight: .bold))
                .foregroundStyle(SAColor.warning)
                .accessibilityHidden(true)

            Text("This mission can't run")
                .font(SAFont.title(22))
                .foregroundStyle(SAColor.textPrimary)

            Text(message)
                .font(SAFont.body(15))
                .foregroundStyle(SAColor.textSecondary)
                .multilineTextAlignment(.center)

            Text("Use the escape hatch below to turn off the alarm, then pick a different mission.")
                .font(SAFont.body(14))
                .foregroundStyle(SAColor.textSecondary)
                .multilineTextAlignment(.center)
        }
    }

    private func start() {
        // Bound to a local first so the callbacks capture the session object
        // rather than the view that owns it.
        let session = self.session
        let goal = session.settings.effectiveGoal
        engine.onComplete = { session.passRound() }
        engine.onIncrement = { _ in HapticEngine.shared.impact(.light) }
        session.setBlocked(false)

        switch session.settings.type {
        // Steps are counted from the moment the mission began, not from when
        // this view appeared, so a rebuilt view or a relaunch resumes the
        // count rather than resetting it.
        case .walk: engine.start(.steps(goal: goal), since: session.startedAt)
        case .shake: engine.start(.shake(goal: goal))
        case .pushup: engine.start(.reps(goal: goal, kind: .pushup))
        case .squat: engine.start(.reps(goal: goal, kind: .squat))
        default: break
        }
    }
}

// MARK: - Barcode

struct BarcodeMissionView: View {
    @ObservedObject var session: MissionSession
    @StateObject private var controller = BarcodeMissionController()

    var body: some View {
        ZStack {
            CameraPreview(session: controller.session)
                .ignoresSafeArea()

            VStack {
                Spacer()

                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(SAColor.accent, lineWidth: 4)
                    .frame(width: 250, height: 250)
                    .accessibilityHidden(true)

                Spacer()

                VStack(spacing: 10) {
                    Text(session.settings.barcodeLabel ?? "Find your registered code")
                        .font(SAFont.headline(20))
                        .foregroundStyle(SAColor.cream)

                    if let mismatch = controller.mismatchMessage {
                        Text(mismatch)
                            .font(SAFont.body(15))
                            .foregroundStyle(SAColor.warning)
                            .multilineTextAlignment(.center)
                    } else {
                        Text("Point the camera at the code you registered.")
                            .font(SAFont.body(15))
                            .foregroundStyle(SAColor.cream.opacity(0.8))
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity)
                .background(SAColor.ink.opacity(0.6))
            }

            CameraStatusOverlay(isRunning: controller.isRunning, errorMessage: controller.errorMessage)
        }
        .task {
            // Locals, because a capture list cannot name a property directly
            // and these must be bound before first use.
            let controller = self.controller
            let session = self.session
            controller.expectedPayload = session.settings.barcodePayload
            // On a match the round passes and the runner rebuilds this view
            // with a fresh controller for the next round, so nothing here
            // restarts the camera — two sessions on one camera fight.
            controller.onMatch = { [weak controller] _ in
                controller?.stop()
                session.passRound()
            }
            await controller.start()
        }
        .onChange(of: controller.errorMessage) { _, message in
            session.setBlocked(message != nil)
        }
        .onDisappear {
            controller.onMatch = nil
            controller.stop()
        }
    }
}

// MARK: - Camera status

/// What the user sees over a black preview: that the camera is starting,
/// or that it cannot start and why. Shared by every camera mission.
struct CameraStatusOverlay: View {
    let isRunning: Bool
    let errorMessage: String?

    var body: some View {
        if let errorMessage {
            VStack(spacing: 16) {
                Image(systemName: "video.slash.fill")
                    .font(.system(size: 42, weight: .bold))
                    .foregroundStyle(SAColor.warning)
                    .accessibilityHidden(true)
                Text("Camera unavailable")
                    .font(SAFont.title(22))
                    .foregroundStyle(SAColor.cream)
                Text(errorMessage)
                    .font(SAFont.body(15))
                    .foregroundStyle(SAColor.cream.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
                Text("Use the escape hatch below to turn off the alarm, then pick a different mission.")
                    .font(SAFont.body(14))
                    .foregroundStyle(SAColor.cream.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    Link("Open iPhone Settings", destination: url)
                        .font(SAFont.emphasis(16))
                        .foregroundStyle(SAColor.accent)
                        .frame(minHeight: 44)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(SAColor.ink.opacity(0.9))
        } else if !isRunning {
            VStack(spacing: 14) {
                ProgressView()
                    .tint(SAColor.accent)
                    .scaleEffect(1.4)
                Text("Starting camera…")
                    .font(SAFont.headline(19))
                    .foregroundStyle(SAColor.cream)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(SAColor.ink.opacity(0.7))
            .accessibilityElement(children: .combine)
        }
    }
}

// MARK: - Object scan

struct ObjectMissionView: View {
    @ObservedObject var session: MissionSession
    @StateObject private var controller = ObjectMissionController()
    /// Decoded once; the meter redraws three times a second.
    @State private var referenceImage: UIImage?

    var body: some View {
        ZStack {
            CameraPreview(session: controller.session)
                .ignoresSafeArea()

            VStack {
                referenceThumbnail
                Spacer()
                meter
            }

            CameraStatusOverlay(isRunning: controller.isRunning, errorMessage: controller.errorMessage)
        }
        .task {
            let controller = self.controller
            let session = self.session
            if let id = session.settings.objectImageID {
                if let data = MissionAssetStore.shared.imageData(id: id) {
                    referenceImage = UIImage(data: data)
                }
                controller.loadReference(imageID: id)
            }
            session.setBlocked(!controller.referenceLoaded)
            // The runner rebuilds this view with a fresh controller for the
            // next round; restarting this one too would put two sessions on
            // one camera.
            controller.onMatch = { [weak controller] in
                controller?.stop()
                session.passRound()
            }
            await controller.start()
        }
        .onChange(of: controller.errorMessage) { _, message in
            session.setBlocked(message != nil || !controller.referenceLoaded)
        }
        .onDisappear {
            controller.onMatch = nil
            controller.stop()
        }
    }

    @ViewBuilder
    private var referenceThumbnail: some View {
        if let image = referenceImage {
            HStack(spacing: 12) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 74, height: 74)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(SAColor.accent, lineWidth: 2)
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text("Find this")
                        .font(SAFont.caption(12))
                        .foregroundStyle(SAColor.cream.opacity(0.75))
                    Text(session.settings.objectLabel ?? "Registered object")
                        .font(SAFont.emphasis(16))
                        .foregroundStyle(SAColor.cream)
                }
                Spacer()

                if controller.hasTorch {
                    Button {
                        controller.setTorch(!controller.isTorchOn)
                    } label: {
                        Image(systemName: controller.isTorchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(controller.isTorchOn ? SAColor.onAccent : SAColor.cream)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(controller.isTorchOn ? SAColor.accent : SAColor.cream.opacity(0.18)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(controller.isTorchOn ? "Turn torch off" : "Turn torch on")
                }
            }
            .padding(14)
            .background(SAColor.ink.opacity(0.6), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.horizontal, SAMetrics.screenPadding)
            .padding(.top, 10)
        }
    }

    private var meter: some View {
        VStack(spacing: 12) {
            if !controller.referenceLoaded {
                Text("The reference photo is missing. Use the escape hatch below to turn off the alarm, then register it again.")
                    .font(SAFont.body(15))
                    .foregroundStyle(SAColor.warning)
                    .multilineTextAlignment(.center)
            } else {
                Text("Match: \(Int((controller.similarity * 100).rounded()))%")
                    .font(SAFont.headline(18))
                    .foregroundStyle(SAColor.cream)
                    .monospacedDigit()

                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(SAColor.cream.opacity(0.25))
                        Capsule()
                            .fill(controller.similarity > 0.7 ? SAColor.success : SAColor.accent)
                            .frame(width: geometry.size.width * controller.similarity)
                            .animation(.easeOut(duration: 0.2), value: controller.similarity)
                    }
                }
                .frame(height: 14)
                .padding(.horizontal, 40)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Match")
                .accessibilityValue("\(Int((controller.similarity * 100).rounded())) percent")
                .accessibilityAddTraits(.updatesFrequently)

                Text("Line the object up the way you photographed it — same distance, same light.")
                    .font(SAFont.body(15))
                    .foregroundStyle(SAColor.cream.opacity(0.8))
                    .multilineTextAlignment(.center)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(SAColor.ink.opacity(0.6))
    }
}

// MARK: - Face ID

struct FaceIDMissionView: View {
    @ObservedObject var session: MissionSession

    @State private var message: String?
    @State private var isRunning = false
    @State private var isBlocked = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 0)

            Image(systemName: BiometricMission.symbolName)
                .font(.system(size: 78, weight: .bold))
                .foregroundStyle(SAColor.accent)
                .accessibilityHidden(true)

            Text(BiometricMission.displayName == "Face ID" ? "Scan your face" : "Use \(BiometricMission.displayName)")
                .font(SAFont.title(24))
                .foregroundStyle(SAColor.textPrimary)

            Text(BiometricMission.displayName == "Face ID"
                 ? "Sit up and look straight at the phone."
                 : "Sit up and rest your finger on the sensor.")
                .font(SAFont.body(15))
                .foregroundStyle(SAColor.textSecondary)
                .multilineTextAlignment(.center)

            if let message {
                Text(message)
                    .font(SAFont.body(15))
                    .foregroundStyle(isBlocked ? SAColor.warning : SAColor.danger)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            Spacer(minLength: 0)

            if !isBlocked {
                Button {
                    Task { await authenticate() }
                } label: {
                    Text(isRunning ? "Scanning…" : "Use \(BiometricMission.displayName)")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(isRunning)
                .padding(.horizontal, SAMetrics.screenPadding)
            } else {
                Text("Use the escape hatch below to turn off the alarm.")
                    .font(SAFont.body(14))
                    .foregroundStyle(SAColor.textSecondary)
                    .padding(.bottom, 10)
            }
        }
        .task {
            // Go straight into the scan rather than making a half-asleep user
            // find a button first.
            await authenticate()
        }
        .onChange(of: isBlocked) { _, blocked in
            session.setBlocked(blocked)
        }
    }

    private func authenticate() async {
        guard !isRunning, !isBlocked else { return }
        isRunning = true
        defer { isRunning = false }

        // The alarm is muted for the moment of the scan so the prompt is
        // audible and the camera is not competing with a siren.
        AlarmAudioEngine.shared.setDucked(true)
        let outcome = await BiometricMission.authenticate()
        AlarmAudioEngine.shared.setDucked(false)

        switch outcome {
        case .success:
            message = nil
            session.passRound()
        case .failed(let reason):
            message = reason
            session.registerFailure()
        case .unavailable(let reason):
            message = reason
            isBlocked = true
        case .cancelled:
            message = "Scan cancelled. Try again."
        }
    }
}

// MARK: - Registration: barcode

struct BarcodeRegistrationView: View {
    var onRegister: (String) -> Void
    var onCancel: () -> Void

    @StateObject private var controller = BarcodeMissionController()

    var body: some View {
        ZStack {
            CameraPreview(session: controller.session)
                .ignoresSafeArea()

            VStack {
                HStack {
                    Button {
                        controller.stop()
                        onCancel()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .black))
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                            .background(Circle().fill(.black.opacity(0.5)))
                    }
                    Spacer()
                }
                .padding(SAMetrics.screenPadding)

                Spacer()

                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(SAColor.accent, lineWidth: 4)
                    .frame(width: 250, height: 250)

                Spacer()

                VStack(spacing: 8) {
                    Text("Scan any barcode or QR code")
                        .font(SAFont.headline(19))
                        .foregroundStyle(.white)
                    Text("Pick something you keep away from your bed. You will have to come back and scan this exact code to turn the alarm off.")
                        .font(SAFont.body(14))
                        .foregroundStyle(.white.opacity(0.75))
                        .multilineTextAlignment(.center)
                    if let error = controller.errorMessage {
                        Text(error)
                            .font(SAFont.body(13))
                            .foregroundStyle(SAColor.danger)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity)
                .background(.black.opacity(0.6))
            }
        }
        .task {
            let register = onRegister
            controller.expectedPayload = nil
            controller.onMatch = { [weak controller] payload in
                controller?.stop()
                register(payload)
            }
            await controller.start()
        }
        .onDisappear {
            controller.onMatch = nil
            controller.stop()
        }
    }
}

// MARK: - Registration: object

struct ObjectRegistrationView: View {
    var onRegister: (String) -> Void
    var onCancel: () -> Void

    @StateObject private var controller = ObjectMissionController()

    var body: some View {
        ZStack {
            CameraPreview(session: controller.session)
                .ignoresSafeArea()

            VStack {
                HStack {
                    Button {
                        controller.stop()
                        onCancel()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .black))
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                            .background(Circle().fill(.black.opacity(0.5)))
                    }
                    Spacer()
                }
                .padding(SAMetrics.screenPadding)

                Spacer()

                VStack(spacing: 14) {
                    Text("Photograph the object")
                        .font(SAFont.headline(19))
                        .foregroundStyle(.white)
                    Text("Fill the frame with something distinctive and far from your bed — the kettle, the bathroom mirror, your toothbrush.")
                        .font(SAFont.body(14))
                        .foregroundStyle(.white.opacity(0.75))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)

                    if let error = controller.errorMessage {
                        Text(error)
                            .font(SAFont.body(13))
                            .foregroundStyle(SAColor.danger)
                    }

                    Button {
                        controller.captureReference()
                    } label: {
                        Circle()
                            .fill(.white)
                            .frame(width: 72, height: 72)
                            .overlay(Circle().strokeBorder(SAColor.accent, lineWidth: 4).padding(-6))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Take photo")
                    .padding(.bottom, 6)
                }
                .padding(20)
                .frame(maxWidth: .infinity)
                .background(.black.opacity(0.6))
            }
        }
        .task {
            let register = onRegister
            controller.isRegistrationMode = true
            controller.onCapturedReference = { [weak controller] data in
                controller?.stop()
                if let id = MissionAssetStore.shared.saveImageData(data) {
                    register(id)
                }
            }
            await controller.start()
        }
        .onDisappear {
            controller.onCapturedReference = nil
            controller.stop()
        }
    }
}
