#if os(macOS)
import SwiftUI
import RxCodeCore

// MARK: - Slash Command Popup

struct SlashCommandPopup: View {
    let query: String
    let agent: AgentProvider?
    let onSelect: (SlashCommand) -> Void
    @Binding var selectedIndex: Int
    @State private var detailCommand: SlashCommand?

    private var filtered: [SlashCommand] {
        SlashCommandRegistry.filtered(by: query, agent: agent)
    }

    func showDetailForSelected() {
        let cmds = filtered
        guard selectedIndex >= 0, selectedIndex < cmds.count else { return }
        let cmd = cmds[selectedIndex]
        if cmd.detailDescription != nil {
            detailCommand = cmd
        }
    }

    var body: some View {
        if filtered.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack {
                    Image(systemName: "command")
                        .font(.system(size: ClaudeTheme.size(10)))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                    Text("Slash Commands", bundle: .module)
                        .font(.system(size: ClaudeTheme.size(11), weight: .medium))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                    Spacer()
                    Text("\(filtered.count)")
                        .font(.system(size: ClaudeTheme.size(10)))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)

                ClaudeThemeDivider()

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(filtered.enumerated()), id: \.element.id) { index, cmd in
                                commandRowButton(cmd, isSelected: index == selectedIndex)
                                    .id(index)
                            }
                        }
                    }
                    .id(query)
                    .onChange(of: selectedIndex) { _, newValue in
                        withAnimation(.easeOut(duration: 0.1)) {
                            proxy.scrollTo(newValue, anchor: .center)
                        }
                    }
                }
            }
            .frame(height: 320)
            .background(ClaudeTheme.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusMedium))
            .overlay(
                RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusMedium)
                    .strokeBorder(ClaudeTheme.border, lineWidth: 1)
            )
            .shadow(color: ClaudeTheme.shadowColor, radius: 12, y: -4)
            .sheet(item: $detailCommand) { cmd in
                CommandDetailSheet(command: cmd)
                    .mobileSheetPresentation()
            }
        }
    }

    @ViewBuilder
    private func commandRowButton(_ cmd: SlashCommand, isSelected: Bool) -> some View {
        HStack(spacing: 0) {
            // Clicking this area executes the command
            Button {
                onSelect(cmd)
            } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(cmd.command)
                                .font(.system(size: ClaudeTheme.size(13), weight: .semibold, design: .monospaced))
                                .foregroundStyle(isSelected ? ClaudeTheme.accent : ClaudeTheme.textPrimary)

                            if cmd.acceptsInput {
                                Text("accepts input", bundle: .module)
                                    .font(.system(size: ClaudeTheme.size(9)))
                                    .foregroundStyle(ClaudeTheme.textTertiary)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(ClaudeTheme.surfaceSecondary, in: Capsule())
                            }
                        }

                        Text(LocalizedStringKey(cmd.description), bundle: .module)
                            .font(.system(size: ClaudeTheme.size(11)))
                            .foregroundStyle(ClaudeTheme.textSecondary)
                            .lineLimit(1)
                    }

                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if cmd.detailDescription != nil {
                Button {
                    detailCommand = cmd
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: ClaudeTheme.size(13)))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerCursorOnHover()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isSelected ? ClaudeTheme.accentSubtle : Color.clear)
    }

    var filteredCount: Int { filtered.count }

    func command(at index: Int) -> SlashCommand? {
        guard index >= 0 && index < filtered.count else { return nil }
        return filtered[index]
    }
}

// MARK: - Command Detail Sheet

struct CommandDetailSheet: View {
    let command: SlashCommand
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(command.command)
                        .font(.system(size: ClaudeTheme.size(16), weight: .bold, design: .monospaced))
                        .foregroundStyle(ClaudeTheme.textPrimary)

                    Text(LocalizedStringKey(command.description), bundle: .module)
                        .font(.system(size: ClaudeTheme.size(13)))
                        .foregroundStyle(ClaudeTheme.textSecondary)
                }

                Spacer()
            }
            .padding(20)

            ClaudeThemeDivider()

            // Body
            ScrollView {
                if let detail = command.detailDescription {
                    Text(LocalizedStringKey(detail))
                        .font(.system(size: ClaudeTheme.size(13)))
                        .foregroundStyle(ClaudeTheme.textPrimary)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                }
            }

            ClaudeThemeDivider()

            // Close
            HStack {
                Spacer()
                Button(String(localized: "Close", bundle: .module)) { dismiss() }
                    .buttonStyle(ClaudeSecondaryButtonStyle())
            }
            .padding(16)
        }
        .frame(width: 520, height: 480)
        .background(ClaudeTheme.background)
    }
}

