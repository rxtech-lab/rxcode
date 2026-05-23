import SwiftUI
import UIKit

/// Liquid-glass message composer. Renders a send button while idle and a stop
/// button while the desktop reports the session as streaming. Sending while
/// streaming is allowed: the host view buffers the text into a local queue
/// (mirroring the macOS app) and flushes the next entry when the current turn
/// completes.
struct MobileInputBar: View {
    @Binding var text: String
    var isStreaming: Bool
    var onSend: (String) -> Void
    var onStop: () -> Void

    @State private var borderAnimationProgress: CGFloat = 0
    @State private var shimmerOffset: CGFloat = -1
    @FocusState private var isInputFocused: Bool

    /// Subtle warm gradient that mirrors the streaming glow.
    private let gradientColors: [Color] = [
        Color(red: 0.95, green: 0.6, blue: 0.4),
        Color(red: 0.85, green: 0.5, blue: 0.55),
        Color(red: 0.65, green: 0.5, blue: 0.7),
        Color(red: 0.5, green: 0.55, blue: 0.75),
        Color(red: 0.55, green: 0.65, blue: 0.7),
        Color(red: 0.7, green: 0.65, blue: 0.55),
        Color(red: 0.9, green: 0.65, blue: 0.45),
        Color(red: 0.95, green: 0.6, blue: 0.4),
    ]

    private var hasText: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Send is disabled when there's nothing to send. We *do* allow sending
    /// while streaming — the host enqueues the message instead.
    private var isSendDisabled: Bool { !hasText }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            inputField
                .frame(maxWidth: .infinity)

            if isStreaming {
                stopButton
                if hasText {
                    sendButton
                        .transition(.scale.combined(with: .opacity))
                }
            } else {
                sendButton
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .animation(.easeInOut(duration: 0.15), value: isStreaming)
        .animation(.easeInOut(duration: 0.15), value: hasText)
        .onChange(of: isStreaming) { _, newValue in
            if newValue {
                startBorderAnimation()
                startShimmerAnimation()
            } else {
                borderAnimationProgress = 0
                shimmerOffset = -1
            }
        }
        .onAppear {
            if isStreaming {
                startBorderAnimation()
                startShimmerAnimation()
            }
        }
    }

    // MARK: - Buttons

    private var sendButton: some View {
        Button {
            sendIfPossible()
        } label: {
            Image(systemName: "arrow.up")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 36, height: 36)
                .contentShape(Circle())
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .disabled(isSendDisabled)
        .accessibilityIdentifier("send-button")
    }

    private var stopButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onStop()
        } label: {
            Image(systemName: "stop.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color(red: 0.9, green: 0.4, blue: 0.4))
                .frame(width: 36, height: 36)
                .contentShape(Circle())
                .glassEffect(
                    .regular.tint(Color(red: 0.95, green: 0.6, blue: 0.6).opacity(0.3)).interactive(),
                    in: .circle
                )
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .accessibilityIdentifier("stop-button")
    }

    // MARK: - Input Field

    private var inputField: some View {
        TextField(placeholder, text: $text, axis: .vertical)
            .lineLimit(1 ... 6)
            .textFieldStyle(.plain)
            .padding(.vertical, 10)
            .padding(.horizontal, 16)
            .accessibilityIdentifier("chat-input")
            .focused($isInputFocused)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isStreaming ? AnyShapeStyle(animatedBackgroundGradient) : AnyShapeStyle(.clear))
            )
            .glassEffect(in: .rect(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(animatedBorderGradient, lineWidth: 4)
                    .blur(radius: 8)
                    .opacity(isStreaming ? 0.6 : 0)
            )
            .shadow(
                color: isStreaming
                    ? gradientColors[Int(borderAnimationProgress * 7) % 8].opacity(0.4)
                    : .clear,
                radius: 12,
                x: 0,
                y: 0
            )
    }

    private var placeholder: String {
        isStreaming
            ? String(localized: "Queue a message...")
            : String(localized: "Message…")
    }

    private var animatedBorderGradient: AnyShapeStyle {
        AnyShapeStyle(
            AngularGradient(
                colors: gradientColors,
                center: .center,
                angle: .degrees(borderAnimationProgress * 360)
            )
        )
    }

    private var animatedBackgroundGradient: LinearGradient {
        LinearGradient(
            colors: gradientColors.map { $0.opacity(0.15) },
            startPoint: UnitPoint(x: borderAnimationProgress, y: 0),
            endPoint: UnitPoint(x: borderAnimationProgress + 0.5, y: 1)
        )
    }

    // MARK: - Actions

    private func sendIfPossible() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        text = ""
        onSend(trimmed)
    }

    private func startBorderAnimation() {
        borderAnimationProgress = 0
        withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) {
            borderAnimationProgress = 1
        }
    }

    private func startShimmerAnimation() {
        shimmerOffset = -1
        withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
            shimmerOffset = 2
        }
    }
}
