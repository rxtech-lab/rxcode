import SwiftUI

/// Animates a text swap by erasing the current value character-by-character
/// (cursor moving right→left) and then typing the new value left→right.
/// No animation runs on the first appearance — the initial value is shown immediately.
public struct TypewriterTitleText: View {
    let title: String
    var charInterval: Duration = .milliseconds(18)
    var pauseBetween: Duration = .milliseconds(120)
    var holdAfter: Duration = .milliseconds(180)

    @State private var displayed: String = ""
    @State private var isAnimating: Bool = false
    @State private var hasAppeared: Bool = false
    @State private var animationTask: Task<Void, Never>?

    public init(
        title: String,
        charInterval: Duration = .milliseconds(18),
        pauseBetween: Duration = .milliseconds(120),
        holdAfter: Duration = .milliseconds(180)
    ) {
        self.title = title
        self.charInterval = charInterval
        self.pauseBetween = pauseBetween
        self.holdAfter = holdAfter
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(displayed)
            if isAnimating {
                Text("│")
                    .foregroundStyle(ClaudeTheme.accent)
                    .opacity(0.85)
                    .transition(.opacity)
            }
        }
        .onAppear {
            guard !hasAppeared else { return }
            displayed = title
            hasAppeared = true
        }
        .onChange(of: title) { _, newValue in
            guard hasAppeared else {
                displayed = newValue
                return
            }
            guard newValue != displayed else { return }
            startSwap(to: newValue)
        }
        .onDisappear {
            animationTask?.cancel()
            animationTask = nil
        }
    }

    private func startSwap(to target: String) {
        animationTask?.cancel()
        animationTask = Task { @MainActor in
            isAnimating = true
            while !displayed.isEmpty {
                if Task.isCancelled { return }
                displayed.removeLast()
                try? await Task.sleep(for: charInterval)
            }
            if Task.isCancelled { return }
            try? await Task.sleep(for: pauseBetween)
            for ch in target {
                if Task.isCancelled { return }
                displayed.append(ch)
                try? await Task.sleep(for: charInterval)
            }
            if Task.isCancelled { return }
            try? await Task.sleep(for: holdAfter)
            withAnimation(.easeOut(duration: 0.18)) {
                isAnimating = false
            }
        }
    }
}
