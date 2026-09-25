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

            CameraStatusOverlay(isRunning: controller.isRunning, errorMessage: controller.errorMessage)
        }
        .task {
            let missionSession = session
            controller.goal = missionSession.settings.effectiveGoal
            controller.onComplete = { missionSession.passRound() }
            await controller.start()
        }
        .onChange(of: controller.errorMessage) { _, message in
            session.setBlocked(message != nil)
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
                    .font(SAFont.display(104))
                    .foregroundStyle(SAColor.cream)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.25), value: controller.count)

                Text("/ \(controller.goal)")
                    .font(SAFont.title(30))
                    .foregroundStyle(SAColor.cream.opacity(0.6))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Repetitions")
            .accessibilityValue("\(controller.count) of \(controller.goal)")
            .accessibilityAddTraits(.updatesFrequently)

            // Fills as you lower and empties as you push back up, so a
            // half-rep is obvious before it fails to count. Sized to read
            // from the couple of metres the setup hint asks for.
            ZStack(alignment: .leading) {
                Capsule().fill(SAColor.cream.opacity(0.2))
                GeometryReader { geometry in
                    Capsule()
                        .fill(controller.depth > 0.85 ? SAColor.success : SAColor.accent)
                        .frame(width: max(12, geometry.size.width * controller.depth))
                        .animation(.easeOut(duration: 0.12), value: controller.depth)
                }
            }
            .frame(height: 22)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Depth")
            .accessibilityValue(depthLabel)

            Text(depthLabel)
                .font(SAFont.headline(24))
                .foregroundStyle(controller.isTrackingBody ? SAColor.cream : SAColor.warning)
        }
        .padding(.vertical, 22)
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity)
        .background(SAColor.ink.opacity(0.5), in: RoundedRectangle(cornerRadius: SAMetrics.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: SAMetrics.cardRadius, style: .continuous)
                .strokeBorder(SAColor.warning, lineWidth: controller.isTrackingBody ? 0 : 4)
        )
        .padding(.horizontal, SAMetrics.screenPadding)
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
            HStack(spacing: 10) {
                Image(systemName: controller.isTrackingBody ? "eye.fill" : "eye.slash.fill")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(controller.isTrackingBody ? SAColor.success : SAColor.warning)
                    .accessibilityHidden(true)
                Text(controller.isTrackingBody ? "Tracking you" : "Can't see you")
                    .font(SAFont.headline(19))
                    .foregroundStyle(SAColor.cream)
            }

            Text(controller.coaching)
                .font(SAFont.title(30))
                .foregroundStyle(SAColor.cream)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.6)

            Text(setupHint)
                .font(SAFont.body(14))
                .foregroundStyle(SAColor.cream.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
        }
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity)
        .background(SAColor.ink.opacity(0.6))
    }

    private var setupHint: String {
        switch exercise {
        case .pushup:
            return "Prop the phone up a couple of metres away, side on, so your shoulder, elbow and wrist are all in shot."
        case .squat:
            return "Prop the phone up a couple of metres away, side on, so your hip, knee and ankle are all in shot."
        }
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
                        .stroke(SAColor.accent.opacity(0.9), style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    }
                }

                ForEach(PoseJoint.allCases, id: \.self) { joint in
                    if let point = joints[joint] {
                        Circle()
                            .fill(SAColor.cream)
                            .frame(width: 18, height: 18)
                            .overlay(Circle().strokeBorder(SAColor.accent, lineWidth: 4))
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
