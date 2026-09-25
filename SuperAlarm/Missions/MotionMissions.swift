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
    /// True while the phone is physically moving — the walking mission shows
    /// this immediately, before the pedometer's first batch lands.
    @Published public private(set) var isMoving = false

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

    // Step counting state
    private var stepModel = StepCountModel(goal: 1)
    private var stepStart = Date()
    private var stepQueryTimer: Timer?
    /// Set when this engine triggered the first-ever Motion permission
    /// prompt, so a denial mid-mission is reported rather than hanging.
    private var awaitingMotionPermission = false

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

    /// Starts a mission.
    ///
    /// `since` is the moment the mission began. The walking mission counts
    /// steps from that instant, so a mission that survives a relaunch (or a
    /// view that is rebuilt underneath the engine) resumes with every step
    /// already taken instead of starting from zero.
    public func start(_ mode: Mode, since: Date = Date()) {
        stop()
        self.mode = mode
        count = 0
        hasCompleted = false
        isMoving = false
        repPhase = .idle
        filteredVertical = 0

        switch mode {
        case .steps(let target):
            goal = target
            startSteps(from: since)
        case .shake(let target):
            goal = target
            startShake()
        case .reps(let target, let kind):
            goal = target
            startReps(kind: kind)
        }
    }

    public func stop() {
        stepQueryTimer?.invalidate()
        stepQueryTimer = nil
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

    /// Walking is counted from three sources at once, because the pedometer
    /// alone feels broken on a live counter:
    ///
    /// * `startUpdates(from:)` delivers cumulative totals in batches every
    ///   few seconds, with the first batch often slower still.
    /// * `queryPedometerData(from:to:)` is polled every second and frequently
    ///   knows about steps the live stream has not reported yet.
    /// * The accelerometer says whether the phone is moving at all, so the
    ///   screen reacts within a frame of the user getting up.
    ///
    /// `StepCountModel` reconciles the totals into a count that never goes
    /// backwards.
    private func startSteps(from start: Date) {
        #if canImport(CoreMotion)
        guard CMPedometer.isStepCountingAvailable() else {
            availability = .unsupported("This device cannot count steps.")
            log.error("Step counting unavailable")
            return
        }

        let status = CMPedometer.authorizationStatus()
        if status == .denied || status == .restricted {
            availability = .permissionDenied(Self.motionDeniedMessage)
            return
        }
        awaitingMotionPermission = status == .notDetermined

        availability = .ready
        isRunning = true
        stepModel = StepCountModel(goal: goal)
        stepStart = start
        hint = stepModel.hint

        pedometer.startUpdates(from: start) { [weak self] data, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.handlePedometerError(error)
                    return
                }
                guard let data else { return }
                self.applySteps(total: data.numberOfSteps.intValue, from: .liveUpdate)
            }
        }

        // The query every second is what makes the counter feel live.
        let timer = Timer(timeInterval: StepCountModel.queryInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollPedometer() }
        }
        RunLoop.main.add(timer, forMode: .common)
        stepQueryTimer = timer

        startMovementDetection()
        #else
        availability = .unsupported("Motion sensors are not available.")
        #endif
    }

    #if canImport(CoreMotion)
    private static let motionDeniedMessage =
        "Motion access is off. Enable it in Settings › Privacy & Security › Motion & Fitness, then come back."

    private func pollPedometer() {
        guard isRunning, !hasCompleted, let mode, case .steps = mode else { return }

        // A permission prompt that appeared mid-mission may have just been
        // answered; a denial must surface instead of a counter stuck at 0.
        if awaitingMotionPermission {
            let status = CMPedometer.authorizationStatus()
            if status == .denied || status == .restricted {
                handlePedometerError(NSError(domain: CMErrorDomain, code: Int(CMErrorMotionActivityNotAuthorized.rawValue)))
                return
            }
            if status == .authorized { awaitingMotionPermission = false }
        }

        pedometer.queryPedometerData(from: stepStart, to: Date()) { [weak self] data, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.handlePedometerError(error)
                    return
                }
                guard let data else { return }
                self.applySteps(total: data.numberOfSteps.intValue, from: .query)
            }
        }
    }

    private func applySteps(total: Int, from source: StepCountModel.Source) {
        guard !hasCompleted else { return }
        let change = stepModel.ingest(total: total, from: source)
        if change.countChanged {
            count = stepModel.count
            onIncrement?(count)
        }
        hint = stepModel.hint
        if change.justCompleted {
            hasCompleted = true
            onComplete?()
            // Called from inside a pedometer callback's main-actor hop, which
            // is safe: the callback has already returned.
            stop()
        }
    }

    private func handlePedometerError(_ error: Error) {
        let nsError = error as NSError
        log.error("Pedometer: \(String(describing: error), privacy: .public)")
        let notAuthorised = nsError.domain == CMErrorDomain
            && nsError.code == Int(CMErrorMotionActivityNotAuthorized.rawValue)
        if notAuthorised || CMPedometer.authorizationStatus() == .denied {
            availability = .permissionDenied(Self.motionDeniedMessage)
            stop()
        }
    }

    /// Accelerometer-only movement detection: no permission prompt, no
    /// latency, so the screen reacts the moment the user gets up.
    private func startMovementDetection() {
        guard motionManager.isAccelerometerAvailable else { return }
        motionManager.accelerometerUpdateInterval = 1.0 / 20.0
        motionManager.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
            guard let self, let data else { return }
            MainActor.assumeIsolated {
                let a = data.acceleration
                let magnitude = sqrt(a.x * a.x + a.y * a.y + a.z * a.z)
                self.stepModel.ingestAcceleration(magnitude: magnitude, at: Date())
                if self.stepModel.isMoving != self.isMoving {
                    self.isMoving = self.stepModel.isMoving
                    self.hint = self.stepModel.hint
                }
            }
        }
    }
    #endif

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
        hint = kind == .squat
            ? "Hold the phone or pocket it, then stand up straight to begin"
            : "Hold the phone or pocket it, then get into position"

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
