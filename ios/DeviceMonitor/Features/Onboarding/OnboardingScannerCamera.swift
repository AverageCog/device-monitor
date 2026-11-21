import AVFoundation
import SwiftUI
import UIKit

/// The camera behind the invitation scanner: a capture session that reports the QR codes it sees.
///
/// AVFoundation's metadata capture rather than VisionKit's `DataScannerViewController`: the data
/// scanner needs an A12 or later and says no on other hardware, has no torch (and holds the camera,
/// so nobody else can switch it on), and brings its own highlights and guidance. This needs one
/// symbology, the app's own viewfinder, a torch for a dim room, and a session it can stop the
/// moment the sheet closes or the app leaves the foreground.
///
/// The session is configured, started and stopped on a queue of its own (`startRunning()` blocks);
/// codes are delivered on the main queue.
nonisolated final class OnboardingScannerCamera: NSObject, AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
    enum Start: Sendable, Equatable {
        case running(hasTorch: Bool)
        /// The device has no camera (the Simulator).
        case unavailable
        case failed
    }

    /// What `OnboardingScannerPreview` shows.
    let session = AVCaptureSession()

    private let queue = DispatchQueue(label: "com.devicemonitor.ios.scanner", qos: .userInitiated)
    private let onCodes: @MainActor @Sendable ([String]) -> Void
    // Both only on `queue`.
    private var device: AVCaptureDevice?
    private var isConfigured = false

    /// Whether there is a camera at all, without asking for it or starting anything.
    @MainActor static var deviceHasCamera: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    /// - Parameter onCodes: the texts of the QR codes in view, many times a second while one is.
    init(onCodes: @escaping @MainActor @Sendable ([String]) -> Void) {
        self.onCodes = onCodes
    }

    /// Starts the camera, configuring it the first time. Call only once access has been granted.
    func start() async -> Start {
        await onQueue { self.startRunning() }
    }

    /// Stops the camera and its torch. The session can be started again.
    func stop() {
        queue.async {
            self.applyTorch(false)
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    /// Returns whether the torch is on afterwards.
    func setTorch(_ isOn: Bool) async -> Bool {
        await onQueue { self.applyTorch(isOn) }
    }

    private func onQueue<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }

    private func startRunning() -> Start {
        if !isConfigured {
            guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) ?? AVCaptureDevice.default(for: .video) else {
                return .unavailable
            }
            guard configure(camera) else { return .failed }
            device = camera
            isConfigured = true
        }
        if !session.isRunning { session.startRunning() }
        guard session.isRunning else { return .failed }
        return .running(hasTorch: device.map { $0.hasTorch && $0.isTorchAvailable } ?? false)
    }

    private func configure(_ camera: AVCaptureDevice) -> Bool {
        guard let input = try? AVCaptureDeviceInput(device: camera) else { return false }
        let output = AVCaptureMetadataOutput()
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        guard session.canAddInput(input), session.canAddOutput(output) else { return false }
        session.addInput(input)
        session.addOutput(output)
        // Only known once the output is part of a session with a camera.
        guard output.availableMetadataObjectTypes.contains(.qr) else {
            session.removeOutput(output)
            session.removeInput(input)
            return false
        }
        output.metadataObjectTypes = [.qr]
        output.setMetadataObjectsDelegate(self, queue: .main)
        // An iPad sharing its screen with another app otherwise takes the camera away.
        if session.isMultitaskingCameraAccessSupported { session.isMultitaskingCameraAccessEnabled = true }
        return true
    }

    @discardableResult
    private func applyTorch(_ isOn: Bool) -> Bool {
        guard let device, device.hasTorch, device.isTorchAvailable else { return false }
        guard (device.torchMode == .on) != isOn else { return isOn }
        guard (try? device.lockForConfiguration()) != nil else { return device.torchMode == .on }
        device.torchMode = isOn ? .on : .off
        device.unlockForConfiguration()
        return isOn
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        let codes = metadataObjects.compactMap { ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }
        guard !codes.isEmpty else { return }
        // On the main queue: see `configure(_:)`.
        MainActor.assumeIsolated { onCodes(codes) }
    }
}

/// The camera's picture, filling the view.
struct OnboardingScannerPreview: UIViewRepresentable {
    let session: AVCaptureSession
    /// True once the session runs. The camera is known from then on, so the picture can be kept
    /// upright as the device turns.
    let isRunning: Bool

    func makeUIView(context: Context) -> OnboardingScannerPreviewView {
        let view = OnboardingScannerPreviewView()
        view.show(session)
        return view
    }

    func updateUIView(_ view: OnboardingScannerPreviewView, context: Context) {
        if isRunning { view.followRotation(of: session) }
    }
}

final class OnboardingScannerPreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    private var previewLayer: AVCaptureVideoPreviewLayer? { layer as? AVCaptureVideoPreviewLayer }
    private var rotation: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?

    func show(_ session: AVCaptureSession) {
        backgroundColor = .black
        previewLayer?.videoGravity = .resizeAspectFill
        previewLayer?.session = session
    }

    func followRotation(of session: AVCaptureSession) {
        guard rotation == nil, let previewLayer, let camera = session.inputs.lazy.compactMap({ ($0 as? AVCaptureDeviceInput)?.device }).first else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: camera, previewLayer: previewLayer)
        rotation = coordinator
        rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]) { [weak self] coordinator, _ in
            let angle = coordinator.videoRotationAngleForHorizonLevelPreview
            Task { @MainActor [weak self] in self?.turn(to: angle) }
        }
    }

    private func turn(to angle: CGFloat) {
        guard let connection = previewLayer?.connection, connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
    }
}
