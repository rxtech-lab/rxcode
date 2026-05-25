import SwiftUI
import PhotosUI
import RxCodeSync
import os
import TipKit

private let onboardingLogger = Logger(subsystem: "com.claudework", category: "Onboarding")

struct OnboardingView: View {
    @EnvironmentObject private var state: MobileAppState
    @Environment(\.dismiss) private var dismiss
    let showsCancelButton: Bool
    let onPairingCompleted: (() -> Void)?
    @State private var showScanner = false
    @State private var showScanOptions = false
    @State private var photoPickerShown = false
    @State private var photoItem: PhotosPickerItem?
    @State private var pairingError: String?
    @State private var displayName: String = UIDevice.current.name
    @FocusState private var nameFocused: Bool

    init(
        showsCancelButton: Bool = false,
        onPairingCompleted: (() -> Void)? = nil
    ) {
        self.showsCancelButton = showsCancelButton
        self.onPairingCompleted = onPairingCompleted
    }

    var body: some View {
        ZStack {
            BackdropOrbs()

            ScrollView {
                VStack(spacing: 28) {
                    hero
                    instructions
                    deviceNameField
                    scanButton
                    if let err = combinedError {
                        errorBanner(err)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 40)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .disabled(state.pairingStatus == .inProgress)
            .blur(radius: state.pairingStatus == .inProgress ? 6 : 0)

            if state.pairingStatus == .inProgress {
                pairingOverlay
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.25), value: pairingError)
        .animation(.smooth(duration: 0.25), value: state.pairingStatus)
        .confirmationDialog(
            "Add a QR code",
            isPresented: $showScanOptions,
            titleVisibility: .visible
        ) {
            Button {
                MobileHaptics.buttonTap()
                showScanner = true
            } label: {
                Label("Scan with Camera", systemImage: "camera.viewfinder")
            }

            Button {
                MobileHaptics.buttonTap()
                // Trigger photo picker by toggling state in next runloop tick
                // so the dialog can dismiss first.
                DispatchQueue.main.async { presentPhotoPicker() }
            } label: {
                Label("Choose from Photos", systemImage: "photo.on.rectangle")
            }

            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Scan the QR code shown on your Mac, or pick a screenshot from your library.")
        }
        .sheet(isPresented: $showScanner) {
            NavigationStack {
                QRScannerView { result in
                    showScanner = false
                    handleScan(result)
                }
                .ignoresSafeArea()
                .background(Color.black)
                .navigationTitle("Scan QR")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.black, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbarColorScheme(.dark, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            MobileHaptics.buttonTap()
                            showScanner = false
                        } label: {
                            Image(systemName: "xmark")
                                .font(.body.weight(.semibold))
                        }
                        .tint(.white)
                    }
                }
            }
            .preferredColorScheme(.dark)
            .mobileSheetPresentation()
        }
        .photosPicker(
            isPresented: $photoPickerShown,
            selection: $photoItem,
            matching: .images,
            photoLibrary: .shared()
        )
        .onChange(of: photoItem) { _, newItem in
            guard let newItem else { return }
            Task { await loadAndDecode(item: newItem) }
        }
        .toolbar {
            if showsCancelButton {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        MobileHaptics.buttonTap()
                        state.cancelPairing()
                        dismiss()
                    }
                }
            }
        }
    }

    private func presentPhotoPicker() { photoPickerShown = true }

    // MARK: - Sections

    private var hero: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [
                            Color.accentColor.opacity(0.22),
                            Color.accentColor.opacity(0.08)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .frame(width: 112, height: 112)
                    .glassEffect(.regular.interactive(), in: .circle)

                Image(systemName: "laptopcomputer.and.iphone")
                    .font(.system(size: 46, weight: .bold))
                    .foregroundStyle(Color.accentColor)
            }
            .shadow(color: Color.accentColor.opacity(0.25), radius: 18, y: 10)

            VStack(spacing: 6) {
                Text("Pair with your Mac")
                    .font(.title.weight(.semibold))
                Text("Securely link this device to RxCode in seconds.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.top, 12)
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 14) {
            stepRow(number: 1, text: "Open **RxCode** on your Mac.")
            stepRow(number: 2, text: "Go to **Settings → Mobile** and tap *Pair new device*.")
            stepRow(number: 3, text: "Scan the QR code shown on your Mac with this app.")
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }

    private func stepRow(number: Int, text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 26, height: 26)
                .glassEffect(.regular, in: .circle)
            Text(text)
                .font(.callout)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var deviceNameField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Device name", systemImage: "tag")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Image(systemName: "iphone")
                    .foregroundStyle(.secondary)
                TextField("Device name", text: $displayName)
                    .textFieldStyle(.plain)
                    .submitLabel(.done)
                    .focused($nameFocused)
                if !displayName.isEmpty {
                    Button {
                        displayName = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .glassEffect(
                .regular.interactive(),
                in: .rect(cornerRadius: 16)
            )
        }
    }

    private var scanButton: some View {
        Button {
            MobileHaptics.buttonTap()
            showScanOptions = true
        } label: {
            Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
        .tint(.accentColor)
        .popoverTip(MobileTips.PairingTip(), arrowEdge: .top)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                MobileHaptics.buttonTap()
                pairingError = nil
                state.dismissPairingError()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }

    private var combinedError: String? {
        if case .failed(let message) = state.pairingStatus { return message }
        return pairingError
    }

    private var pairingOverlay: some View {
        ZStack {
            Rectangle()
                .fill(Color.black.opacity(0.25))
                .ignoresSafeArea()

            VStack(spacing: 18) {
                ProgressView()
                    .controlSize(.large)
                    .tint(.accentColor)
                VStack(spacing: 4) {
                    Text("Pairing with your Mac…")
                        .font(.headline)
                    Text("Make sure RxCode is open on your Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                Button {
                    MobileHaptics.buttonTap()
                    onboardingLogger.info("user cancelled pairing")
                    state.cancelPairing()
                } label: {
                    Text("Cancel")
                        .frame(maxWidth: 180)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.glass)
                .controlSize(.regular)
                .padding(.top, 4)
            }
            .padding(28)
            .frame(maxWidth: 320)
            .glassEffect(.regular, in: .rect(cornerRadius: 22))
            .shadow(color: .black.opacity(0.2), radius: 24, y: 12)
        }
    }

    // MARK: - Scan handling

    private func handleScan(_ value: String) {
        MobileHaptics.qrScanned()
        onboardingLogger.info("handleScan received payload length=\(value.count, privacy: .public)")
        do {
            let token = try PairingToken.parse(value)
            onboardingLogger.info("parsed token expired=\(token.isExpired, privacy: .public)")
            onboardingLogger.info("parsed token relayURL=\(token.relayURL, privacy: .public)")
            guard !token.isExpired else {
                pairingError = String(localized: "This QR has expired. Generate a new one on your Mac.")
                return
            }
            pairingError = nil
            Task {
                onboardingLogger.info("starting pair task displayName=\(displayName, privacy: .public)")
                await state.pair(with: token, displayName: displayName)
                // pair() only sends the request; wait for the desktop to accept.
                // The pairingStatus changes to .idle on success or .failed on error.
                onboardingLogger.info("pair request sent, waiting for ack...")
                await waitForPairingResult(expectedPubkey: token.desktopPubkeyHex)
            }
        } catch {
            onboardingLogger.error("token parse failed: \(error.localizedDescription, privacy: .public)")
            pairingError = String(localized: "Unrecognized QR. Try scanning the one from the Mac app.")
        }
    }

    /// Waits for the pairing handshake to complete (success or failure).
    private func waitForPairingResult(expectedPubkey: String) async {
        // Wait until pairingStatus is no longer .inProgress
        while state.pairingStatus == .inProgress {
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
        onboardingLogger.info("pair task finished isPaired=\(state.isPaired, privacy: .public) status=\(String(describing: state.pairingStatus), privacy: .public)")
        if state.isPaired, state.pairedDesktopPubkey == expectedPubkey {
            onPairingCompleted?()
        }
    }

    private func loadAndDecode(item: PhotosPickerItem) async {
        onboardingLogger.info("loadAndDecode start")
        defer { photoItem = nil }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                onboardingLogger.error("photo picker returned nil data")
                pairingError = String(localized: "Couldn't read the selected image.")
                return
            }
            guard let image = UIImage(data: data) else {
                onboardingLogger.error("UIImage init failed bytes=\(data.count, privacy: .public)")
                pairingError = String(localized: "Couldn't read the selected image.")
                return
            }
            onboardingLogger.info("decoded image size=\(image.size.debugDescription, privacy: .public)")
            if let payload = QRImageDecoder.decode(image) {
                onboardingLogger.info("QR decoded from photo length=\(payload.count, privacy: .public)")
                handleScan(payload)
            } else {
                onboardingLogger.error("no QR found in photo")
                pairingError = String(localized: "No QR code found in that image.")
            }
        } catch {
            onboardingLogger.error("loadTransferable error: \(error.localizedDescription, privacy: .public)")
            pairingError = String(localized: "Couldn't load the selected image.")
        }
    }
}

// MARK: - Image QR decoding

private enum QRImageDecoder {
    static func decode(_ image: UIImage) -> String? {
        guard let cgImage = image.cgImage else { return nil }
        let ciImage = CIImage(cgImage: cgImage)
        let context = CIContext()
        let detector = CIDetector(
            ofType: CIDetectorTypeQRCode,
            context: context,
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
        )
        let features = detector?.features(in: ciImage) ?? []
        for feature in features {
            if let qr = feature as? CIQRCodeFeature, let value = qr.messageString {
                return value
            }
        }
        return nil
    }
}

// MARK: - Background

private struct BackdropOrbs: View {
    @State private var animate = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(.systemBackground),
                    Color.accentColor.opacity(0.06)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            Circle()
                .fill(Color.accentColor.opacity(0.35))
                .frame(width: 320, height: 320)
                .blur(radius: 80)
                .offset(x: animate ? -120 : -160, y: animate ? -220 : -260)

            Circle()
                .fill(Color.blue.opacity(0.25))
                .frame(width: 280, height: 280)
                .blur(radius: 90)
                .offset(x: animate ? 140 : 180, y: animate ? 260 : 220)

            Circle()
                .fill(Color.purple.opacity(0.18))
                .frame(width: 220, height: 220)
                .blur(radius: 90)
                .offset(x: animate ? -100 : -60, y: animate ? 180 : 220)
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.easeInOut(duration: 8).repeatForever(autoreverses: true)) {
                animate = true
            }
        }
    }
}
