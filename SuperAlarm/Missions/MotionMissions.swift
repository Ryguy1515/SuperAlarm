import Foundation
import Combine
import os.log
#if canImport(CoreMotion)
import CoreMotion
#endif

/// Drives every sensor-based mission: step counting, shake detection and
/// repetition counting for push-ups and squats.
///
/// All four share one `CMMotionManager` because Core Motion documents that a
/// single instance per app is the supported pattern.
@MainActor
public final class MotionMissionEngine: ObservableObject {
    public enum Mode: Equatable {
        case steps(goal: Int)
        case shake(goal: Int)
        case reps(goal: Int, kind: MissionType)
    }

    public enum Availability: Equatable {
        case ready
        case unsupported(String)
        case permissionDenied(String)
    }

    @Published public private(set) var count: Int = 0
    @Published public private(set) var goal: Int = 0
    @Published public private(set) var availability: Availability = .ready
    @Published public private(set) var isRunning = false
    /// Live coaching text, e.g. "Go lower" or "Keep walking".
    @Published public private(set) var hint: String = ""

    public var progress: Double {
        goal <= 0 ? 0 : min(1, Double(count) / Double(goal))
    }

    public var isComplete: Bool { goal > 0 && count >= goal }

    /// Fired once when the goal is reached.
    public var onComplete: (() -> Void)?
    /// Fired on each increment, for haptics and sound.
    public var onIncrement: ((Int) -> Void)?

    private let log = Logger(subsystem: "io.superalarm", category: "motion")

    #if canImport(CoreMotion)
    private let motionManager = CMMotionManager()
    private let pedometer = CMPedometer()
    #endif

    private var mode: Mode?
    private var hasCompleted = false

    // Shake detection state
    private var shakeArmed = true
    private var lastShakeAt: Date = .distantPast

    // Repetition state machine
    private enum RepPhase { case idle, descending, ascending }
    private var repPhase: RepPhase = .idle
    private var filteredVertical: Double = 0
    private var phaseStartedAt: Date = .distantPast
    private var lastRepAt: Date = .distantPast

    public init() {}

    deinit {
        #if canImport(CoreMotion)
        motionManager.stopAccelerometerUpdates()
        motionManager.stopDeviceMotionUpdates()
        pedometer.stopUpdates()
        #endif
    }

    // MARK: - Lifecycle

    public func start(_ mode: Mode) {
        stop()
        self.mode = mode
        count = 0
        hasCompleted = false
        repPhase = .idle
        filteredVertical = 0

        switch mode {
        case .steps(let target):
            goal = target
            startSteps()
        case .shake(let target):
            goal = target
            startShake()
        case .reps(let target, let kind):
            goal = target
            startReps(kind: kind)
        }
    }

    public func stop() {
        #if canImport(CoreMotion)
        motionManager.stopAccelerometerUpdates()
        motionManager.stopDeviceMotionUpdates()
        pedometer.stopUpdates()
        #endif
        isRunning = false
    }

    /// Test seam and accessibility escape hatch — lets the ring screen award
    /// progress when sensors are unavailable.
    public func incrementManually() {
        register()
    }

    private func register() {
        guard !hasCompleted else { return }
        count += 1
        onIncrement?(count)
        if count >= goal {
            hasCompleted = true
            hint = "Done"
            onComplete?()
            stop()
        }
    }

    // MARK: - Steps

    private func startSteps() {
        #if canImport(CoreMotion)
        guard CMPedometer.isStepCountingAvailable() else {
            availability = .unsupported("This device cannot count steps.")
            log.error("Step counting unavailable")
            return
        }

        let status = CMPedometer.authorizationStatus()
        if status == .denied || status == .restricted {
            availability = .permissionDenied("Motion access is off. Enable it in Settings › Privacy › Motion & Fitness.")
            return
        }

        availability = .ready
        isRunning = true
        hint = "Get up and start walking"

        let start = Date()
        pedometer.startUpdates(from: start) { [weak self] data, error in
            guard let data else {
                if let error { self?.log.error("Pedometer: \(String(describing: error), privacy: .public)") }
                return
            }
            let steps = data.numberOfSteps.intValue
            Task { @MainActor in
                guard let self, !self.hasCompleted else { return }
                // The pedometer reports cumulative totals, so assign rather
                // than increment.
                let clamped = min(steps, self.goal)
                if clamped != self.count {
                    self.count = clamped
                    self.onIncrement?(clamped)
                }
                let left = max(0, self.goal - clamped)
                self.hint = left == 0 ? "Done" : "\(left) steps to go"
                if clamped >= self.goal {
                    self.hasCompleted = true
                    self.onComplete?()
                    self.stop()
                }
            }
        }
        #else
        availability = .unsupported("Motion sensors are not available.")
        #endif
    }

