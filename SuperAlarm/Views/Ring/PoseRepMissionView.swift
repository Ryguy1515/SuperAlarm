import SwiftUI
import UIKit

/// Push-ups and squats counted by the front camera.
///
/// Prop the phone against something facing you and watch the counter. Nothing
/// to hold, wear or pocket — which was the fatal flaw of counting reps from
/// the accelerometer alone.
struct PoseRepMissionView: View {
    @ObservedObject var session: MissionSession
    let exercise: RepExercise

    @StateObject private var controller: PoseMissionController

    init(session: MissionSession, exercise: RepExercise) {
        self.session = session
        self.exercise = exercise
        _controller = StateObject(wrappedValue: PoseMissionController(exercise: exercise))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            CameraPreview(session: controller.session)
                .ignoresSafeArea()

            SkeletonOverlay(
                joints: controller.overlayJoints,
                frameAspect: controller.frameAspect,
                isTracking: controller.isTrackingBody
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                counter
                Spacer()
                coaching
            }

            if let error = controller.errorMessage {
                permissionFallback(error)
            }
        }
        .task {
            let missionSession = session
            controller.goal = missionSession.settings.effectiveGoal
            controller.onComplete = { missionSession.passRound() }
            await controller.start()
        }
        .onDisappear {
            controller.onComplete = nil
            controller.onIncrement = nil
            controller.stop()
        }
    }

    // MARK: Counter

    private var counter: some View {
        VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(controller.count)")
                    .font(.system(size: 104, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.25), value: controller.count)

                Text("/ \(controller.goal)")
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
            }

            // Fills as you lower and empties as you push back up, so a
            // half-rep is obvious before it fails to count.
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.2))
                Capsule()
                    .fill(controller.depth > 0.85 ? SAColor.success : SAColor.accent)
                    .frame(width: max(6, 220 * controller.depth))
                    .animation(.easeOut(duration: 0.12), value: controller.depth)
            }
            .frame(width: 220, height: 8)

            Text(depthLabel)
                .font(SAFont.caption(12))
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(.vertical, 22)
        .padding(.horizontal, 34)
        .background(.black.opacity(0.42), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .padding(.top, 14)
    }

    private var depthLabel: String {
        switch controller.phase {
        case .searching: return "Not tracking"
        case .up: return "Top"
        case .down: return "Bottom"
        }
    }

    // MARK: Coaching

    private var coaching: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(controller.isTrackingBody ? SAColor.success : SAColor.warning)
                    .frame(width: 9, height: 9)
                Text(controller.isTrackingBody ? "Tracking you" : "Can't see you")
                    .font(SAFont.caption(13))
                    .foregroundStyle(.white.opacity(0.75))
            }

            Text(controller.coaching)
                .font(SAFont.headline(22))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)

            Text(setupHint)
                .font(SAFont.body(13))
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
        }
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity)
        .background(.black.opacity(0.55))
    }

    private var setupHint: String {
        switch exercise {
        case .pushup:
            return "Prop the phone up a couple of metres away, side on, so your shoulder, elbow and wrist are all in shot."
        case .squat:
            return "Prop the phone up a couple of metres away, side on, so your hip, knee and ankle are all in shot."
        }
    }

    // MARK: Permission fallback

    private func permissionFallback(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "video.slash.fill")
                .font(.system(size: 42, weight: .bold))
                .foregroundStyle(SAColor.warning)
            Text("Camera unavailable")
                .font(SAFont.title(22))
                .foregroundStyle(.white)
            Text(message)
                .font(SAFont.body(15))
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
            Text("Use the escape hatch below to stop the alarm, then switch this alarm to motion counting or a different mission.")
                .font(SAFont.body(13))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.88))
    }
}

// MARK: - Skeleton

/// Draws the tracked limb, so it is obvious the camera has found you — and
/// equally obvious which joint it has lost when it has not.
private struct SkeletonOverlay: View {
    let joints: [PoseJoint: CGPoint]
    let frameAspect: CGFloat
    let isTracking: Bool

    private static let segments: [(PoseJoint, PoseJoint)] = [
        (.shoulder, .elbow), (.elbow, .wrist),
        (.shoulder, .hip),
        (.hip, .knee), (.knee, .ankle),
    ]

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size

            ZStack {
                ForEach(Array(SkeletonOverlay.segments.enumerated()), id: \.offset) { _, segment in
                    if let start = joints[segment.0], let end = joints[segment.1] {
                        Path { path in
                            path.move(to: place(start, in: size))
                            path.addLine(to: place(end, in: size))
                        }
                        .stroke(SAColor.accent.opacity(0.9), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    }
                }

                ForEach(PoseJoint.allCases, id: \.self) { joint in
                    if let point = joints[joint] {
                        Circle()
                            .fill(.white)
                            .frame(width: 12, height: 12)
                            .overlay(Circle().strokeBorder(SAColor.accent, lineWidth: 3))
                            .position(place(point, in: size))
                    }
                }
            }
            .opacity(isTracking ? 1 : 0.35)
        }
    }

    /// Maps a Vision point (normalised, origin bottom-left) into view space,
    /// reproducing the preview layer's aspect-fill crop so the skeleton lands
    /// on the body rather than beside it.
    private func place(_ point: CGPoint, in size: CGSize) -> CGPoint {
        guard size.width > 0, size.height > 0 else { return .zero }

        let viewAspect = size.width / size.height
        let drawWidth: CGFloat
        let drawHeight: CGFloat

        if viewAspect > frameAspect {
            drawWidth = size.width
            drawHeight = size.width / frameAspect
        } else {
            drawHeight = size.height
            drawWidth = size.height * frameAspect
        }

        let offsetX = (size.width - drawWidth) / 2
        let offsetY = (size.height - drawHeight) / 2

        return CGPoint(
            x: offsetX + point.x * drawWidth,
            y: offsetY + (1 - point.y) * drawHeight
        )
    }
}
