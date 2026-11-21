import RxCodeChatKit
import RxCodeCore
import SwiftUI

struct PetToolOrbitView: View {
    let calls: [PetToolActivity.Call]
    let petSize: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startedAt = Date.now
    @State private var isHovering = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15, paused: reduceMotion || isHovering)) { context in
            let elapsed = reduceMotion ? 0 : context.date.timeIntervalSince(startedAt)
            ZStack {
                ForEach(Array(calls.enumerated()), id: \.element.id) { index, call in
                    let angle = elapsed * .pi / 12 + Double(index) * 2 * .pi / 3 - .pi / 2
                    toolBubble(call)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.94).combined(with: .opacity))
                        .offset(
                            x: cos(angle) * (petSize / 2 + 50),
                            y: sin(angle) * (petSize / 2 + 30)
                        )
                }
            }
            .frame(width: petSize + 220, height: petSize + 120)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: calls.map(\.id))
        }
    }

    private func toolBubble(_ call: PetToolActivity.Call) -> some View {
        HStack(spacing: 5) {
            ZStack {
                if call.status == .running {
                    PetLoadingSpinner()
                        .transition(.opacity)
                } else {
                    Image(systemName: statusSymbol(call.status))
                        .font(.system(size: 14))
                        .foregroundStyle(call.status == .failed ? ClaudeTheme.statusError : ClaudeTheme.textSecondary)
                        .transition(.opacity)
                }
            }
            .frame(width: 14, height: 14)
            ScrollView(.vertical) {
                MarkdownContentView(text: call.name, style: .rxCodeCompact)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(height: 30)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(width: 112)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.8)
        }
        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
        .help(call.name)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityValue(statusLabel(call.status))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: call.status)
    }

    private func statusSymbol(_ status: PetToolActivity.Status) -> String {
        switch status {
        case .running: "hourglass"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        case .cancelled: "minus.circle"
        }
    }

    private func statusLabel(_ status: PetToolActivity.Status) -> String {
        switch status {
        case .running: "In progress"
        case .completed: "Completed"
        case .failed: "Failed"
        case .cancelled: "Stopped"
        }
    }
}

/// A compact pixel-style orbit that stays legible on the pet's material bubbles.
struct PetLoadingSpinner: View {
    var size: CGFloat = 14
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.1, paused: reduceMotion)) { context in
            let step = reduceMotion ? 0 : Int(context.date.timeIntervalSinceReferenceDate * 10) % 8
            ZStack {
                ForEach(0..<8) { index in
                    let angle = Double(index) * .pi / 4
                    RoundedRectangle(cornerRadius: 0.7)
                        .fill(Color.accentColor.opacity(0.25 + Double((index - step + 8) % 8) / 7 * 0.75))
                        .frame(width: size * 0.2, height: size * 0.2)
                        .offset(x: cos(angle) * size * 0.36, y: sin(angle) * size * 0.36)
                }
            }
            .frame(width: size, height: size)
        }
        .accessibilityLabel("Loading")
    }
}
