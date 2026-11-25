import RxCodeCore
import SwiftUI

/// An agent's face: its pet look animated by what the agent is doing, or its
/// SF Symbol when it has no look.
struct AgentAvatarView: View {
    let agent: AgentProfile
    var activity: AgentActivity = .idle
    var size: CGFloat = 36
    /// Whether the sprite plays. Still frames keep long lists cheap.
    var animated = true
    /// Shows a small status dot on the avatar's edge.
    var showsStatus = true

    private var tint: Color { Color(hex: agent.colorHex) }

    private var look: PetLook? {
        guard let id = agent.petLookId else { return nil }
        return PetController.shared.looks.looks.first { $0.id == id }
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [tint.opacity(0.32), tint.opacity(0.12)],
                        center: .center, startRadius: 0, endRadius: size * 0.6
                    )
                )
            Circle()
                .strokeBorder(activity == .working ? tint : tint.opacity(0.35), lineWidth: max(1, size / 28))
            if let look {
                PetSpriteView(
                    character: look.character, state: Self.petState(for: activity),
                    size: size * 0.96, isAnimationActive: animated
                )
                .frame(width: size, height: size)
                .clipShape(Circle())
                .allowsHitTesting(false)
            } else {
                Image(systemName: agent.symbol)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(tint)
                    .symbolEffect(.pulse, isActive: animated && activity == .working)
            }
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            if showsStatus, let color = statusColor {
                Circle()
                    .fill(color)
                    .frame(width: max(7, size * 0.24), height: max(7, size * 0.24))
                    .overlay(Circle().strokeBorder(ClaudeTheme.background, lineWidth: max(1.5, size / 24)))
                    .offset(x: size * 0.02, y: size * 0.02)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(Text("\(agent.displayName), \(String(localized: activity.label))"))
    }

    private var statusColor: Color? {
        switch activity {
        case .idle: nil
        case .working: ClaudeTheme.statusRunning
        case .waiting: ClaudeTheme.statusWarning
        case .celebrating: ClaudeTheme.statusSuccess
        case .failed: ClaudeTheme.statusError
        }
    }

    static func petState(for activity: AgentActivity) -> PetState {
        var state = PetState()
        switch activity {
        case .idle: state.status = .idle
        case .working: state.status = .working
        case .waiting: state.status = .listening
        case .celebrating: state.status = .celebrating
        case .failed: state.status = .failed
        }
        return state
    }
}

/// A small capsule showing an agent's activity.
struct AgentActivityPill: View {
    let activity: AgentActivity

    private var color: Color {
        switch activity {
        case .idle: ClaudeTheme.textTertiary
        case .working: ClaudeTheme.statusRunning
        case .waiting: ClaudeTheme.statusWarning
        case .celebrating: ClaudeTheme.statusSuccess
        case .failed: ClaudeTheme.statusError
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(activity.label)
        }
        .font(.system(size: ClaudeTheme.size(11), weight: .medium))
        .foregroundStyle(activity == .idle ? ClaudeTheme.textSecondary : color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.12)))
    }
}

/// A small capsule showing a job's status.
struct AgentJobStatusBadge: View {
    let status: AgentJob.Status

    private var color: Color {
        switch status {
        case .queued: ClaudeTheme.textSecondary
        case .running: ClaudeTheme.statusRunning
        case .succeeded: ClaudeTheme.statusSuccess
        case .failed, .interrupted: ClaudeTheme.statusError
        case .cancelled: ClaudeTheme.textTertiary
        }
    }

    var body: some View {
        Label {
            Text(status.displayName)
        } icon: {
            Image(systemName: status.systemImage)
                .symbolEffect(.rotate, isActive: status == .running)
        }
        .font(.system(size: ClaudeTheme.size(11), weight: .medium))
        .foregroundStyle(color)
        .labelStyle(.titleAndIcon)
    }
}