// MARK: - SlashCommand + Identifiable for sheet

// SlashCommand: Hashable conformance is in the struct declaration (name-based identity)

// MARK: - Command Menu Button

struct CommandMenuButton: View {
    let messages: [ChatMessage]
    @State private var isCopied = false
    @State private var showUsagePopover = false
    @State private var showCommandManager = false

    var body: some View {
        Menu {
            Button {
                copyConversation()
            } label: {
                Label(isCopied ? String(localized: "Copied", bundle: .module) : String(localized: "Copy Conversation", bundle: .module), systemImage: isCopied ? "checkmark" : "doc.on.doc")
            }
            .disabled(messages.isEmpty)

            Button {
                showUsagePopover = true
            } label: {
                Label(String(localized: "Usage", bundle: .module), systemImage: "chart.bar")
            }

            Divider()

            Button {
                showCommandManager = true
            } label: {
                Label(String(localized: "Manage Commands", bundle: .module), systemImage: "slider.horizontal.3")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: ClaudeTheme.size(14)))
                .foregroundStyle(ClaudeTheme.textSecondary)
        }
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .help("Commands")
        .popover(isPresented: $showUsagePopover, arrowEdge: .top) { UsagePopoverView() }
        .sheet(isPresented: $showCommandManager) {
            SlashCommandManagerView()
                .mobileSheetPresentation()
        }
    }

    private func copyConversation() {
        let text = messages.map { msg in
            let role = msg.role == .user ? "Me" : "Claude"
            return "[\(role)] \(msg.content)"
        }.joined(separator: "\n\n")

        copyToClipboard(text, feedback: $isCopied)
    }
}

// MARK: - Usage Popover

struct UsagePopoverView: View {
    @Environment(ChatBridge.self) private var chatBridge

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Session Usage", bundle: .module)
                .font(.system(size: ClaudeTheme.size(13), weight: .semibold))
                .foregroundStyle(ClaudeTheme.textPrimary)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                usageRow(icon: "dollarsign.circle", label: "Cost", value: formatCost(chatBridge.sessionStats.costUsd))
                usageRow(icon: "arrow.down.circle", label: "Input tokens", value: formatTokens(chatBridge.sessionStats.inputTokens))
                usageRow(icon: "arrow.up.circle", label: "Output tokens", value: formatTokens(chatBridge.sessionStats.outputTokens))
                usageRow(icon: "square.stack", label: "Cache creation", value: formatTokens(chatBridge.sessionStats.cacheCreationTokens))
                usageRow(icon: "square.stack.fill", label: "Cache read", value: formatTokens(chatBridge.sessionStats.cacheReadTokens))
                usageRow(icon: "clock", label: "Duration", value: formatDuration(chatBridge.sessionStats.durationMs))
                usageRow(icon: "arrow.triangle.2.circlepath", label: "Turns", value: "\(chatBridge.sessionStats.turns)")
            }
        }
        .padding(16)
        .frame(width: 240)
    }

    @ViewBuilder
    private func usageRow(icon: String, label: String, value: String) -> some View {
        GridRow {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(ClaudeTheme.textTertiary)
                    .frame(width: 14)
                Text(label)
                    .font(.system(size: ClaudeTheme.size(12)))
                    .foregroundStyle(ClaudeTheme.textSecondary)
            }
            Text(value)
                .font(.system(size: ClaudeTheme.size(12), weight: .medium, design: .monospaced))
                .foregroundStyle(ClaudeTheme.textPrimary)
        }
    }

    private func formatCost(_ cost: Double) -> String {
        if cost == 0 { return "—" }
        return String(format: "$%.4f", cost)
    }

    private func formatTokens(_ tokens: Int) -> String {
        if tokens == 0 { return "—" }
        if tokens >= 1_000_000 {
            return String(format: "%.1fm", Double(tokens) / 1_000_000)
        } else if tokens >= 1_000 {
            return String(format: "%.1fk", Double(tokens) / 1_000)
        }
        return "\(tokens)"
    }

    private func formatDuration(_ ms: Double) -> String {
        if ms == 0 { return "—" }
        let seconds = Int(ms / 1_000)
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        let secs = seconds % 60
        return "\(minutes)m \(secs)s"
    }
}
#endif
