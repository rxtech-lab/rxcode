import CoreImage.CIFilterBuiltins
import RxCodeCore
import RxCodeSync
import SwiftUI

struct MobilePairingPreview: View {
    let token: PairingToken?
    let qrImage: NSImage?
    let downloadLinks: DownloadLinks?
    let isLoadingDownloads: Bool
    let errorMessage: String?
    let savedRelayServers: [SavedRelayServer]
    @Binding var selectedRelayServerID: UUID?
    let onRegenerate: () -> Void
    let onAddRelayServer: () -> Void

    private var hasDownloadOptions: Bool {
        guard let links = downloadLinks else { return false }
        let urls = [
            links.ios.appStoreURL,
            links.android.playStoreURL,
            links.android.apkURL
        ]
        return urls.contains { !$0.isEmpty }
    }

    private var showDownloadPanel: Bool {
        isLoadingDownloads || hasDownloadOptions
    }

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            pairingPanel
            if showDownloadPanel {
                downloadPanel
            }
        }
        .frame(maxWidth: 640)
    }

    private var pairingPanel: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "qrcode")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(ClaudeTheme.accent)
                Text("Pair via QR")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(ClaudeTheme.textPrimary)
                Spacer()
            }

            relaySelector

            if let qrImage {
                Image(nsImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 180, height: 180)
                    .background(Color.white.opacity(0.96))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else if let errorMessage {
                VStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(ClaudeTheme.statusWarning)
                    Text(verbatim: errorMessage)
                        .font(.system(size: 11))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(ClaudeTheme.textSecondary)
                }
                .frame(width: 180, height: 180)
                .background(ClaudeTheme.codeBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                ProgressView()
                    .frame(width: 180, height: 180)
            }

            if let token {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let remaining = Int(token.expiresAt.timeIntervalSince(context.date).rounded(.down))
                    Text(remaining > 0
                         ? String(format: NSLocalizedString("Expires in %d:%02d", comment: ""), remaining / 60, remaining % 60)
                         : String(localized: "Expired"))
                        .font(.system(size: 10))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                }
            }

            Button {
                onRegenerate()
            } label: {
                Label(LocalizedStringKey("Regenerate"), systemImage: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ClaudeTheme.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(ClaudeTheme.surfaceSecondary, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(ClaudeTheme.codeBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(ClaudeTheme.border, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var relaySelector: some View {
        if savedRelayServers.isEmpty {
            VStack(spacing: 8) {
                Text("No relay server configured")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(ClaudeTheme.textSecondary)
                    .multilineTextAlignment(.center)
                Button {
                    onAddRelayServer()
                } label: {
                    Label(LocalizedStringKey("Add Relay Server"), systemImage: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(ClaudeTheme.textOnAccent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(ClaudeTheme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        } else {
            HStack(spacing: 6) {
                Text("Relay")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ClaudeTheme.textSecondary)
                Picker("", selection: $selectedRelayServerID) {
                    ForEach(savedRelayServers) { server in
                        Text(verbatim: server.name).tag(Optional(server.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .frame(maxWidth: .infinity)

                Button {
                    onAddRelayServer()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .foregroundStyle(ClaudeTheme.textPrimary)
                        .background(ClaudeTheme.surfaceSecondary, in: Circle())
                }
                .buttonStyle(.plain)
                .help(LocalizedStringKey("Add Relay Server"))
            }
        }
    }

    private var downloadPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "iphone.gen3")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(ClaudeTheme.accent)
                Text("Install the app")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(ClaudeTheme.textPrimary)
                Spacer()
            }

            Text("Open RxCode on your phone, then tap Pair Device and scan the QR code.")
                .font(.system(size: 12))
                .foregroundStyle(ClaudeTheme.textSecondary)

            if isLoadingDownloads {
                ProgressView()
                    .controlSize(.small)
                    .padding(.vertical, 8)
            } else if let links = downloadLinks {
                downloadButtons(links: links)
            } else {
                Text("Download links unavailable. Visit rxlab.app to install the mobile app.")
                    .font(.system(size: 11))
                    .foregroundStyle(ClaudeTheme.textTertiary)
            }

            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(ClaudeTheme.codeBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(ClaudeTheme.border, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func downloadButtons(links: DownloadLinks) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let url = URL(string: links.ios.appStoreURL), !links.ios.appStoreURL.isEmpty {
                downloadLinkButton(
                    icon: "applelogo",
                    label: LocalizedStringKey("Download for iOS"),
                    sublabel: links.ios.version,
                    url: url
                )
            }
            if let url = URL(string: links.android.playStoreURL), !links.android.playStoreURL.isEmpty {
                downloadLinkButton(
                    icon: "smartphone",
                    label: LocalizedStringKey("Get it on Google Play"),
                    sublabel: links.android.version,
                    url: url
                )
            }
            if let url = URL(string: links.android.apkURL), !links.android.apkURL.isEmpty {
                downloadLinkButton(
                    icon: "arrow.down.circle",
                    label: LocalizedStringKey("Download APK"),
                    sublabel: links.android.version,
                    url: url
                )
            }
        }
    }

    private func downloadLinkButton(icon: String, label: LocalizedStringKey, sublabel: String, url: URL) -> some View {
        Link(destination: url) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(.system(size: 12, weight: .semibold))
                    if !sublabel.isEmpty {
                        Text(verbatim: sublabel)
                            .font(.system(size: 10))
                            .foregroundStyle(ClaudeTheme.textTertiary)
                    }
                }
                Spacer()
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 11))
                    .foregroundStyle(ClaudeTheme.textTertiary)
            }
            .foregroundStyle(ClaudeTheme.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(ClaudeTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Download links model

struct DownloadLinks: Decodable, Sendable {
    struct IOS: Decodable, Sendable {
        let appStoreURL: String
        let testflightURL: String
        let version: String
    }
    struct Android: Decodable, Sendable {
        let playStoreURL: String
        let apkURL: String
        let version: String
    }
    let ios: IOS
    let android: Android

    private static let endpoint = URL(string: "https://rxlab.app/api/download")!

    static func fetch() async -> DownloadLinks? {
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 6
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            return try JSONDecoder().decode(DownloadLinks.self, from: data)
        } catch {
            return nil
        }
    }
}

// MARK: - QR code helper

func makeOnboardingQRCode(from string: String) -> NSImage? {
    let context = CIContext()
    let filter = CIFilter.qrCodeGenerator()
    filter.setValue(Data(string.utf8), forKey: "inputMessage")
    filter.correctionLevel = "M"
    guard let outputImage = filter.outputImage else { return nil }
    let scaled = outputImage.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
    guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
    return NSImage(cgImage: cgImage, size: NSSize(width: 180, height: 180))
}
