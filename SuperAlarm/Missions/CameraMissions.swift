import Foundation
// AVCaptureSession is not Sendable but is safe to hand to the session queue,
// which is the pattern Apple's own sample code uses.
@preconcurrency import AVFoundation
import Combine
import Vision
import CoreImage
import os.log
#if canImport(UIKit)
import UIKit
import SwiftUI
#endif

// MARK: - Camera permission

public enum CameraAccess {
    public static var status: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .video)
    }

    public static func request() async -> Bool {
        switch status {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }
}

// MARK: - Shared capture plumbing

/// Common session setup for the two camera missions.
@MainActor
public class CaptureController: NSObject, ObservableObject {
    @Published public private(set) var isRunning = false
    @Published public private(set) var errorMessage: String?

    public let session = AVCaptureSession()
    let sessionQueue = DispatchQueue(label: "io.superalarm.capture")
    let log = Logger(subsystem: "io.superalarm", category: "camera")

    private var isConfigured = false
    private var device: AVCaptureDevice?

    /// True while the torch is on. Only the back camera has one.
    @Published public private(set) var isTorchOn = false
    public var hasTorch: Bool { device?.hasTorch ?? false }

    /// Subclasses attach their outputs here, from inside the session's
    /// configuration transaction.
    func configureOutputs() {}

    /// Lights the scene for a 6am object scan. Ignored on cameras without a
    /// torch, and switched off with the session.
    public func setTorch(_ on: Bool) {
        guard let device, device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            device.torchMode = on ? .on : .off
            device.unlockForConfiguration()
            isTorchOn = on
        } catch {
            log.error("Torch: \(String(describing: error), privacy: .public)")
        }
    }

    /// Which camera to open. Scanning missions point away from you; pose
    /// missions point at you.
    var cameraPosition: AVCaptureDevice.Position { .back }

    /// Capture preset. Pose detection pins this so the overlay knows the
    /// frame's aspect ratio without having to query it.
    var preset: AVCaptureSession.Preset { .high }

    /// Configuration happens on the main actor — it is a one-off and touches
    /// `@Published` state — while `startRunning()` is dispatched off it,
    /// because that call blocks.
    public func start() async {
        guard await CameraAccess.request() else {
            errorMessage = "Camera access is off. Enable it in Settings › Privacy › Camera."
            return
        }
        errorMessage = nil

        if !isConfigured {
            // Only latch success. Marking it configured after a failure would
            // mean a camera that was unavailable once — say the permission
            // sheet was still up — could never be retried.
            guard configureSession() else { return }
            isConfigured = true
        }

        let session = self.session
        sessionQueue.async {
            if !session.isRunning { session.startRunning() }
        }
        isRunning = true
    }

    public func stop() {
        if isTorchOn { setTorch(false) }
        let session = self.session
        sessionQueue.async {
            if session.isRunning { session.stopRunning() }
        }
        isRunning = false
    }

    /// Returns false when no usable camera could be attached, leaving
    /// `errorMessage` set for the caller to surface.
    private func configureSession() -> Bool {
        session.beginConfiguration()
        session.sessionPreset = preset
        // The alarm owns the audio session. Left at its default the capture
        // session reconfigures it when the camera opens, which could undo
        // the playback category the siren depends on.
        session.automaticallyConfiguresApplicationAudioSession = false

        guard
            let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: cameraPosition)
                ?? AVCaptureDevice.default(for: .video),
            let input = try? AVCaptureDeviceInput(device: device),
            session.canAddInput(input)
        else {
            session.commitConfiguration()
            errorMessage = "No usable camera was found."
            return false
        }
        session.addInput(input)
        self.device = device

        configureOutputs()
        session.commitConfiguration()
        return true
    }
}

// MARK: - Barcode / QR mission

@MainActor
public final class BarcodeMissionController: CaptureController, AVCaptureMetadataOutputObjectsDelegate {
    /// When set, only this exact payload counts. Nil means registration mode,
    /// where any scanned code is accepted and reported back.
    public var expectedPayload: String?

    @Published public private(set) var lastScanned: String?
    /// Set when a code was read but did not match the registered one.
    @Published public private(set) var mismatchMessage: String?

    public var onMatch: ((String) -> Void)?

    private let metadataOutput = AVCaptureMetadataOutput()
    private var lastHandledAt: Date = .distantPast
    private var hasMatched = false

