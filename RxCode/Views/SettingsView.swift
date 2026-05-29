import RxCodeChatKit
import RxCodeCore
import SwiftUI
import TipKit

// MARK: - Settings Sheet

struct SettingsView: View {
    @Environment(AppState.self) private var appState

    @State private var selectedTab = 0
    @State private var showUserManual = false
    @State private var showOnboarding = false

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsTab(
                showUserManual: $showUserManual,
                showOnboarding: $showOnboarding
            )
            .tabItem {
                Label("General", systemImage: "slider.horizontal.3")
            }
            .tag(0)

            ChatSettingsTab()
                .tabItem {
                    Label("Message", systemImage: "bubble.left.and.bubble.right")
                }
                .tag(1)

            CommandsSettingsTab()
                .tabItem {
                    Label("Commands", systemImage: "command")
                }
                .tag(2)

            SkillMarketView(isEmbedded: true)
                .tabItem {
                    Label("Skill Marketplace", systemImage: "brain.head.profile")
                }
                .tag(3)

            MCPSettingsTab()
                .tabItem {
                    Label("MCP", systemImage: "puzzlepiece.extension")
                }
                .tag(4)

            ACPClientSettingsTab()
                .tabItem {
                    Label("ACP Clients", systemImage: "link.circle")
                }
                .tag(5)

            MobileSettingsTab()
                .tabItem {
                    Label("Mobile", systemImage: "iphone.gen3")
                }
                .tag(6)

            AutopilotSettingsTab()
                .tabItem {
                    Label("Autopilot", systemImage: "paperplane.circle")
                }
                .tag(7)
        }
        .frame(width: 680, height: 620)
        .focusable(false)
        .onAppear { selectedTab = 0 }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            guard let window = notification.object as? NSWindow,
                  window.title == "Settings" else { return }
            selectedTab = 0
        }
        .sheet(isPresented: $showUserManual) {
            UserManualView()
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView {
                showOnboarding = false
            }
            .environment(appState)
        }
    }
}

// MARK: - General Settings Tab

struct GeneralSettingsTab: View {
    @Environment(AppState.self) private var appState
    @Binding var showUserManual: Bool
    @Binding var showOnboarding: Bool
    @State private var showThemePicker = false
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra: Bool = true

