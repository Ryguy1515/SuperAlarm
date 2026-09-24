import Foundation
import AVFoundation
import os.log
#if canImport(UIKit)
import UIKit
import MediaPlayer
#endif

/// Reads and writes the device output volume.
///
/// `AVAudioSession.outputVolume` is read-only, so writing goes through the
/// hidden `UISlider` inside an off-screen `MPVolumeView` — the long-standing
/// approach for alarm apps that need to defeat a phone left at 10% volume.
///
/// The view is attached at app launch rather than at ring time: the slider is
/// vended asynchronously after the view joins a window, and an alarm that
/// fires into a `fullScreenCover` a few hundred milliseconds later must not
/// find it missing. Everything degrades gracefully — if the slider cannot be
/// found the app plays at whatever volume the user already has, and the
/// Diagnostics screen says so.
@MainActor
public final class SystemVolume {
    public static let shared = SystemVolume()

    private let log = Logger(subsystem: "io.superalarm", category: "volume")

    #if canImport(UIKit)
    private var volumeView: MPVolumeView?
    private weak var slider: UISlider?
    private var retriesLeft = 0
    /// True while a lookup chain is scheduled, so repeated `prepare()` calls
    /// (one per volume write) do not each start a chain and burn the retry
    /// budget between them.
    private var isLookingUp = false
    #endif

    /// Number of successful writes since launch, for diagnostics.
    public private(set) var writeCount = 0
    /// Number of writes that found no slider.
    public private(set) var failedWriteCount = 0

    private init() {}

    /// Current hardware output volume, 0...1.
    ///
    /// Read from the hidden slider when it is available: on iOS 18
    /// `AVAudioSession.outputVolume` can report a stale value after the
    /// session is deactivated and reactivated, and the slider tracks the real
    /// level. The session property is the fallback.
    public var current: Float {
        let session = AVAudioSession.sharedInstance().outputVolume
        #if canImport(UIKit)
        if let slider = findSlider(), slider.value > 0 {
            return slider.value
        }
        #endif
        return session
    }

    /// True once the hidden slider has been found and can be written to.
    public var isReady: Bool {
        #if canImport(UIKit)
        return findSlider() != nil
        #else
        return false
        #endif
    }

    /// One-line status for the Diagnostics screen.
    public var diagnosticStatus: String {
        #if canImport(UIKit)
        if isReady {
            return failedWriteCount == 0 ? "Ready" : "Ready (\(failedWriteCount) failed writes)"
        }
        return volumeView == nil ? "Not attached — no window" : "Slider not found — lock unavailable"
        #else
        return "Unavailable on this platform"
        #endif
    }

    /// Attaches the hidden volume view to the key window. Safe to call
    /// repeatedly; it only does work until the slider has been found.
    public func prepare() {
        #if canImport(UIKit)
        if volumeView != nil, findSlider() != nil { return }
        guard let window = Self.keyWindow else {
            log.error("Volume control: no key window yet, will retry")
            return
        }

        if volumeView == nil {
            // Positioned off-screen rather than hidden: MPVolumeView stops
            // vending its slider when it is not in a visible hierarchy.
            let view = MPVolumeView(frame: CGRect(x: -4_000, y: -4_000, width: 200, height: 40))
            view.alpha = 0.001
            view.isUserInteractionEnabled = false
            view.showsVolumeSlider = true
            window.addSubview(view)
            volumeView = view
            retriesLeft = 6
        }

        guard !isLookingUp else { return }
        isLookingUp = true
        scheduleSliderLookup(after: 0.1)
        #endif
    }

    #if canImport(UIKit)
    /// The slider is created asynchronously after the view is added, and on
    /// some launches it takes more than one runloop turn. Keep looking for a
    /// few seconds, then log loudly so the failure is visible in Diagnostics.
    private func scheduleSliderLookup(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.findSlider() != nil {
                    self.isLookingUp = false
                    self.log.info("Volume control ready")
                    return
                }
                guard self.retriesLeft > 0 else {
                    self.isLookingUp = false
                    self.log.error("Volume control: MPVolumeView never vended its slider; volume lock unavailable")
                    return
                }
                self.retriesLeft -= 1
                self.scheduleSliderLookup(after: min(2.0, delay * 2))
            }
        }
    }

    private func findSlider() -> UISlider? {
        if let slider { return slider }
        let found = volumeView?.subviews.compactMap { $0 as? UISlider }.first
        slider = found
        return found
    }
    #endif

    /// Raises (or lowers) the hardware volume. Returns false when the slider
    /// was unavailable, so callers can fall back to player gain alone.
    @discardableResult
    public func set(_ value: Float) -> Bool {
        #if canImport(UIKit)
        prepare()
        let clamped = max(0, min(1, value))

        guard let target = findSlider() else {
            failedWriteCount += 1
            return false
        }
        writeCount += 1

        // Setting the value on the next runloop turn is required; setting it
        // synchronously right after the view is added is silently ignored.
        DispatchQueue.main.async {
            Task { @MainActor in
                target.value = clamped
                target.sendActions(for: .valueChanged)
            }
        }
        return true
        #else
        return false
        #endif
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
