import SwiftUI
import RxCodeSync

struct OnboardingView: View {
    @EnvironmentObject private var state: MobileAppState
    @State private var showScanner = false
    @State private var pairingError: String?
    @State private var displayName: String = UIDevice.current.name

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "iphone.gen3.badge.checkmark")
                .font(.system(size: 72))
                .foregroundStyle(.tint)
            Text("Pair with your Mac")
                .font(.title2)
                .fontWeight(.semibold)
            Text("Open RxCode on your Mac, go to Settings → Mobile, and tap “Pair new device”. Then scan the QR code with this app.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)

            VStack(alignment: .leading, spacing: 6) {
                Text("Device name")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Device name", text: $displayName)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(.horizontal, 40)

            Button {
                showScanner = true
            } label: {
                Label("Scan QR", systemImage: "qrcode.viewfinder")
                    .frame(maxWidth: 240)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)

            if let err = pairingError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
        .padding(.vertical, 40)
        .sheet(isPresented: $showScanner) {
            QRScannerView { result in
                showScanner = false
                handleScan(result)
            }
        }
    }

    private func handleScan(_ value: String) {
        do {
            let token = try PairingToken.parse(value)
            guard !token.isExpired else {
                pairingError = "This QR has expired. Generate a new one on your Mac."
                return
            }
            pairingError = nil
            Task { await state.pair(with: token, displayName: displayName) }
        } catch {
            pairingError = "Unrecognized QR. Try scanning the one from the Mac app."
        }
    }
}
