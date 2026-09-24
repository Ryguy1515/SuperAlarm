import Foundation
import CoreGraphics

/// Which body angle defines a repetition.
public enum RepExercise: String, Codable, Sendable {
    case pushup
    case squat

    /// Angle at the tracked joint below which the rep counts as "down".
    var downBelow: Double {
        switch self {
        case .pushup: return 100   // elbow bent, chest lowered
        case .squat: return 110    // knee bent, hips dropped
        }
    }

    /// Angle above which the body is back to the top of the rep.
    var upAbove: Double {
        switch self {
        case .pushup: return 150   // arms close to locked out
        case .squat: return 160    // legs close to straight
        }
    }

    /// Joints that must be visible for a reading to be trusted.
    var requiredJoints: [PoseJoint] {
        switch self {
        case .pushup: return [.shoulder, .elbow, .wrist]
        case .squat: return [.hip, .knee, .ankle]
        }
    }

    var coachingDown: String {
        switch self {
        case .pushup: return "Lower your chest"
        case .squat: return "Drop your hips"
        }
    }

    var coachingUp: String {
        switch self {
        case .pushup: return "Push all the way up"
        case .squat: return "Stand all the way up"
        }
    }
}

/// The joints this counter cares about, independent of Vision's naming so the
/// state machine can be unit tested without importing Vision.
public enum PoseJoint: String, Sendable, CaseIterable {
    case shoulder, elbow, wrist, hip, knee, ankle
}

/// One side's worth of tracked points, already filtered by confidence.
public struct PoseSample: Sendable {
    public var joints: [PoseJoint: CGPoint]

    public init(joints: [PoseJoint: CGPoint]) {
        self.joints = joints
    }

    public func has(_ required: [PoseJoint]) -> Bool {
        required.allSatisfy { joints[$0] != nil }
    }
}

// MARK: - Geometry

public enum PoseGeometry {
    /// Interior angle at `vertex`, in degrees, between the rays to `a` and `b`.
    /// Returns nil for degenerate input rather than NaN.
    public static func angle(vertex: CGPoint, _ a: CGPoint, _ b: CGPoint) -> Double? {
        let v1 = CGPoint(x: a.x - vertex.x, y: a.y - vertex.y)
        let v2 = CGPoint(x: b.x - vertex.x, y: b.y - vertex.y)

        let m1 = (v1.x * v1.x + v1.y * v1.y).squareRoot()
        let m2 = (v2.x * v2.x + v2.y * v2.y).squareRoot()
        guard m1 > 1e-6, m2 > 1e-6 else { return nil }

        let cosine = Double((v1.x * v2.x + v1.y * v2.y) / (m1 * m2))
        return acos(max(-1, min(1, cosine))) * 180 / .pi
    }

    /// The angle a repetition is measured by: elbow for push-ups, knee for
    /// squats.
    public static func trackedAngle(for exercise: RepExercise, in sample: PoseSample) -> Double? {
        switch exercise {
        case .pushup:
            guard let shoulder = sample.joints[.shoulder],
                  let elbow = sample.joints[.elbow],
                  let wrist = sample.joints[.wrist] else { return nil }
            return angle(vertex: elbow, shoulder, wrist)
        case .squat:
            guard let hip = sample.joints[.hip],
                  let knee = sample.joints[.knee],
                  let ankle = sample.joints[.ankle] else { return nil }
            return angle(vertex: knee, hip, ankle)
        }
    }
}

// MARK: - State machine

/// Counts repetitions from a stream of joint angles.
///
/// Deliberately separate from Vision and from any view so the counting rules
/// can be tested directly — this is the part that decides whether someone is
/// let out of bed, so it should not only be verifiable on a device at 6am.
public final class RepCountingStateMachine {
    public enum Phase: String, Sendable {
        /// No usable reading yet, or the body left the frame.
        case searching
        /// At the top of the rep.
        case up
        /// At the bottom of the rep.
        case down
    }

    public private(set) var phase: Phase = .searching
    public private(set) var count = 0
    /// Most recent tracked angle, for the on-screen gauge.
    public private(set) var angle: Double?
    /// How far through the current rep, 0 (top) to 1 (bottom).
    public private(set) var depth: Double = 0

    private let exercise: RepExercise
    /// A rep cannot legitimately complete faster than this.
    private let minimumRepSeconds: TimeInterval
    private var lastRepAt: Date = .distantPast
    private var enteredDownAt: Date?
    /// Frames since the body was last seen, used to fall back to searching.
    private var missingFrames = 0
    private let missingFrameLimit = 15

    public init(exercise: RepExercise, minimumRepSeconds: TimeInterval = 0.6) {
        self.exercise = exercise
        self.minimumRepSeconds = minimumRepSeconds
    }

    /// Feeds one frame. Returns true when this frame completed a repetition.
    @discardableResult
    public func ingest(_ sample: PoseSample?, now: Date = Date()) -> Bool {
        guard let sample, sample.has(exercise.requiredJoints),
              let measured = PoseGeometry.trackedAngle(for: exercise, in: sample) else {
            missingFrames += 1
            if missingFrames >= missingFrameLimit {
                phase = .searching
                angle = nil
                depth = 0
            }
            return false
        }

        missingFrames = 0
        angle = measured

        // 0 at the top of the rep, 1 at full depth.
        let span = exercise.upAbove - exercise.downBelow
        depth = span > 0 ? max(0, min(1, (exercise.upAbove - measured) / span)) : 0

        switch phase {
        case .searching:
            // Only start counting once the body is at the top, so a partial
            // first rep cannot be claimed.
            if measured >= exercise.upAbove { phase = .up }

        case .up:
            if measured <= exercise.downBelow {
                phase = .down
                enteredDownAt = now
            }

        case .down:
            if measured >= exercise.upAbove {
                let longEnough = now.timeIntervalSince(lastRepAt) >= minimumRepSeconds
                let heldTheBottom = enteredDownAt.map { now.timeIntervalSince($0) >= 0.15 } ?? false
                phase = .up
                enteredDownAt = nil
                if longEnough && heldTheBottom {
                    count += 1
                    lastRepAt = now
                    return true
                }
            }
        }

        return false
    }

    /// Guidance for the current phase.
    public var coaching: String {
        switch phase {
        case .searching: return "Get your whole body in frame"
        case .up: return exercise.coachingDown
        case .down: return exercise.coachingUp
        }
    }

    public func reset() {
        phase = .searching
        count = 0
        angle = nil
        depth = 0
        enteredDownAt = nil
        lastRepAt = .distantPast
        missingFrames = 0
    }
}
