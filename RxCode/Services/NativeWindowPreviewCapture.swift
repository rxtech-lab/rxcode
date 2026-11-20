import CoreMedia
import Foundation
import Observation
import ScreenCaptureKit
import os

@MainActor
@Observable
final class NativeWindowPreviewCapture: NSObject, SCContentSharingPickerObserver, SCStreamDelegate, SCStreamOutput {
    struct Window {
        let title: String
        let appName: String?
        var bundleID: String? = nil
    }

    private(set) var window: Window?
    private(set) var frame: CGImage?
    private(set) var isChoosingWindow = false
    var errorMessage: LocalizedStringResource?

    @ObservationIgnored private var stream: SCStream?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    private static let outputQueue = DispatchQueue(label: "app.rxlab.flowcy.code.window-preview")
    private static let logger = Logger(subsystem: "app.rxlab.flowcy.code", category: "WindowPreview")

    func chooseWindow() {
        guard !isChoosingWindow, stream == nil else { return }
        let picker = SCContentSharingPicker.shared
        guard !picker.isActive else {
            errorMessage = "Close the preview in the other RxCode window before choosing a new window."
            return
        }

        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = .singleWindow
        configuration.allowsChangingSelectedContent = false
        picker.defaultConfiguration = configuration
        picker.maximumStreamCount = 1
        picker.add(self)
        isChoosingWindow = true
        picker.isActive = true
        picker.present(using: .window)
    }

    func stop() {
        let activeStream = stream
        if isChoosingWindow || activeStream != nil {
            let picker = SCContentSharingPicker.shared
            picker.remove(self)
            picker.isActive = false
        }

        isChoosingWindow = false
        stream = nil
        window = nil
        frame = nil
        errorMessage = nil

        if let startTask {
            // The start task stops the stream if cancellation arrives during startCapture().
            startTask.cancel()
            self.startTask = nil
        } else if let activeStream {
            Task { try? await activeStream.stopCapture() }
        }
    }

    private func start(with filter: SCContentFilter) {
        guard filter.style == .window else {
            stop()
            errorMessage = "Choose a single window in the macOS sharing picker."
            return
        }

        let configuration = ComputerUseWindowCapture.configuration(for: filter)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 5)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: Self.outputQueue)
        } catch {
            captureFailed(error)
            return
        }

        let selectedWindow = filter.includedWindows.first
        let appName = selectedWindow?.owningApplication?.applicationName
        window = Window(
            title: selectedWindow?.title ?? appName ?? String(localized: "Shared Window"),
            appName: appName,
            bundleID: selectedWindow?.owningApplication?.bundleIdentifier
        )
        self.stream = stream
        isChoosingWindow = false
        startTask = Task { [weak self] in
            do {
                try Task.checkCancellation()
                try await stream.startCapture()
            } catch {
                guard self?.stream === stream else { return }
                self?.captureFailed(error)
                return
            }

            guard !Task.isCancelled, self?.stream === stream else {
                try? await stream.stopCapture()
                return
            }
            self?.startTask = nil
        }
    }

    private func captureFailed(_ error: any Error) {
        let error = error as NSError
        Self.logger.error("Window preview ended: \(error.domain, privacy: .public) (\(error.code))")
        stop()
        guard error.domain != SCStreamErrorDomain || error.code != SCStreamError.Code.userStopped.rawValue else { return }
        errorMessage = "Choose an available window in the macOS sharing picker to start the preview."
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        guard stream == nil else { return }
        Task { @MainActor [weak self] in
            guard let self, isChoosingWindow else { return }
            start(with: filter)
        }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        guard stream == nil else { return }
        Task { @MainActor [weak self] in
            guard let self, isChoosingWindow else { return }
            stop()
        }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        Task { @MainActor [weak self] in
            guard let self, isChoosingWindow else { return }
            captureFailed(error)
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        let streamID = ObjectIdentifier(stream)
        Task { @MainActor [weak self] in
            guard let self, self.stream.map(ObjectIdentifier.init) == streamID else { return }
            captureFailed(error)
        }
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let frame = ComputerUseWindowCapture.image(from: sampleBuffer) else { return }
        let streamID = ObjectIdentifier(stream)
        Task { @MainActor [weak self] in
            guard let self, self.stream.map(ObjectIdentifier.init) == streamID else { return }
            self.frame = frame
        }
    }
}
