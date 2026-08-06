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
        .onDisappear { engine.stop() }
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

            Image(systemName: session.settings.type.symbolName)
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(SAColor.accent)

            Text(engine.hint.isEmpty ? session.settings.type.tagline : engine.hint)
                .font(SAFont.headline(19))
                .foregroundStyle(SAColor.textPrimary)
                .multilineTextAlignment(.center)

            if session.settings.type == .walk {
                Text("Keep the phone with you. Steps are counted by the motion sensor, not by shaking.")
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

            Text("This mission can't run")
                .font(SAFont.title(22))
                .foregroundStyle(SAColor.textPrimary)

            Text(message)
                .font(SAFont.body(15))
                .foregroundStyle(SAColor.textSecondary)
                .multilineTextAlignment(.center)

            Text("Use the escape hatch below to stop the alarm, then pick a different mission.")
                .font(SAFont.body(13))
                .foregroundStyle(SAColor.textTertiary)
                .multilineTextAlignment(.center)
        }
    }

    private func start() {
        let goal = session.settings.effectiveGoal
        engine.onComplete = { session.passRound() }
        engine.onIncrement = { _ in HapticEngine.shared.impact(.light) }

        switch session.settings.type {
        case .walk: engine.start(.steps(goal: goal))
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

                Spacer()

                VStack(spacing: 10) {
                    Text(session.settings.barcodeLabel ?? "Find your registered code")
                        .font(SAFont.headline(20))
                        .foregroundStyle(.white)

                    if let mismatch = controller.mismatchMessage {
                        Text(mismatch)
                            .font(SAFont.body(14))
                            .foregroundStyle(SAColor.warning)
                            .multilineTextAlignment(.center)
                    } else {
                        Text("Point the camera at the code you registered.")
                            .font(SAFont.body(14))
                            .foregroundStyle(.white.opacity(0.75))
                            .multilineTextAlignment(.center)
                    }

                    if let error = controller.errorMessage {
                        Text(error)
                            .font(SAFont.body(13))
                            .foregroundStyle(SAColor.danger)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity)
                .background(.black.opacity(0.55))
            }
        }
        .task {
            controller.expectedPayload = session.settings.barcodePayload
            controller.onMatch = { _ in
                controller.stop()
                session.passRound()
                if !session.isComplete {
                    controller.reset()
                    Task { await controller.start() }
                }
            }
            await controller.start()
        }
        .onDisappear { controller.stop() }
    }
}

// MARK: - Object scan

struct ObjectMissionView: View {
    @ObservedObject var session: MissionSession
    @StateObject private var controller = ObjectMissionController()

    var body: some View {
        ZStack {
            CameraPreview(session: controller.session)
                .ignoresSafeArea()

            VStack {
                referenceThumbnail
                Spacer()
                meter
            }
        }
        .task {
            if let id = session.settings.objectImageID {
                controller.loadReference(imageID: id)
            }
            controller.onMatch = {
                controller.stop()
                session.passRound()
                if !session.isComplete {
                    controller.reset()
                    Task { await controller.start() }
                }
            }
            await controller.start()
        }
        .onDisappear { controller.stop() }
    }

    @ViewBuilder
    private var referenceThumbnail: some View {
        if let id = session.settings.objectImageID,
           let data = MissionAssetStore.shared.imageData(id: id),
           let image = UIImage(data: data) {
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
                        .foregroundStyle(.white.opacity(0.7))
                    Text(session.settings.objectLabel ?? "Registered object")
                        .font(SAFont.emphasis(16))
                        .foregroundStyle(.white)
                }
                Spacer()
            }
            .padding(14)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.horizontal, SAMetrics.screenPadding)
            .padding(.top, 10)
        }
    }

    private var meter: some View {
        VStack(spacing: 12) {
            if !controller.referenceLoaded {
                Text("The reference photo is missing. Use the escape hatch below and register it again.")
                    .font(SAFont.body(14))
                    .foregroundStyle(SAColor.warning)
                    .multilineTextAlignment(.center)
            } else {
                Text("Match")
                    .font(SAFont.caption(12))
                    .foregroundStyle(.white.opacity(0.7))

                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.25))
                        Capsule()
                            .fill(controller.similarity > 0.7 ? SAColor.success : SAColor.accent)
                            .frame(width: geometry.size.width * controller.similarity)
                            .animation(.easeOut(duration: 0.2), value: controller.similarity)
                    }
                }
                .frame(height: 12)
                .padding(.horizontal, 40)

                Text("Line the object up the way you photographed it.")
                    .font(SAFont.body(14))
                    .foregroundStyle(.white.opacity(0.75))
            }

            if let error = controller.errorMessage {
                Text(error)
                    .font(SAFont.body(13))
                    .foregroundStyle(SAColor.danger)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(.black.opacity(0.55))
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
                .font(.system(size: 78, weight: .light))
                .foregroundStyle(SAColor.accent)

            Text("Scan your face")
                .font(SAFont.title(24))
                .foregroundStyle(SAColor.textPrimary)

            Text("Sit up and look straight at the phone.")
                .font(SAFont.body(15))
                .foregroundStyle(SAColor.textSecondary)
                .multilineTextAlignment(.center)

            if let message {
                Text(message)
                    .font(SAFont.body(14))
                    .foregroundStyle(isBlocked ? SAColor.warning : SAColor.danger)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            Spacer(minLength: 0)

            if !isBlocked {
                Button {
                    Task { await authenticate() }
                } label: {
                    Text(isRunning ? "Scanning…" : "Scan \(BiometricMission.displayName)")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(isRunning)
                .padding(.horizontal, SAMetrics.screenPadding)
            } else {
                Text("Use the escape hatch below to stop the alarm.")
                    .font(SAFont.body(13))
                    .foregroundStyle(SAColor.textTertiary)
                    .padding(.bottom, 10)
            }
        }
        .task {
            // Go straight into the scan rather than making a half-asleep user
            // find a button first.
            await authenticate()
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
            controller.expectedPayload = nil
            controller.onMatch = { payload in
                controller.stop()
                onRegister(payload)
            }
            await controller.start()
        }
        .onDisappear { controller.stop() }
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
                    .padding(.bottom, 6)
                }
                .padding(20)
                .frame(maxWidth: .infinity)
                .background(.black.opacity(0.6))
            }
        }
        .task {
            controller.isRegistrationMode = true
            controller.onCapturedReference = { data in
                controller.stop()
                if let id = MissionAssetStore.shared.saveImageData(data) {
                    onRegister(id)
                }
            }
            await controller.start()
        }
        .onDisappear { controller.stop() }
    }
}
