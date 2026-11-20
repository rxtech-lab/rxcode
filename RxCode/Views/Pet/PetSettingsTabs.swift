import SwiftUI

extension PetSettingsView {
    enum SettingsTab: Hashable, CaseIterable {
        case generalAgent, looks, voice, music, desktop

        var title: String {
            switch self {
            case .generalAgent: "General Agent"
            case .looks: "Looks"
            case .voice: "Voice"
            case .music: "Music"
            case .desktop: "Desktop & Reports"
            }
        }

        var systemImage: String {
            switch self {
            case .generalAgent: "sparkles"
            case .looks: "paintpalette"
            case .voice: "waveform"
            case .music: "music.note"
            case .desktop: "desktopcomputer"
            }
        }
    }
}

// MARK: - macOS Settings-style toolbar tab

struct SettingsToolbarTabButton: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.system(size: 20, weight: .regular))
                    .symbolVariant(isSelected ? .fill : .none)
                    .frame(height: 24)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .frame(minWidth: 64)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(isSelected ? 0.09 : (isHovering ? 0.05 : 0)))
            }
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
