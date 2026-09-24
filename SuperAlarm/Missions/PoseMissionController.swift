import Foundation
import AVFoundation
import Combine
import Vision
import os.log

/// Counts push-ups and squats from the front camera using Vision's on-device
/// body-pose model.
///
/// Prop the phone up facing you and the rep counter watches your joints —
/// no need to hold, wear or pocket the device, which was the fatal flaw of
/// counting from the accelerometer alone.
@MainActor
public final class PoseMissionController: CaptureController, AVCaptureVideoDataOutputSampleBufferDelegate {

    // MARK: Published state

    @Published public private(set) var count = 0
    @Published public private(set) var phase: RepCountingStateMachine.Phase = .searching
    /// 0 at the top of the rep, 1 at full depth. Drives the on-screen gauge.
    @Published public private(set) var depth: Double = 0
    @Published public private(set) var coaching = "Get your whole body in frame"
    /// Normalised joint positions for the skeleton overlay, upright-image
    /// space with the origin at the bottom left.
    @Published public private(set) var overlayJoints: [PoseJoint: CGPoint] = [:]
    @Published public private(set) var isTrackingBody = false

    public var goal = 10
    public var onIncrement: ((Int) -> Void)?
    public var onComplete: (() -> Void)?

    /// The frame's aspect ratio (width / height) once upright, so the overlay
    /// can match the preview's aspect-fill cropping.
    public let frameAspect: CGFloat = 9.0 / 16.0

    // MARK: Internals

    private let videoOutput = AVCaptureVideoDataOutput()
    private var machine: RepCountingStateMachine
    private let exercise: RepExercise
    private var hasFinished = false
    private var lastFrameAt: Date = .distantPast
    /// Vision's model is heavy; 15 fps is ample for rep counting and leaves
    /// headroom on older devices.
    private let minimumFrameInterval: TimeInterval = 1.0 / 15.0

    /// Joints below this are treated as not visible. Static so the capture
    /// callback, which is nonisolated, can read it.
    private nonisolated static let confidenceFloor: Float = 0.3

    override var cameraPosition: AVCaptureDevice.Position { .front }
    override var preset: AVCaptureSession.Preset { .hd1280x720 }

    public init(exercise: RepExercise) {
        self.exercise = exercise
        self.machine = RepCountingStateMachine(exercise: exercise)
        super.init()
    }

    override func configureOutputs() {
        guard session.canAddOutput(videoOutput) else { return }
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ]
        session.addOutput(videoOutput)
        videoOutput.setSampleBufferDelegate(self, queue: sessionQueue)
    }

    public func reset() {
        machine.reset()
        count = 0
        depth = 0
        phase = .searching
        overlayJoints = [:]
        hasFinished = false
    }

    // MARK: Frame handling

    public nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Vision runs here on the capture queue; only the result hops to the
        // main actor.
        let handler = VNImageRequestHandler(
            cmSampleBuffer: sampleBuffer,
            // Front camera held in portrait: this puts the person upright in
            // Vision's coordinate space and mirrors to match the preview.
            orientation: .leftMirrored,
            options: [:]
        )

        let poseRequest = VNDetectHumanBodyPoseRequest()
        try? handler.perform([poseRequest])
        let observation = poseRequest.results?.first

        var sample: PoseSample?
        var overlay: [PoseJoint: CGPoint] = [:]

        if let observation, let points = try? observation.recognizedPoints(.all) {
            let floor = Self.confidenceFloor
            // Prefer whichever side the camera can see better.
            let left = Self.collect(points, side: .left, floor: floor)
            let right = Self.collect(points, side: .right, floor: floor)
            let best = right.count >= left.count ? right : left
            if !best.isEmpty { sample = PoseSample(joints: best) }
            overlay = best
        }

        let captured = sample
        let capturedOverlay = overlay
        Task { @MainActor in
            self.process(sample: captured, overlay: capturedOverlay)
        }
    }

    private nonisolated static func collect(
        _ points: [VNHumanBodyPoseObservation.JointName: VNRecognizedPoint],
        side: Side,
        floor: Float
    ) -> [PoseJoint: CGPoint] {
        var result: [PoseJoint: CGPoint] = [:]
        for (joint, name) in side.mapping {
            if let point = points[name], point.confidence >= floor {
                result[joint] = CGPoint(x: point.location.x, y: point.location.y)
            }
        }
        return result
    }

    private enum Side {
        case left, right

        var mapping: [(PoseJoint, VNHumanBodyPoseObservation.JointName)] {
            switch self {
            case .left:
                return [
                    (.shoulder, .leftShoulder), (.elbow, .leftElbow), (.wrist, .leftWrist),
                    (.hip, .leftHip), (.knee, .leftKnee), (.ankle, .leftAnkle),
                ]
            case .right:
                return [
                    (.shoulder, .rightShoulder), (.elbow, .rightElbow), (.wrist, .rightWrist),
                    (.hip, .rightHip), (.knee, .rightKnee), (.ankle, .rightAnkle),
                ]
            }
        }
    }

    private func process(sample: PoseSample?, overlay: [PoseJoint: CGPoint]) {
        guard !hasFinished else { return }

        let now = Date()
        guard now.timeIntervalSince(lastFrameAt) >= minimumFrameInterval else { return }
        lastFrameAt = now

        overlayJoints = overlay
        isTrackingBody = sample != nil

        let completedRep = machine.ingest(sample, now: now)

        phase = machine.phase
        depth = machine.depth
        coaching = machine.coaching

        if completedRep {
            count = min(machine.count, goal)
            HapticEngine.shared.impact(.medium)
            onIncrement?(count)

            if count >= goal {
                hasFinished = true
                HapticEngine.shared.success()
                onComplete?()
                stop()
            }
        }
    }
}
