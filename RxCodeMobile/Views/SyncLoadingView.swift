import SwiftUI
import RxCodeCore
import os.log

private let logger = Logger(subsystem: "com.idealapp.RxCode", category: "SyncLoadingView")

/// A beautiful full-screen liquid glass loading splash shown while syncing with the paired Mac.
/// Features animated gradient orbs, a pulsing progress indicator, and smooth transitions.
/// When timed out, shows a timeout screen with retry button.
struct SyncLoadingView: View {
    var isTimedOut: Bool = false
    var pairedDesktops: [PairedDesktop] = []
    var activeDesktopID: String?
    var onRetry: (() -> Void)?
    var onSelectDesktop: ((PairedDesktop) -> Void)?
    var onPairNewDesktop: (() -> Void)?

    @State private var pulseScale: CGFloat = 1.0
    @State private var orbRotation: Double = 0
    @State private var shimmerOffset: CGFloat = -200
    @State private var appeared = false
    @State private var animationStartTask: Task<Void, Never>?
    @State private var shimmerTask: Task<Void, Never>?

    var body: some View {
        let _ = logger.debug("SyncLoadingView body: isTimedOut=\(self.isTimedOut)")
        if isTimedOut {
            timeoutView
        } else {
            loadingView
        }
    }

    private var loadingView: some View {
        ZStack {
            // Background gradient
            backgroundGradient
                .ignoresSafeArea()

            // Floating background orbs
            floatingOrbs
                .ignoresSafeArea()

            // Main content
            VStack(spacing: 32) {
                Spacer()

                // Animated orb container
                animatedOrbView
                    .scaleEffect(appeared ? 1 : 0.8)
                    .opacity(appeared ? 1 : 0)

                // Text content
                VStack(spacing: 16) {
                    Text("Syncing with Mac")
                        .font(.title.weight(.semibold))
                        .foregroundStyle(.primary)

                    HStack(spacing: 6) {
                        Text("Connecting to \(activeDesktopDisplayName)")
                            .font(.body)
                            .foregroundStyle(.secondary)

                        AnimatedDotsView()
                    }
                }
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 20)

                // Shimmer bar
                shimmerBar
                    .padding(.top, 8)
                    .opacity(appeared ? 1 : 0)

                Spacer()
                Spacer()
            }
            .padding(.horizontal, 40)
        }
        .onAppear {
            resetAnimations()
            startAnimations()
            withAnimation(.easeOut(duration: 0.6)) {
                appeared = true
            }
        }
        .onDisappear {
            stopAnimations()
        }
    }

    // MARK: - Timeout View

    private var timeoutView: some View {
        ZStack {
            // Background gradient (same as loading)
            backgroundGradient
                .ignoresSafeArea()

            // Main content
            VStack(spacing: 32) {
                Spacer()

                // Error icon with glass effect
                timeoutIconView

                // Text content
                VStack(spacing: 16) {
                    Text("Connection Timed Out")
                        .font(.title.weight(.semibold))
                        .foregroundStyle(.primary)

                    Text("Unable to connect to your Mac. Make sure RxCode is running on your desktop and both devices are on the same network.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                desktopPickerView

                timeoutActions

                Spacer()
                Spacer()
            }
            .padding(.horizontal, 40)
        }
    }

    private var timeoutActions: some View {
        VStack(spacing: 12) {
            Button {
                onRetry?()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Try Again")
                        .font(.body.weight(.semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 32)
                .padding(.vertical, 14)
                .background(
                    LinearGradient(
                        colors: [
                            ClaudeTheme.accent,
                            ClaudeTheme.accent.opacity(0.85)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .clipShape(Capsule())
                .shadow(color: ClaudeTheme.accent.opacity(0.3), radius: 12, x: 0, y: 6)
            }
            .buttonStyle(.plain)

            if let onPairNewDesktop {
                Button {
                    onPairNewDesktop()
                } label: {
                    Label("Pair New Mac", systemImage: "plus.circle")
                        .font(.body.weight(.semibold))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.glass)
                .foregroundStyle(.primary)
            }
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private var desktopPickerView: some View {
        if pairedDesktops.count > 1 {
            VStack(alignment: .leading, spacing: 8) {
                Label("Connect to", systemImage: "desktopcomputer")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)

                Picker("Mac", selection: desktopSelection) {
                    ForEach(pairedDesktops) { desktop in
                        Text(desktopPickerTitle(desktop))
                            .tag(desktop.id)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(.white.opacity(0.18))
                }
            }
            .frame(maxWidth: 320)
            .padding(.top, 4)
        }
    }

    private var desktopSelection: Binding<String> {
        Binding(
            get: {
                activeDesktopID ?? pairedDesktops.first?.id ?? ""
            },
            set: { selectedID in
                guard let desktop = pairedDesktops.first(where: { $0.id == selectedID }) else { return }
                onSelectDesktop?(desktop)
            }
        )
    }

    private func desktopPickerTitle(_ desktop: PairedDesktop) -> String {
        let name = desktop.displayName.isEmpty ? "Unknown Mac" : desktop.displayName
        guard let relay = desktop.relayDisplayName else { return name }
        return "\(name) (\(relay))"
    }

    private var activeDesktopDisplayName: String {
        guard let desktop = pairedDesktops.first(where: { $0.id == activeDesktopID }) else {
            return "your Mac"
        }
        return desktop.displayName.isEmpty ? "Unknown Mac" : desktop.displayName
    }

    private var timeoutIconView: some View {
        ZStack {
            // Outer glow (dimmer than loading state)
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.orange.opacity(0.15),
                            Color.orange.opacity(0.05),
                            .clear
                        ],
                        center: .center,
                        startRadius: 40,
                        endRadius: 100
                    )
                )
                .frame(width: 200, height: 200)

            // Central glass circle
            ZStack {
                // Glass background with blur
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 110, height: 110)

                // Warning ring
                Circle()
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.orange.opacity(0.8),
                                Color.orange.opacity(0.5)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 3
                    )
                    .frame(width: 95, height: 95)

                // Warning icon
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 36, weight: .medium))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                Color.orange,
                                Color.orange.opacity(0.75)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .shadow(color: Color.orange.opacity(0.15), radius: 20, x: 0, y: 8)
            .glassEffect(.regular.tint(Color.orange.opacity(0.05)), in: .circle)
        }
        .frame(width: 200, height: 200)
    }

    // MARK: - Background

    private var backgroundGradient: some View {
        ZStack {
            // Base gradient
            LinearGradient(
                colors: [
                    Color(UIColor.systemBackground),
                    Color(UIColor.systemBackground).opacity(0.95)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            // Accent color wash
            RadialGradient(
                colors: [
                    ClaudeTheme.accent.opacity(0.08),
                    ClaudeTheme.accent.opacity(0.03),
                    .clear
                ],
                center: .center,
                startRadius: 100,
                endRadius: 400
            )
        }
    }

    private var floatingOrbs: some View {
        GeometryReader { geo in
            ZStack {
                // Top-right orb
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                ClaudeTheme.accent.opacity(0.15),
                                ClaudeTheme.accent.opacity(0.05),
                                .clear
                            ],
                            center: .center,
                            startRadius: 20,
                            endRadius: 120
                        )
                    )
                    .frame(width: 240, height: 240)
                    .offset(x: geo.size.width * 0.3, y: -geo.size.height * 0.15)
                    .scaleEffect(pulseScale * 0.9 + 0.1)

                // Bottom-left orb
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color(red: 0.4, green: 0.6, blue: 0.9).opacity(0.12),
                                Color(red: 0.5, green: 0.4, blue: 0.85).opacity(0.04),
                                .clear
                            ],
                            center: .center,
                            startRadius: 30,
                            endRadius: 150
                        )
                    )
                    .frame(width: 300, height: 300)
                    .offset(x: -geo.size.width * 0.35, y: geo.size.height * 0.25)
                    .scaleEffect(1.1 - (pulseScale - 1) * 0.5)
            }
        }
    }

    // MARK: - Animated Orb

    private var animatedOrbView: some View {
        ZStack {
            // Outer glow
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            ClaudeTheme.accent.opacity(0.25),
                            ClaudeTheme.accent.opacity(0.08),
                            .clear
                        ],
                        center: .center,
                        startRadius: 40,
                        endRadius: 120
                    )
                )
                .frame(width: 240, height: 240)
                .scaleEffect(pulseScale)

            // Orbiting dots
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(orbGradient(for: index))
                    .frame(width: 14, height: 14)
                    .shadow(color: orbShadowColor(for: index), radius: 8, x: 0, y: 2)
                    .offset(x: 55)
                    .rotationEffect(.degrees(orbRotation + Double(index) * 120))
            }

            // Central glass circle
            ZStack {
                // Glass background with blur
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 110, height: 110)

                // Inner gradient ring
                Circle()
                    .strokeBorder(
                        AngularGradient(
                            colors: [
                                ClaudeTheme.accent.opacity(0.9),
                                ClaudeTheme.accent.opacity(0.3),
                                Color.white.opacity(0.4),
                                ClaudeTheme.accent.opacity(0.7),
                                ClaudeTheme.accent.opacity(0.9)
                            ],
                            center: .center,
                            startAngle: .degrees(0),
                            endAngle: .degrees(360)
                        ),
                        lineWidth: 3.5
                    )
                    .frame(width: 95, height: 95)
                    .rotationEffect(.degrees(-orbRotation * 0.5))

                // Mac icon
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 36, weight: .medium))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                ClaudeTheme.accent,
                                ClaudeTheme.accent.opacity(0.75)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .scaleEffect(0.95 + (pulseScale - 1) * 0.3)
            }
            .shadow(color: ClaudeTheme.accent.opacity(0.2), radius: 20, x: 0, y: 8)
            .glassEffect(.regular.tint(ClaudeTheme.accent.opacity(0.08)), in: .circle)
        }
        .frame(width: 240, height: 240)
    }

    // MARK: - Shimmer Bar

    private var shimmerBar: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color.secondary.opacity(0.15))
            .frame(width: 160, height: 6)
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .fill(
                        LinearGradient(
                            colors: [
                                .clear,
                                ClaudeTheme.accent.opacity(0.5),
                                .clear
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: 80)
                    .offset(x: shimmerOffset)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Helpers

    private func orbGradient(for index: Int) -> LinearGradient {
        let colors: [[Color]] = [
            [ClaudeTheme.accent, ClaudeTheme.accent.opacity(0.7)],
            [Color(red: 0.4, green: 0.6, blue: 0.9), Color(red: 0.5, green: 0.4, blue: 0.85)],
            [Color(red: 0.9, green: 0.5, blue: 0.6), Color(red: 0.95, green: 0.6, blue: 0.4)]
        ]
        return LinearGradient(
            colors: colors[index % colors.count],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private func orbShadowColor(for index: Int) -> Color {
        let colors: [Color] = [
            ClaudeTheme.accent.opacity(0.4),
            Color(red: 0.4, green: 0.6, blue: 0.9).opacity(0.4),
            Color(red: 0.9, green: 0.5, blue: 0.6).opacity(0.4)
        ]
        return colors[index % colors.count]
    }

    private func startAnimations() {
        animationStartTask?.cancel()
        animationStartTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled, !isTimedOut else { return }

            withAnimation(
                .easeInOut(duration: 2.0)
                .repeatForever(autoreverses: true)
            ) {
                pulseScale = 1.12
            }

            withAnimation(
                .linear(duration: 5.0)
                .repeatForever(autoreverses: false)
            ) {
                orbRotation = 360
            }

            startShimmerLoop()
        }
    }

    private func resetAnimations() {
        stopAnimations()
        pulseScale = 1.0
        orbRotation = 0
        shimmerOffset = -200
        appeared = false
    }

    private func stopAnimations() {
        animationStartTask?.cancel()
        animationStartTask = nil
        shimmerTask?.cancel()
        shimmerTask = nil
    }

    private func startShimmerLoop() {
        shimmerTask?.cancel()
        shimmerTask = Task { @MainActor in
            while !Task.isCancelled {
                shimmerOffset = -200
                await Task.yield()
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 1.8)) {
                    shimmerOffset = 200
                }
                try? await Task.sleep(for: .milliseconds(1800))
            }
        }
    }
}

/// Animated ellipsis dots for loading text
private struct AnimatedDotsView: View {
    @State private var dotCount = 0

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 5, height: 5)
                    .opacity(index < dotCount ? 1 : 0.3)
            }
        }
        .onAppear {
            startAnimation()
        }
    }

    private func startAnimation() {
        Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
            withAnimation(.easeInOut(duration: 0.2)) {
                dotCount = (dotCount + 1) % 4
            }
        }
    }
}

// MARK: - Transition Modifier

extension AnyTransition {
    /// A smooth transition for the loading splash screen
    static var splashTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity.animation(.easeOut(duration: 0.3)),
            removal: .opacity.combined(with: .scale(scale: 1.05)).animation(.easeIn(duration: 0.4))
        )
    }

    /// A smooth transition for the main content appearing after loading
    static var contentTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.98)).animation(.spring(duration: 0.5, bounce: 0.1)),
            removal: .opacity.animation(.easeOut(duration: 0.2))
        )
    }
}

// MARK: - Preview

#Preview {
    SyncLoadingView()
}