    // MARK: - Shake

    private func startShake() {
        #if canImport(CoreMotion)
        guard motionManager.isAccelerometerAvailable else {
            availability = .unsupported("This device has no accelerometer.")
            return
        }

        availability = .ready
        isRunning = true
        hint = "Shake the phone"

        motionManager.accelerometerUpdateInterval = 1.0 / 50.0
        motionManager.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
            guard let self, let data else { return }
            MainActor.assumeIsolated {
                self.handleShakeSample(data.acceleration)
            }
        }
        #else
        availability = .unsupported("Motion sensors are not available.")
        #endif
    }

    #if canImport(CoreMotion)
    private func handleShakeSample(_ acceleration: CMAcceleration) {
        guard !hasCompleted else { return }

        // Gravity alone reads ~1 g, so a genuine shake shows up well above it.
        let magnitude = sqrt(
            acceleration.x * acceleration.x
                + acceleration.y * acceleration.y
                + acceleration.z * acceleration.z
        )

        let highThreshold = 2.1
        let lowThreshold = 1.3
        let minimumInterval: TimeInterval = 0.14

        if shakeArmed, magnitude > highThreshold {
            let now = Date()
            if now.timeIntervalSince(lastShakeAt) >= minimumInterval {
                lastShakeAt = now
                shakeArmed = false
                register()
                hint = "\(max(0, goal - count)) to go"
            }
        } else if !shakeArmed, magnitude < lowThreshold {
            // Require the motion to settle before the next shake counts, so
            // one violent swing cannot register as several.
            shakeArmed = true
        }
    }
    #endif

    // MARK: - Repetitions

    private func startReps(kind: MissionType) {
        #if canImport(CoreMotion)
        guard motionManager.isDeviceMotionAvailable else {
            availability = .unsupported("This device cannot track motion.")
            return
        }

        availability = .ready
        isRunning = true
        hint = kind == .squat ? "Stand up straight to begin" : "Get into position"

        motionManager.deviceMotionUpdateInterval = 1.0 / 50.0
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            MainActor.assumeIsolated {
                self.handleRepSample(motion, kind: kind)
            }
        }
        #else
        availability = .unsupported("Motion sensors are not available.")
        #endif
    }

    #if canImport(CoreMotion)
    /// Counts a rep as a full down-then-up cycle along the gravity axis.
    ///
    /// Projecting user acceleration onto the gravity vector makes the result
    /// independent of how the phone is oriented — in a pocket, strapped to an
    /// arm, or held against the chest all behave the same.
    private func handleRepSample(_ motion: CMDeviceMotion, kind: MissionType) {
        guard !hasCompleted else { return }

        let gravity = motion.gravity
        let user = motion.userAcceleration
        let vertical = user.x * gravity.x + user.y * gravity.y + user.z * gravity.z

        // Low-pass filter to reject jitter and small hand tremor.
        filteredVertical = filteredVertical * 0.8 + vertical * 0.2

        // Squats move the whole body and read stronger than push-ups.
        let threshold = kind == .squat ? 0.16 : 0.11
        // A real rep cannot be faster than this; shaking the phone can be.
        let minimumPhaseSeconds: TimeInterval = 0.28
        let refractory: TimeInterval = 0.45

        let now = Date()

        switch repPhase {
        case .idle:
            if filteredVertical < -threshold, now.timeIntervalSince(lastRepAt) > refractory {
                repPhase = .descending
                phaseStartedAt = now
                hint = kind == .squat ? "Down…" : "Lower…"
            }

        case .descending:
            if filteredVertical > threshold {
                // Reject anything suspiciously quick — that is a shake, not a
                // repetition.
                if now.timeIntervalSince(phaseStartedAt) >= minimumPhaseSeconds {
                    repPhase = .ascending
                    phaseStartedAt = now
                    hint = "Up!"
                } else {
                    repPhase = .idle
                    hint = "Too fast — slow it down"
                }
            } else if now.timeIntervalSince(phaseStartedAt) > 6 {
                repPhase = .idle
            }

        case .ascending:
            if abs(filteredVertical) < threshold * 0.5 {
                if now.timeIntervalSince(phaseStartedAt) >= minimumPhaseSeconds * 0.6 {
                    lastRepAt = now
                    repPhase = .idle
                    register()
                    if !hasCompleted {
                        hint = "\(max(0, goal - count)) to go"
                    }
                } else {
                    repPhase = .idle
                    hint = "Too fast — slow it down"
                }
            } else if now.timeIntervalSince(phaseStartedAt) > 6 {
                repPhase = .idle
            }
        }
    }
    #endif
}
