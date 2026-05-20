import SwiftUI
import RxCodeCore
import RxCodeSync

/// A thread card using Liquid Glass design for the mobile threads list.
/// Features translucent glass background with subtle morphing animations.
struct GlassThreadCard: View {
    let session: SessionSummary
    let isSelected: Bool
    /// When true, uses NavigationLink for stack-based navigation (iPhone).
    /// When false, uses Button with onSelect callback for selection-based navigation (iPad).
    var usesNavigationLink: Bool = true
    var onSelect: (() -> Void)?
    
    @Environment(\.colorScheme) private var colorScheme
    
    private var displayTitle: String {
        let cleaned = ChatSession.stripAttachmentMarkers(from: session.title)
        return cleaned.isEmpty ? ChatSession.defaultTitle : cleaned
    }
    
    var body: some View {
        if usesNavigationLink {
            NavigationLink(value: session.id) {
                cardContent
            }
            .buttonStyle(GlassCardButtonStyle(isSelected: isSelected))
        } else {
            Button {
                onSelect?()
            } label: {
                cardContent
            }
            .buttonStyle(GlassCardButtonStyle(isSelected: isSelected))
        }
    }
    
    private var cardContent: some View {
        HStack(spacing: 12) {
            // Status indicator
            statusIndicator
            
            // Content
            VStack(alignment: .leading, spacing: 6) {
                // Title row
                HStack(spacing: 6) {
                    Text(displayTitle)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    
                    if session.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                
                // Metadata row
                HStack(spacing: 8) {
                    // Time
                    Label {
                        Text(compactElapsed(since: session.updatedAt))
                            .font(.system(size: 12))
                    } icon: {
                        Image(systemName: "clock")
                            .font(.system(size: 10))
                    }
                    .foregroundStyle(.secondary)
                    
                    // Todo progress if available
                    if let todos = session.todos, !todos.isEmpty {
                        let completed = todos.filter { $0.status == .completed }.count
                        let inProgress = todos.contains { $0.status == .inProgress }
                        
                        HStack(spacing: 4) {
                            if inProgress {
                                ProgressView()
                                    .controlSize(.mini)
                            } else {
                                Image(systemName: completed == todos.count ? "checkmark.circle.fill" : "circle.dotted")
                                    .font(.system(size: 10))
                            }
                            Text("\(completed)/\(todos.count)")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(completed == todos.count ? Color.green : .secondary)
                    }
                }
            }
            
            Spacer(minLength: 0)
            
            // Streaming indicator
            if session.isStreaming {
                streamingIndicator
            }
            
            // Chevron
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
    
    // MARK: - Status Indicator
    
    @ViewBuilder
    private var statusIndicator: some View {
        let size: CGFloat = 10
        
        if let attention = session.attention {
            Circle()
                .fill(attention == .question ? Color.yellow : Color.orange)
                .frame(width: size, height: size)
                .glassEffect(.regular.tint(attention == .question ? .yellow : .orange), in: .circle)
        } else if session.hasUncheckedCompletion && !session.isStreaming {
            Circle()
                .fill(ClaudeTheme.statusSuccess)
                .frame(width: size, height: size)
                .glassEffect(.regular.tint(.green), in: .circle)
        } else {
            Circle()
                .fill(.clear)
                .frame(width: size, height: size)
        }
    }
    
    // MARK: - Streaming Indicator
    
    private var streamingIndicator: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(ClaudeTheme.accent)
                    .frame(width: 4, height: 4)
                    .opacity(0.6)
            }
        }
        .modifier(PulsingAnimation())
    }
    
    // MARK: - Helpers
    
    private func compactElapsed(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "now" }
        
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        
        let days = hours / 24
        if days < 7 { return "\(days)d" }
        
        let weeks = days / 7
        if weeks < 52 { return "\(weeks)w" }
        
        return "\(days / 365)y"
    }
}

// MARK: - Glass Card Button Style

private struct GlassCardButtonStyle: ButtonStyle {
    let isSelected: Bool
    @Environment(\.colorScheme) private var colorScheme
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(backgroundColor(isPressed: configuration.isPressed))
            }
            .glassEffect(
                glassConfig(isPressed: configuration.isPressed),
                in: .rect(cornerRadius: 16)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
    
    private func backgroundColor(isPressed: Bool) -> Color {
        if isSelected {
            return ClaudeTheme.accent.opacity(0.15)
        } else if isPressed {
            return Color.primary.opacity(0.05)
        } else {
            return .clear
        }
    }
    
    private func glassConfig(isPressed: Bool) -> Glass {
        if isSelected {
            return .regular.tint(ClaudeTheme.accent.opacity(0.3)).interactive()
        } else {
            return .regular.interactive()
        }
    }
}

// MARK: - Pulsing Animation

private struct PulsingAnimation: ViewModifier {
    @State private var isAnimating = false
    
    func body(content: Content) -> some View {
        content
            .opacity(isAnimating ? 0.4 : 1.0)
            .animation(
                .easeInOut(duration: 0.8)
                .repeatForever(autoreverses: true),
                value: isAnimating
            )
            .onAppear {
                isAnimating = true
            }
    }
}

// MARK: - Preview

#Preview {
    ScrollView {
        VStack(spacing: 12) {
            GlassThreadCard(
                session: SessionSummary(
                    id: "1",
                    projectId: UUID(),
                    title: "Implement Liquid Glass UI",
                    updatedAt: Date().addingTimeInterval(-300),
                    isPinned: true,
                    isArchived: false,
                    isStreaming: false,
                    attention: nil,
                    todos: [
                        TodoItem(id: 1, content: "Task 1", activeForm: "Doing task 1", status: .completed),
                        TodoItem(id: 2, content: "Task 2", activeForm: "Doing task 2", status: .inProgress),
                        TodoItem(id: 3, content: "Task 3", activeForm: "Doing task 3", status: .pending)
                    ],
                    hasUncheckedCompletion: false
                ),
                isSelected: true
            )
            
            GlassThreadCard(
                session: SessionSummary(
                    id: "2",
                    projectId: UUID(),
                    title: "Fix scrolling performance",
                    updatedAt: Date().addingTimeInterval(-3600),
                    isPinned: false,
                    isArchived: false,
                    isStreaming: true,
                    attention: nil,
                    todos: nil,
                    hasUncheckedCompletion: false
                ),
                isSelected: false
            )
            
            GlassThreadCard(
                session: SessionSummary(
                    id: "3",
                    projectId: UUID(),
                    title: "Review pull request",
                    updatedAt: Date().addingTimeInterval(-86400),
                    isPinned: false,
                    isArchived: false,
                    isStreaming: false,
                    attention: .permission,
                    todos: nil,
                    hasUncheckedCompletion: false
                ),
                isSelected: false
            )
        }
        .padding()
    }
    .background(Color(.systemGroupedBackground))
}
