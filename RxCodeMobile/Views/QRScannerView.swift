import SwiftUI
import AVFoundation
import os

private let scannerLogger = Logger(subsystem: "com.claudework", category: "QRScanner")

/// Presents the rear camera and reports the first detected QR string.
struct QRScannerView: UIViewControllerRepresentable {
    let onResult: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerVC {
        scannerLogger.info("makeUIViewController")
        let vc = ScannerVC()
        vc.onResult = onResult
        return vc
    }

    func updateUIViewController(_ uiViewController: ScannerVC, context: Context) {}

    final class ScannerVC: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onResult: ((String) -> Void)?
        private let session = AVCaptureSession()
        private var previewLayer: AVCaptureVideoPreviewLayer?

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black

            let authStatus = AVCaptureDevice.authorizationStatus(for: .video)
            scannerLogger.info("viewDidLoad authStatus=\(authStatus.rawValue, privacy: .public)")

            switch authStatus {
            case .authorized:
                configureSession()
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                    scannerLogger.info("camera access granted=\(granted, privacy: .public)")
                    DispatchQueue.main.async {
                        if granted { self?.configureSession() }
                    }
                }
            case .denied, .restricted:
                scannerLogger.error("camera access denied/restricted")
            @unknown default:
                scannerLogger.error("camera access unknown status")
            }
        }

        private func configureSession() {
            guard let device = AVCaptureDevice.default(for: .video) else {
                scannerLogger.error("no default video device")
                return
            }
            let input: AVCaptureDeviceInput
            do {
                input = try AVCaptureDeviceInput(device: device)
            } catch {
                scannerLogger.error("device input error: \(error.localizedDescription, privacy: .public)")
                return
            }
            guard session.canAddInput(input) else {
                scannerLogger.error("cannot add camera input")
                return
            }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            if session.canAddOutput(output) {
                session.addOutput(output)
                output.setMetadataObjectsDelegate(self, queue: .main)
                output.metadataObjectTypes = [.qr]
                scannerLogger.info("metadata output configured for .qr")
            } else {
                scannerLogger.error("cannot add metadata output")
            }
            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.videoGravity = .resizeAspectFill
            preview.frame = view.layer.bounds
            view.layer.addSublayer(preview)
            previewLayer = preview
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.session.startRunning()
                scannerLogger.info("capture session started")
            }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            previewLayer?.frame = view.layer.bounds
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            if session.isRunning {
                session.stopRunning()
                scannerLogger.info("capture session stopped (viewWillDisappear)")
            }
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput,
                            didOutput metadataObjects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            scannerLogger.debug("metadataOutput count=\(metadataObjects.count, privacy: .public)")
            guard let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  let value = obj.stringValue else {
                scannerLogger.debug("first metadata object had no string value")
                return
            }
            scannerLogger.info("QR detected length=\(value.count, privacy: .public)")
            session.stopRunning()
            onResult?(value)
        }
    }
}