    var body: some View {
        @Bindable var appState = appState
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                themeSection
                Divider()
                fontSizeSection
                Divider()
                notificationsSection(appState: $appState.notificationsEnabled)
                Divider()
                menuBarSection
                Divider()
                searchIndexSection
                Divider()
                MemorySettingsSection()
                Divider()
                HooksSettingsSection()
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    onboardingSection
                    helpSection
                    sourceCodeSection
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Search Index Section

    private var searchIndexSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Search Index")
                .font(.system(size: ClaudeTheme.size(13), weight: .semibold))

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Reindex all threads")
                        .font(.system(size: ClaudeTheme.size(13)))
                    Text("Wipe cached embeddings and re-embed every thread for semantic search. Use this if global search results look stale or empty.")
                        .font(.system(size: ClaudeTheme.size(11)))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button {
                    Task { await appState.reindexAllThreads() }
                } label: {
                    if let progress = appState.reindexProgress {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            if progress.total > 0 {
                                Text(verbatim: "\(progress.done)/\(progress.total)")
                                    .font(.system(size: ClaudeTheme.size(12)))
                                    .monospacedDigit()
                            }
                        }
                    } else {
                        Text("Reindex Now")
                    }
                }
                .disabled(appState.reindexProgress != nil)
            }
        }
    }

    // MARK: - Menu Bar Section

    private var menuBarSection: some View {
        toggleSection(
            title: "Menu Bar",
            label: "Show menu bar icon",
            detail: "Shows in-progress chat counts and Claude Code usage limits in the macOS menu bar.",
            isOn: $showMenuBarExtra
        )
    }

    // MARK: - Toggle Section

    private func toggleSection(
        title: LocalizedStringKey,
        label: LocalizedStringKey,
        detail: LocalizedStringKey,
        isOn: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: ClaudeTheme.size(13), weight: .semibold))

            Toggle(isOn: isOn) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.system(size: ClaudeTheme.size(13)))
                    Text(detail)
                        .font(.system(size: ClaudeTheme.size(11)))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
        }
    }

    // MARK: - Font Size Section

    private var fontSizeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Font Size")
                .font(.system(size: ClaudeTheme.size(13), weight: .semibold))
            fontSizeRow(
                label: "Interface",
                value: appState.fontSizeAdjustment,
                onDecrease: { appState.decreaseFontSize() },
                onIncrease: { appState.increaseFontSize() },
                onReset: { appState.fontSizeAdjustment = 0 }
            )
            fontSizeRow(
                label: "Messages",
                value: appState.messageFontSizeAdjustment,
                onDecrease: { appState.decreaseMessageFontSize() },
                onIncrease: { appState.increaseMessageFontSize() },
                onReset: { appState.messageFontSizeAdjustment = 0 }
            )
            Text("font.size.hint")
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(.secondary)
        }
    }

    private func fontSizeRow(label: LocalizedStringKey, value: Int, onDecrease: @escaping () -> Void, onIncrease: @escaping () -> Void, onReset: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: ClaudeTheme.size(12)))
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            fontStepButton(systemName: "minus", action: onDecrease)
                .disabled(value <= ThemeStore.minFontSizeAdjustment)
            Group {
                if value == 0 {
                    Text("Default")
                } else {
                    Text(verbatim: value > 0 ? "+\(value)" : "\(value)")
                }
            }
            .font(.system(size: ClaudeTheme.size(13), weight: .medium))
            .frame(minWidth: 48, alignment: .center)
            fontStepButton(systemName: "plus", action: onIncrease)
                .disabled(value >= ThemeStore.maxFontSizeAdjustment)
            if value != 0 {
                Button("Reset", action: onReset)
                    .buttonStyle(.plain)
                    .font(.system(size: ClaudeTheme.size(12)))
                    .foregroundStyle(ClaudeTheme.accent)
            }
        }
    }

    private func fontStepButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .frame(width: 26, height: 26)
                .background(Color(NSColor.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(NSColor.separatorColor), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Notifications Section

    private func notificationsSection(appState: Binding<Bool>) -> some View {
        toggleSection(
            title: "Notifications",
            label: "Notify when response completes",
            detail: "Sends a system notification while RxCode is in the background.",
            isOn: appState
        )
    }

    // MARK: - Theme Section

    private var themeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Theme")
                .font(.system(size: ClaudeTheme.size(13), weight: .semibold))

            Button {
                showThemePicker.toggle()
            } label: {
                HStack(spacing: 8) {
                    Circle()
                        .fill(appState.selectedTheme.colors.accent)
                        .frame(width: 10, height: 10)
                    Text(appState.selectedTheme.displayName)
                        .font(.system(size: ClaudeTheme.size(13)))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: ClaudeTheme.size(10)))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(NSColor.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color(NSColor.separatorColor), lineWidth: 1)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showThemePicker, arrowEdge: .bottom) {
                VStack(spacing: 0) {
                    ForEach(AppTheme.allCases) { theme in
                        ThemePickerRow(
                            theme: theme,
                            isSelected: appState.selectedTheme == theme
                        ) {
                            appState.selectedTheme = theme
                            showThemePicker = false
                        }
                    }
                }
                .padding(4)
                .frame(minWidth: 220)
                .focusable(false)
            }
        }
    }

    // MARK: - Source Code Section

    private var sourceCodeSection: some View {
        Link(destination: URL(string: "https://github.com/rxtech-lab/rxcode")!) {
            HStack(spacing: 10) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: ClaudeTheme.size(14)))
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Open Source")
                        .font(.system(size: ClaudeTheme.size(13)))
                        .foregroundStyle(.primary)
                    Text(verbatim: "github.com/rxtech-lab/rxcode")
                        .font(.system(size: ClaudeTheme.size(11)))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color(NSColor.separatorColor), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Help Section

    private var onboardingSection: some View {
        Button {
            showOnboarding = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: ClaudeTheme.size(14)))
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Show Onboarding")
                        .font(.system(size: ClaudeTheme.size(13)))
                        .foregroundStyle(.primary)
                    Text("Review the CLI setup check")
                        .font(.system(size: ClaudeTheme.size(11)))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color(NSColor.separatorColor), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var helpSection: some View {
        Button {
            showUserManual = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "book.fill")
                    .font(.system(size: ClaudeTheme.size(14)))
                    .frame(width: 20)
                Text("User Guide")
                    .font(.system(size: ClaudeTheme.size(13)))
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color(NSColor.separatorColor), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    SettingsView()
        .environment(AppState())
        .environment(WindowState())
}
