@preconcurrency import AVFoundation
import SwiftUI
import UIKit

enum CameraStatus { case starting, ready, denied, unavailable }
enum CameraCaptureFailure: Error { case unavailable, captureFailed }

struct CameraCapture: Sendable {
    let data: Data
    let capturedAt: Date
    let timeZone: TimeZone
}

/// AVCaptureSession and its mutable capture state are confined to one serial queue.
/// The main-thread preview layer only attaches the session for display.
final class MealCameraDevice: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.example.BiteLens.camera")
    private let output = AVCapturePhotoOutput()
    private var configured = false
    private var completion: (@Sendable (Result<CameraCapture, CameraCaptureFailure>) -> Void)?
    private var capturedAt = Date.distantPast
    private var captureTimeZone = TimeZone.current

    func start(completion: @escaping @Sendable (Bool) -> Void) {
        queue.async { [self] in
            do {
                if !configured { try configure() }
                if !session.isRunning { session.startRunning() }
                completion(session.isRunning)
            } catch { completion(false) }
        }
    }

    private func configure() throws {
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw CameraCaptureFailure.unavailable
        }
        let input = try AVCaptureDeviceInput(device: camera)
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .photo
        guard session.canAddInput(input) else { throw CameraCaptureFailure.unavailable }
        session.addInput(input)
        guard session.canAddOutput(output) else {
            session.removeInput(input)
            throw CameraCaptureFailure.unavailable
        }
        session.addOutput(output)
        if let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        configured = true
    }

    func stop() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    func capture(completion: @escaping @Sendable (Result<CameraCapture, CameraCaptureFailure>) -> Void) {
        queue.async { [self] in
            guard self.completion == nil, session.isRunning, output.connection(with: .video) != nil else {
                completion(.failure(.unavailable))
                return
            }
            self.completion = completion
            capturedAt = Date()
            captureTimeZone = .current
            let settings = AVCapturePhotoSettings()
            settings.photoQualityPrioritization = .balanced
            output.capturePhoto(with: settings, delegate: self)
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: (any Error)?) {
        let bytes = error == nil ? photo.fileDataRepresentation() : nil
        queue.async { [self] in
            let callback = completion
            completion = nil
            if let bytes, !bytes.isEmpty {
                callback?(.success(CameraCapture(data: bytes, capturedAt: capturedAt, timeZone: captureTimeZone)))
            }
            else { callback?(.failure(.captureFailed)) }
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: (any Error)?) {
        guard error != nil else { return }
        queue.async { [self] in
            let callback = completion
            completion = nil
            callback?(.failure(.captureFailed))
        }
    }
}

@MainActor final class MealCameraModel: ObservableObject {
    let device = MealCameraDevice()
    @Published private(set) var status = CameraStatus.starting
    @Published private(set) var isCapturing = false
    @Published var message: String?
    private var generation = 0

    init() {
        #if DEBUG
        if UITestMode.isEnabled { status = .unavailable }
        #endif
    }

    func start() async {
        #if DEBUG
        if UITestMode.isEnabled {
            status = .unavailable
            return
        }
        #endif
        generation += 1
        let current = generation
        status = .starting
        let allowed: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: allowed = true
        case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .video)
        default: allowed = false
        }
        guard current == generation, !Task.isCancelled else { return }
        guard allowed else { status = .denied; return }
        device.start { [weak self] ready in
            Task { @MainActor in
                guard let self, current == self.generation else { return }
                self.status = ready ? .ready : .unavailable
            }
        }
    }

    func stop() {
        generation += 1
        device.stop()
        #if DEBUG
        if UITestMode.isEnabled {
            status = .unavailable
            return
        }
        #endif
        status = .starting
    }

    func capture(onCapture: @escaping @MainActor (CameraCapture) -> Void) {
        guard !isCapturing, status == .ready else { return }
        isCapturing = true
        message = nil
        device.capture { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.isCapturing = false
                switch result {
                case .success(let capture): onCapture(capture)
                case .failure: self.message = "Couldn't capture that photo. Try again, or restart the camera."
                }
            }
        }
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> CameraPreviewView {
        let view = CameraPreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }
    func updateUIView(_ uiView: CameraPreviewView, context: Context) {
        if let connection = uiView.previewLayer.connection, connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
    }
}

final class CameraPreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}
