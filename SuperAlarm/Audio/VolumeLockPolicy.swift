import Foundation

/// The decision logic behind the volume lock, kept free of UIKit so it can be
/// tested without a device.
///
/// The lock has one job: whenever the hardware output volume is observed
/// below the level the alarm is entitled to, push it straight back. The
/// observation comes from key-value observing on `AVAudioSession.outputVolume`
/// (a button press is reported within a frame) with a slow timer as a safety
/// net; the push goes through the hidden `MPVolumeView` slider.
public struct VolumeLockPolicy: Equatable, Sendable {
    /// Level the lock enforces, 0...1.
    public var target: Float
    /// How far below the target the observed level may drift before the lock
    /// reacts. Wide enough to ignore float noise, narrow enough that a single
    /// volume-button step (1/16 ≈ 0.0625) is always caught.
    public var tolerance: Float = 0.02

    /// Lowest level the lock will ever hold when "override device volume" is
    /// off. Locking the volume at zero would defend a silent alarm, which is
    /// no alarm at all.
    public static let floor: Float = 0.25

    /// Interval of the safety-net timer that backs up the observer.
    public static let safetyNetInterval: TimeInterval = 1.0

    public init(target: Float, tolerance: Float = 0.02) {
        self.target = max(0, min(1, target))
        self.tolerance = tolerance
    }

    /// The level to hold when the alarm starts.
    ///
    /// - Parameters:
    ///   - overridesSystemVolume: the alarm's "override device volume" setting.
    ///   - current: hardware volume at the moment the alarm starts.
    public static func initialTarget(overridesSystemVolume: Bool, current: Float) -> Float {
        if overridesSystemVolume { return 1.0 }
        return max(floor, min(1, current))
    }

    /// Where the lock target sits partway through a gradual ramp. The lock
    /// follows the ramp rather than fighting it, so the hardware volume rises
    /// smoothly instead of snapping to full the moment the lock engages.
    public static func rampedTarget(start: Float, end: Float, progress: Double) -> Float {
        let clamped = Float(max(0, min(1, progress)))
        return start + (end - start) * clamped
    }

    /// True when the observed level has been lowered and must be restored.
    public func shouldRestore(observed: Float) -> Bool {
        observed < target - tolerance
    }
}
