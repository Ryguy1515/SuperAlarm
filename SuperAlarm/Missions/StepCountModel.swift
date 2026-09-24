import Foundation

/// The counting model behind the walking mission, separated from Core Motion
/// so the awkward parts of the pedometer can be tested with simulated data.
///
/// `CMPedometer` is a poor fit for a live counter on its own: it delivers
/// cumulative totals in batches every few seconds, the first batch can take
/// longer, and a query for the same window can return a different (usually
/// higher) number than the last live update. The model reconciles every
/// source into one count that only ever goes up, and separately tracks
/// whether the phone is physically moving so the screen can react before the
/// first batch lands.
public struct StepCountModel: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        /// A cumulative total from `startUpdates(from:)`.
        case liveUpdate
        /// A cumulative total from `queryPedometerData(from:to:)`.
        case query
    }

    public let goal: Int
    /// Steps counted so far, clamped to the goal. Never decreases.
    public private(set) var count: Int = 0
    /// True once the goal has been reached. Set exactly once.
    public private(set) var isComplete = false
    /// Highest raw total seen from each source, for diagnostics.
    public private(set) var lastLiveTotal: Int = 0
    public private(set) var lastQueryTotal: Int = 0
    /// True while the accelerometer says the phone is being carried.
    public private(set) var isMoving = false
    /// When the most recent movement was detected.
    public private(set) var lastMovementAt: Date?

    /// Accelerometer magnitude deviation from 1 g that counts as movement.
    /// Walking with a phone in hand or pocket sits comfortably above this;
    /// lying in bed fidgeting does not.
    public static let movementThreshold: Double = 0.12
    /// How long "moving" stays true after the last strong sample.
    public static let movementHold: TimeInterval = 1.2
    /// How often the model expects a fresh pedometer query.
    public static let queryInterval: TimeInterval = 1.0

    public init(goal: Int) {
        self.goal = max(1, goal)
    }

    /// Result of feeding a new total in.
    public struct Change: Equatable, Sendable {
        public var countChanged: Bool
        public var justCompleted: Bool
    }

    /// Feeds a cumulative step total from one of the pedometer's sources.
    /// Returns what changed so the caller can fire haptics or completion.
    @discardableResult
    public mutating func ingest(total: Int, from source: Source) -> Change {
        let sanitized = max(0, total)
        switch source {
        case .liveUpdate: lastLiveTotal = max(lastLiveTotal, sanitized)
        case .query: lastQueryTotal = max(lastQueryTotal, sanitized)
        }

        let best = min(goal, max(lastLiveTotal, lastQueryTotal))
        guard best > count else {
            return Change(countChanged: false, justCompleted: false)
        }
        count = best

        let completedNow = !isComplete && count >= goal
        if completedNow { isComplete = true }
        return Change(countChanged: true, justCompleted: completedNow)
    }

    /// Feeds one accelerometer sample. `magnitude` is the length of the
    /// acceleration vector in g, so a phone at rest reads about 1.0.
    public mutating func ingestAcceleration(magnitude: Double, at time: Date) {
        if abs(magnitude - 1.0) >= Self.movementThreshold {
            lastMovementAt = time
            isMoving = true
        } else if let last = lastMovementAt, time.timeIntervalSince(last) > Self.movementHold {
            isMoving = false
        } else if lastMovementAt == nil {
            isMoving = false
        }
    }

    public var remaining: Int { max(0, goal - count) }

    public var progress: Double { Double(count) / Double(goal) }

    /// Coaching line for the screen. The counter itself lags a few seconds
    /// behind the feet, so this is where the user learns the phone noticed.
    public var hint: String {
        if isComplete { return "Done" }
        if count == 0 {
            return isMoving ? "Movement detected — counting…" : "Get up and start walking"
        }
        if isMoving { return "\(remaining) to go — keep walking" }
        return "\(remaining) to go"
    }
}
