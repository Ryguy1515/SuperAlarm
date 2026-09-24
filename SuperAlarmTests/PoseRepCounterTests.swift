import XCTest
import CoreGraphics
@testable import SuperAlarm

/// The rep counter decides whether someone is allowed out of bed, so its rules
/// are tested directly rather than only being exercised on a device at 6am.
final class PoseRepCounterTests: XCTestCase {

    // MARK: Geometry

    func testAngleOfAStraightLimbIsOneEighty() {
        let angle = PoseGeometry.angle(
            vertex: CGPoint(x: 0.5, y: 0.5),
            CGPoint(x: 0.5, y: 0.9),
            CGPoint(x: 0.5, y: 0.1)
        )
        XCTAssertNotNil(angle)
        XCTAssertEqual(angle!, 180, accuracy: 0.001)
    }

    func testRightAngleIsNinety() {
        let angle = PoseGeometry.angle(
            vertex: .zero,
            CGPoint(x: 1, y: 0),
            CGPoint(x: 0, y: 1)
        )
        XCTAssertEqual(angle!, 90, accuracy: 0.001)
    }

    func testFullyFoldedLimbIsZero() {
        let angle = PoseGeometry.angle(
            vertex: .zero,
            CGPoint(x: 1, y: 0),
            CGPoint(x: 2, y: 0)
        )
        XCTAssertEqual(angle!, 0, accuracy: 0.001)
    }

    func testDegenerateInputReturnsNilRatherThanNaN() {
        // A joint detected on top of its neighbour must not produce NaN, which
        // would silently poison every comparison downstream.
        XCTAssertNil(PoseGeometry.angle(vertex: .zero, .zero, CGPoint(x: 1, y: 1)))
    }

    // MARK: Joint selection

    func testPushupMeasuresTheElbowAndSquatTheKnee() {
        let sample = PoseSample(joints: [
            .shoulder: CGPoint(x: 0.5, y: 0.9),
            .elbow: CGPoint(x: 0.5, y: 0.5),
            .wrist: CGPoint(x: 0.5, y: 0.1),
            .hip: CGPoint(x: 0.4, y: 0.6),
            .knee: CGPoint(x: 0.4, y: 0.4),
            .ankle: CGPoint(x: 0.4, y: 0.2),
        ])

        XCTAssertEqual(PoseGeometry.trackedAngle(for: .pushup, in: sample)!, 180, accuracy: 0.001)
        XCTAssertEqual(PoseGeometry.trackedAngle(for: .squat, in: sample)!, 180, accuracy: 0.001)
    }

    func testMissingJointsYieldNoAngle() {
        let partial = PoseSample(joints: [.shoulder: .zero, .elbow: CGPoint(x: 1, y: 0)])
        XCTAssertNil(PoseGeometry.trackedAngle(for: .pushup, in: partial))
        XCTAssertFalse(partial.has(RepExercise.pushup.requiredJoints))
    }

    // MARK: Counting

    /// Builds a sample whose elbow angle is approximately `degrees`.
    private func elbowSample(degrees: Double) -> PoseSample {
        let radians = degrees * .pi / 180
        return PoseSample(joints: [
            .elbow: .zero,
            .shoulder: CGPoint(x: 1, y: 0),
            .wrist: CGPoint(x: cos(radians), y: sin(radians)),
        ])
    }

    private func feed(_ machine: RepCountingStateMachine, angles: [Double], start: Date, step: TimeInterval = 0.4) -> Int {
        var reps = 0
        for (index, angle) in angles.enumerated() {
            let now = start.addingTimeInterval(step * Double(index))
            if machine.ingest(elbowSample(degrees: angle), now: now) { reps += 1 }
        }
        return reps
    }

    func testOneFullRepCounts() {
        let machine = RepCountingStateMachine(exercise: .pushup)
        let reps = feed(machine, angles: [170, 80, 170], start: Date())
        XCTAssertEqual(reps, 1)
        XCTAssertEqual(machine.count, 1)
    }

    func testThreeRepsCountThree() {
        let machine = RepCountingStateMachine(exercise: .pushup)
        let reps = feed(machine, angles: [170, 80, 170, 80, 170, 80, 170], start: Date())
        XCTAssertEqual(reps, 3)
    }

    func testHalfRepDoesNotCount() {
        // Down only partway, then back up: never crosses the down threshold.
        let machine = RepCountingStateMachine(exercise: .pushup)
        let reps = feed(machine, angles: [170, 130, 170, 125, 170], start: Date())
        XCTAssertEqual(reps, 0, "Half reps must not count")
    }