    override func configureOutputs() {
        guard session.canAddOutput(metadataOutput) else { return }
        session.addOutput(metadataOutput)
        metadataOutput.setMetadataObjectsDelegate(self, queue: sessionQueue)

        // Everything a household object is likely to carry.
        let wanted: [AVMetadataObject.ObjectType] = [
            .qr, .ean13, .ean8, .upce, .code128, .code39, .code39Mod43,
            .code93, .pdf417, .aztec, .dataMatrix, .interleaved2of5, .itf14,
        ]
        metadataOutput.metadataObjectTypes = wanted.filter {
            metadataOutput.availableMetadataObjectTypes.contains($0)
        }
    }

    public nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard
            let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
            let value = object.stringValue
        else { return }

        Task { @MainActor in self.handle(code: value) }
    }

    private func handle(code: String) {
        guard !hasMatched else { return }
        // Metadata arrives many times a second; throttle the UI churn.
        guard Date().timeIntervalSince(lastHandledAt) > 0.3 else { return }
        lastHandledAt = Date()

        lastScanned = code

        guard let expected = expectedPayload else {
            // Registration mode — any code will do.
            hasMatched = true
            HapticEngine.shared.success()
            onMatch?(code)
            return
        }

        if code == expected {
            hasMatched = true
            mismatchMessage = nil
            HapticEngine.shared.success()
            onMatch?(code)
        } else {
            mismatchMessage = "That's a different code. Find the one you registered."
            HapticEngine.shared.warning()
        }
    }

    public func reset() {
        hasMatched = false
        mismatchMessage = nil
        lastScanned = nil
    }
}

// MARK: - Object scan mission

/// Matches the live camera against a registered reference photo using Vision
/// feature prints, which compare images by learned visual similarity rather
/// than raw pixels — so lighting and angle can change and it still matches.
@MainActor
public final class ObjectMissionController: CaptureController, AVCaptureVideoDataOutputSampleBufferDelegate {
    /// 0...1, higher means a closer match.
    @Published public private(set) var similarity: Double = 0
    @Published public private(set) var hasMatched = false
    @Published public private(set) var referenceLoaded = false

    /// Feature-print distance under which the object counts as recognised.
    /// Vision distances run roughly 0 (identical) to ~2 (unrelated).
    public var matchDistanceThreshold: Float = 0.62 {
        didSet { scan.threshold = matchDistanceThreshold }
    }

    public var onMatch: (() -> Void)?
    /// Registration mode captures a reference instead of matching one.
    public var onCapturedReference: ((Data) -> Void)?
    public var isRegistrationMode = false {
        didSet { scan.isRegistrationMode = isRegistrationMode }
    }

    private let videoOutput = AVCaptureVideoDataOutput()
    /// Everything the frame callback needs, guarded by a lock so the
    /// expensive work stays on the capture queue and only results reach the
    /// main actor. Rendering and feature printing every frame on the main
    /// thread stuttered the UI and starved the capture pool.
    private let scan = ScanState()

    private final class ScanState: @unchecked Sendable {
        let ciContext = CIContext(options: [.useSoftwareRenderer: false])
        private let lock = NSLock()
        private var _threshold: Float = 0.62
        private var _referencePrint: VNFeaturePrintObservation?
        private var _hasMatched = false
        private var _wantsReferenceCapture = false
        private var _isRegistrationMode = false
        private var _lastSampleAt: Date = .distantPast
        private var _consecutiveGoodFrames = 0

        /// Require a few consecutive good frames so a lucky frame cannot pass.
        let requiredGoodFrames = 3

