import SwiftUI
import RxCodeCore

/// Splash shown while `AppState.initialize()` is loading projects, sessions,
/// and warming services. Replaced by the main view as soon as
/// `AppState.isInitialized` flips.
struct LoadingView: View {
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "sparkle")
                .font(.system(size: ClaudeTheme.size(56), weight: .light))
                .foregroundStyle(ClaudeTheme.accent)
                .scaleEffect(pulse ? 1.08 : 0.94)
                .opacity(pulse ? 1.0 : 0.7)
                .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: pulse)

            Text("RxCode")
                .font(.system(size: ClaudeTheme.size(28), weight: .semibold))
                .foregroundStyle(ClaudeTheme.textPrimary)

            ProgressView()
                .controlSize(.small)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ClaudeTheme.background.ignoresSafeArea())
        .onAppear { pulse = true }
    }
}