    func testCountingOnlyStartsFromTheTop() {
        // Starting mid-rep must not award a rep for merely standing up.
        let machine = RepCountingStateMachine(exercise: .pushup)
        let reps = feed(machine, angles: [80, 170], start: Date())
        XCTAssertEqual(reps, 0, "A partial first rep must not be claimed")
        XCTAssertEqual(machine.phase, .up)
    }

    func testImplausiblyFastRepsAreRejected() {
        // Flapping an arm can cross both thresholds; a real push-up cannot do
        // it in 50 ms.
        let machine = RepCountingStateMachine(exercise: .pushup)
        let start = Date()
        var reps = 0
        let angles: [Double] = [170, 80, 170, 80, 170, 80, 170]
        for (index, angle) in angles.enumerated() {
            let now = start.addingTimeInterval(0.05 * Double(index))
            if machine.ingest(elbowSample(degrees: angle), now: now) { reps += 1 }
        }
        XCTAssertEqual(reps, 0, "Reps faster than physically possible must be rejected")
    }

    func testLosingTheBodyReturnsToSearching() {
        let machine = RepCountingStateMachine(exercise: .pushup)
        _ = machine.ingest(elbowSample(degrees: 170), now: Date())
        XCTAssertEqual(machine.phase, .up)

        for _ in 0..<20 { _ = machine.ingest(nil, now: Date()) }
        XCTAssertEqual(machine.phase, .searching)
        XCTAssertNil(machine.angle)
    }

    func testBriefTrackingDropoutDoesNotResetPhase() {
        // A couple of dropped frames is normal; it must not lose the rep.
        let machine = RepCountingStateMachine(exercise: .pushup)
        _ = machine.ingest(elbowSample(degrees: 170), now: Date())
        for _ in 0..<3 { _ = machine.ingest(nil, now: Date()) }
        XCTAssertEqual(machine.phase, .up)
    }

    func testDepthRunsFromTopToBottom() {
        let machine = RepCountingStateMachine(exercise: .pushup)

        _ = machine.ingest(elbowSample(degrees: 160), now: Date())
        XCTAssertEqual(machine.depth, 0, accuracy: 0.05, "At the top depth should read zero")

        _ = machine.ingest(elbowSample(degrees: 90), now: Date().addingTimeInterval(0.4))
        XCTAssertGreaterThan(machine.depth, 0.9, "At the bottom depth should be near one")
    }

    func testResetClearsEverything() {
        let machine = RepCountingStateMachine(exercise: .pushup)
        _ = feed(machine, angles: [170, 80, 170], start: Date())
        XCTAssertEqual(machine.count, 1)

        machine.reset()
        XCTAssertEqual(machine.count, 0)
        XCTAssertEqual(machine.phase, .searching)
        XCTAssertEqual(machine.depth, 0)
    }

    func testSquatUsesItsOwnThresholds() {
        // 105 degrees is deep enough for a push-up but not for a squat.
        XCTAssertLessThan(RepExercise.pushup.downBelow, RepExercise.squat.downBelow)
        XCTAssertLessThan(RepExercise.pushup.upAbove, RepExercise.squat.upAbove)

        let machine = RepCountingStateMachine(exercise: .squat)
        let sample = { (degrees: Double) -> PoseSample in
            let radians = degrees * .pi / 180
            return PoseSample(joints: [
                .knee: .zero,
                .hip: CGPoint(x: 1, y: 0),
                .ankle: CGPoint(x: cos(radians), y: sin(radians)),
            ])
        }
        let start = Date()
        _ = machine.ingest(sample(170), now: start)
        _ = machine.ingest(sample(105), now: start.addingTimeInterval(0.4))
        let counted = machine.ingest(sample(170), now: start.addingTimeInterval(0.8))
        XCTAssertFalse(counted, "105 degrees is not deep enough to count as a squat")
    }

    // MARK: Settings

    func testCameraIsTheDefaultForReps() {
        XCTAssertEqual(MissionSettings(type: .pushup).repDetection, .camera)
        XCTAssertEqual(MissionSettings(type: .squat).repDetection, .camera)
    }

    func testRepDetectionSurvivesADecodeWithoutTheField() throws {
        let json = Data(#"{"type":"pushup","goal":12}"#.utf8)
        let settings = try JSONDecoder().decode(MissionSettings.self, from: json)
        XCTAssertEqual(settings.repDetection, .camera)
        XCTAssertEqual(settings.goal, 12)
    }
}
