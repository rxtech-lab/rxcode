import SwiftUI
import RxCodeCore

/// Shared visual language for the mobile list cards (threads, projects, sidebar
/// destinations, search hits).
///
/// A flat, solid surface: an opaque grouped-background fill, a hairline
/// border and a soft drop shadow. State shows up as an optional coloured rail
/// on the leading edge instead of a tinted glass material. Replaces the
/// Liquid Glass cards.
enum MobileCard {
    static let cornerRadius: CGFloat = 14

    /// Page background behind the cards, so the card fill contrasts with it in
    /// both light and dark mode.
    static var pageBackground: Color { Color(.systemGroupedBackground) }
    static var surface: Color { Color(.secondarySystemGroupedBackground) }
    static var shape: RoundedRectangle { RoundedRectangle(cornerRadius: cornerRadius, style: .continuous) }
}

/// The surface itself, usable as a background for compound cards that hold
/// several sibling buttons (such as the thread card with a review disclosure).
struct MobileCardSurface: View {
    var isSelected: Bool = false
    var isPressed: Bool = false
    /// Leading accent rail colour; `nil` hides the rail.
    var rail: Color? = nil

    var body: some View {
        MobileCard.shape
            .fill(fill)
            .overlay(alignment: .leading) {
                if let rail {
                    Capsule()
                        .fill(rail)
                        .frame(width: 3)
                        .padding(.vertical, 12)
                        .padding(.leading, 5)
                }
            }
            .overlay {
                MobileCard.shape
                    .strokeBorder(
                        isSelected ? ClaudeTheme.accent.opacity(0.7) : Color.primary.opacity(0.07),
                        lineWidth: isSelected ? 1.5 : 0.5
                    )
            }
            .shadow(color: .black.opacity(isPressed ? 0.02 : 0.05), radius: isPressed ? 1 : 6, y: isPressed ? 0 : 2)
    }

    private var fill: Color {
        if isSelected { return ClaudeTheme.accent.opacity(0.10) }
        if isPressed { return Color(.tertiarySystemGroupedBackground) }
        return MobileCard.surface
    }
}

/// Button style that draws a `MobileCardSurface` behind the label.
struct MobileCardButtonStyle: ButtonStyle {
    var isSelected: Bool = false
    var rail: Color? = nil
    var isEnabled: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                MobileCardSurface(isSelected: isSelected, isPressed: configuration.isPressed, rail: rail)
            }
            .contentShape(MobileCard.shape)
            .scaleEffect(configuration.isPressed ? 0.985 : 1.0)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
            .opacity(isEnabled ? 1 : 0.55)
    }
}

/// Rounded-square icon tile used at the leading edge of cards.
struct MobileCardIconTile: View {
    let systemImage: String
    let tint: Color
    var size: CGFloat = 38

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(tint.opacity(0.14))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: systemImage)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(tint)
            }
    }
}

/// Small capsule tag used for metadata (labels, todo progress, counts).
struct MobileCardTag: View {
    let text: String
    var systemImage: String? = nil
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 9, weight: .bold))
            }
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(tint.opacity(0.12), in: Capsule())
    }
}

extension View {
    /// Draws a `MobileCardSurface` behind static (non-button) card content.
    func mobileCardSurface(isSelected: Bool = false, rail: Color? = nil) -> some View {
        background { MobileCardSurface(isSelected: isSelected, rail: rail) }
            .contentShape(MobileCard.shape)
    }

    /// Small neutral capsule fill for inline count/label chips on a card.
    func mobileCardChipBackground() -> some View {
        background(Color.primary.opacity(0.06), in: Capsule())
    }
}
