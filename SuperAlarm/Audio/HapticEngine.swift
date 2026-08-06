import Foundation
import AudioToolbox
#if canImport(UIKit)
import UIKit
#endif

/// Vibration while the alarm rings, plus the small UI feedback taps used
/// throughout the app.
@MainActor
public final class HapticEngine {
    public static let shared = HapticEngine()

    private var vibrationTimer: Timer?
    /// Set false by app settings to mute all UI feedback.
    public var uiFeedbackEnabled: Bool = true

    private init() {}

    // MARK: Alarm vibration

    /// Starts the repeating alarm buzz. Uses the system vibrate sound rather
    /// than Core Haptics because it is the only path that keeps firing while
    /// the screen is locked.
    public func startAlarmVibration(interval: TimeInterval = 1.4) {
        stopAlarmVibration()
        fire()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.fire() }
        }
        // .common keeps it running while the user drags a slider or scrolls.
        RunLoop.main.add(timer, forMode: .common)
        vibrationTimer = timer
    }

    public func stopAlarmVibration() {
        vibrationTimer?.invalidate()
        vibrationTimer = nil
    }

    public var isVibrating: Bool { vibrationTimer != nil }

    private func fire() {
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
    }

    // MARK: UI feedback

    #if canImport(UIKit)
    public func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .medium) {
        guard uiFeedbackEnabled else { return }
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.prepare()
        generator.impactOccurred()
    }

    public func selection() {
        guard uiFeedbackEnabled else { return }
        let generator = UISelectionFeedbackGenerator()
        generator.prepare()
        generator.selectionChanged()
    }

    public func notify(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        guard uiFeedbackEnabled else { return }
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(type)
    }

    public func success() { notify(.success) }
    public func warning() { notify(.warning) }
    public func failure() { notify(.error) }
    #else
    public func impact(_ style: Int = 0) {}
    public func selection() {}
    public func success() {}
    public func warning() {}
    public func failure() {}
    #endif
}
