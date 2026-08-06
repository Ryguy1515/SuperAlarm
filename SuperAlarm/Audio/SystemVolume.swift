import Foundation
import AVFoundation
#if canImport(UIKit)
import UIKit
import MediaPlayer
#endif

/// Reads and writes the device output volume.
///
/// `AVAudioSession.outputVolume` is read-only, so writing goes through the
/// hidden `UISlider` inside an off-screen `MPVolumeView` — the long-standing
/// approach for alarm apps that need to defeat a phone left at 10% volume.
/// Everything here degrades gracefully: if the slider cannot be found the app
/// simply plays at whatever the user's volume already is.
@MainActor
public final class SystemVolume {
    public static let shared = SystemVolume()

    #if canImport(UIKit)
    private var volumeView: MPVolumeView?
    private weak var slider: UISlider?
    #endif

    private init() {}

    /// Current hardware output volume, 0...1.
    public var current: Float {
        AVAudioSession.sharedInstance().outputVolume
    }

    /// Attaches the hidden volume view to the key window. Safe to call
    /// repeatedly; only the first call does work.
    public func prepare() {
        #if canImport(UIKit)
        guard volumeView == nil else { return }
        guard let window = Self.keyWindow else { return }

        // Positioned off-screen rather than hidden: MPVolumeView stops
        // vending its slider when it is not in a visible hierarchy.
        let view = MPVolumeView(frame: CGRect(x: -4_000, y: -4_000, width: 200, height: 40))
        view.alpha = 0.001
        view.isUserInteractionEnabled = false
        view.showsRouteButton = false
        window.addSubview(view)
        volumeView = view

        // The slider is created asynchronously after the view is added.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.slider = view.subviews.compactMap { $0 as? UISlider }.first
        }
        #endif
    }

    /// Raises (or lowers) the hardware volume. Returns false when the slider
    /// was unavailable, so callers can fall back to player gain alone.
    @discardableResult
    public func set(_ value: Float) -> Bool {
        #if canImport(UIKit)
        prepare()
        let clamped = max(0, min(1, value))

        let target = slider ?? volumeView?.subviews.compactMap { $0 as? UISlider }.first
        guard let target else { return false }
        slider = target

        // Setting the value on the next runloop turn is required; setting it
        // synchronously right after the view is added is silently ignored.
        DispatchQueue.main.async {
            target.value = clamped
            target.sendActions(for: .valueChanged)
        }
        return true
        #else
        return false
        #endif
    }

    /// Ramps the hardware volume from its current level to `target`.
    public func ramp(to target: Float, over duration: TimeInterval, steps: Int = 20) {
        guard duration > 0, steps > 0 else {
            set(target)
            return
        }
        let start = current
        let interval = duration / Double(steps)
        for step in 1...steps {
            let progress = Float(step) / Float(steps)
            let value = start + (target - start) * progress
            DispatchQueue.main.asyncAfter(deadline: .now() + interval * Double(step)) { [weak self] in
                self?.set(value)
            }
        }
    }

    public func detach() {
        #if canImport(UIKit)
        volumeView?.removeFromSuperview()
        volumeView = nil
        slider = nil
        #endif
    }

    #if canImport(UIKit)
    static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
            ?? UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first
    }
    #endif
}
