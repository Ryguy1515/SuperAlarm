import Foundation
import AVFoundation
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

    /// Subclasses attach their outputs here. Called on `sessionQueue` inside a
    /// configuration transaction.
    func configureOutputs() {}

    public func start() async {
        guard await CameraAccess.request() else {
            errorMessage = "Camera access is off. Enable it in Settings › Privacy › Camera."
            return
        }
        errorMessage = nil

        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.isConfigured {
                self.configureSession()
                self.isConfigured = true
            }
            if !self.session.isRunning {
                self.session.startRunning()
            }
            Task { @MainActor in self.isRunning = self.session.isRunning }
        }
    }

    public func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning { self.session.stopRunning() }
            Task { @MainActor in self.isRunning = false }
        }
    }

    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .high

        guard
            let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(for: .video),
            let input = try? AVCaptureDeviceInput(device: device),
            session.canAddInput(input)
        else {
            session.commitConfiguration()
            Task { @MainActor in self.errorMessage = "No usable camera was found." }
            return
        }
        session.addInput(input)

        configureOutputs()
        session.commitConfiguration()
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
    public var matchDistanceThreshold: Float = 0.62

    public var onMatch: (() -> Void)?
    /// Registration mode captures a reference instead of matching one.
    public var onCapturedReference: ((Data) -> Void)?
    public var isRegistrationMode = false

    private let videoOutput = AVCaptureVideoDataOutput()
    private var referencePrint: VNFeaturePrintObservation?
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private var lastSampleAt: Date = .distantPast
    private var wantsReferenceCapture = false
    /// Require a few consecutive good frames so a lucky frame cannot pass.
    private var consecutiveGoodFrames = 0
    private let requiredGoodFrames = 3

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
        referencePrint = Self.featurePrint(for: cgImage)
        referenceLoaded = referencePrint != nil
        #endif
    }

    /// Asks for the next frame to be saved as the reference photo.
    public func captureReference() {
        wantsReferenceCapture = true
    }

    public func reset() {
        hasMatched = false
        similarity = 0
        consecutiveGoodFrames = 0
    }

    public nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let image = CIImage(cvPixelBuffer: buffer)
        Task { @MainActor in self.process(image) }
    }

    private func process(_ image: CIImage) {
        guard !hasMatched else { return }
        // Feature prints are expensive; three frames a second is plenty.
        guard Date().timeIntervalSince(lastSampleAt) > 0.33 else { return }
        lastSampleAt = Date()

        guard let cgImage = ciContext.createCGImage(image, from: image.extent) else { return }

        if wantsReferenceCapture {
            wantsReferenceCapture = false
            #if canImport(UIKit)
            if let data = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.85) {
                referencePrint = Self.featurePrint(for: cgImage)
                referenceLoaded = referencePrint != nil
                HapticEngine.shared.success()
                onCapturedReference?(data)
            }
            #endif
            return
        }

        guard !isRegistrationMode, let reference = referencePrint else { return }
        guard let candidate = Self.featurePrint(for: cgImage) else { return }

        var distance = Float.greatestFiniteMagnitude
        do {
            try reference.computeDistance(&distance, to: candidate)
        } catch {
            log.error("Feature distance failed: \(String(describing: error), privacy: .public)")
            return
        }

        // Map distance onto a 0...1 confidence for the on-screen meter.
        let normalised = max(0, min(1, 1 - Double(distance) / 1.4))
        similarity = normalised

        if distance <= matchDistanceThreshold {
            consecutiveGoodFrames += 1
            if consecutiveGoodFrames >= requiredGoodFrames {
                hasMatched = true
                HapticEngine.shared.success()
                onMatch?()
            }
        } else {
            consecutiveGoodFrames = 0
        }
    }

    static func featurePrint(for cgImage: CGImage) -> VNFeaturePrintObservation? {
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