        var referencePrint: VNFeaturePrintObservation? {
            get { lock.lock(); defer { lock.unlock() }; return _referencePrint }
            set { lock.lock(); _referencePrint = newValue; lock.unlock() }
        }
        var threshold: Float {
            get { lock.lock(); defer { lock.unlock() }; return _threshold }
            set { lock.lock(); _threshold = newValue; lock.unlock() }
        }
        var hasMatched: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _hasMatched }
            set { lock.lock(); _hasMatched = newValue; lock.unlock() }
        }
        var isRegistrationMode: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _isRegistrationMode }
            set { lock.lock(); _isRegistrationMode = newValue; lock.unlock() }
        }
        func requestReferenceCapture() {
            lock.lock(); _wantsReferenceCapture = true; lock.unlock()
        }
        /// Consumes the capture request, if one is pending.
        func takeReferenceCaptureRequest() -> Bool {
            lock.lock(); defer { lock.unlock() }
            let wanted = _wantsReferenceCapture
            _wantsReferenceCapture = false
            return wanted
        }
        /// True if enough time has passed for another sample.
        func shouldSample(now: Date, interval: TimeInterval) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard now.timeIntervalSince(_lastSampleAt) > interval else { return false }
            _lastSampleAt = now
            return true
        }
        /// Records a frame result; returns true when the match is confirmed.
        func recordFrame(isGood: Bool) -> Bool {
            lock.lock(); defer { lock.unlock() }
            if isGood {
                _consecutiveGoodFrames += 1
                if _consecutiveGoodFrames >= requiredGoodFrames {
                    _hasMatched = true
                    return true
                }
            } else {
                _consecutiveGoodFrames = 0
            }
            return false
        }
        func reset() {
            lock.lock()
            _hasMatched = false
            _consecutiveGoodFrames = 0
            lock.unlock()
        }
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

    /// Loads the stored reference image and computes its feature print.
    public func loadReference(imageID: String) {
        guard let data = MissionAssetStore.shared.imageData(id: imageID) else {
            log.error("Reference image \(imageID, privacy: .public) missing")
            referenceLoaded = false
            return
        }
        loadReference(data: data)
    }

    public func loadReference(data: Data) {
        #if canImport(UIKit)
        guard let image = UIImage(data: data), let cgImage = image.cgImage else {
            referenceLoaded = false
            return
        }
        let print = Self.featurePrint(for: cgImage)
        scan.referencePrint = print
        referenceLoaded = print != nil
        #endif
    }

    /// Asks for the next frame to be saved as the reference photo.
    public func captureReference() {
        scan.requestReferenceCapture()
    }

    public func reset() {
        scan.reset()
        hasMatched = false
        similarity = 0
    }

    /// Runs on the capture queue. Only the outcome hops to the main actor.
    public nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard !scan.hasMatched else { return }
        // Feature prints are expensive; three frames a second is plenty.
        guard scan.shouldSample(now: Date(), interval: 0.33) else { return }
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let image = CIImage(cvPixelBuffer: buffer)
        guard let cgImage = scan.ciContext.createCGImage(image, from: image.extent) else { return }

        if scan.takeReferenceCaptureRequest() {
            #if canImport(UIKit)
            // The back camera delivers landscape buffers; the phone was held
            // upright, so the saved photo is rotated to match.
            let photo = UIImage(cgImage: cgImage, scale: 1, orientation: .right)
            guard let data = photo.jpegData(compressionQuality: 0.85) else { return }
            let print = Self.featurePrint(for: cgImage)
            scan.referencePrint = print
            Task { @MainActor in self.didCaptureReference(data: data, hasPrint: print != nil) }
            #endif
            return
        }

        guard !scan.isRegistrationMode, let reference = scan.referencePrint else { return }
        guard let candidate = Self.featurePrint(for: cgImage) else { return }

        var distance = Float.greatestFiniteMagnitude
        do {
            try reference.computeDistance(&distance, to: candidate)
        } catch {
            return
        }

        let isGood = distance <= scan.threshold
        let matched = scan.recordFrame(isGood: isGood)
        // Map distance onto a 0...1 confidence for the on-screen meter.
        let normalised = max(0, min(1, 1 - Double(distance) / 1.4))
        Task { @MainActor in self.didMeasure(similarity: normalised, matched: matched) }
    }

    private func didCaptureReference(data: Data, hasPrint: Bool) {
        referenceLoaded = hasPrint
        onCapturedReference?(data)
    }

    private func didMeasure(similarity value: Double, matched: Bool) {
        similarity = value
        if matched, !hasMatched {
            hasMatched = true
            onMatch?()
        }
    }

    nonisolated static func featurePrint(for cgImage: CGImage) -> VNFeaturePrintObservation? {
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        return request.results?.first as? VNFeaturePrintObservation
    }
}

// MARK: - Camera preview

#if canImport(UIKit)
/// Live camera feed for the mission screens.
public struct CameraPreview: UIViewRepresentable {
    public let session: AVCaptureSession

    public init(session: AVCaptureSession) {
        self.session = session
    }

    public func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        return view
    }

    public func updateUIView(_ uiView: PreviewView, context: Context) {
        if uiView.videoPreviewLayer.session !== session {
            uiView.videoPreviewLayer.session = session
        }
    }

    public final class PreviewView: UIView {
        public override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        public var videoPreviewLayer: AVCaptureVideoPreviewLayer {
            // Safe: `layerClass` guarantees the type.
            layer as! AVCaptureVideoPreviewLayer
        }
    }
}
#endif
