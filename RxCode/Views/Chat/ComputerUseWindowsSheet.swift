import RxCodeCore
import SwiftUI

/// Every previewed window streaming side by side. Choosing one pins it in the
/// floating preview.
struct ComputerUseWindowsSheet: View {
    @Environment(\.dismiss) private var dismiss

    let items: [ComputerUsePreviewItem]
    let canChooseWindow: Bool
    let onChooseWindow: () -> Void
    let onStopManualPreview: () -> Void
    let onSelect: (ComputerUsePreviewItem.ID) -> Void

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(ClaudeTheme.background)
                .navigationTitle("Computer Use Windows")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button("Choose Window…", systemImage: "macwindow.badge.plus", action: onChooseWindow)
                            .disabled(!canChooseWindow)
                            .help("Add another window to the preview")
                    }
                }
        }
        .frame(minWidth: 720, idealWidth: 960, maxWidth: .infinity, minHeight: 520, idealHeight: 720, maxHeight: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        if items.isEmpty {
            ContentUnavailableView(
                "No Windows to Preview",
                systemImage: "desktopcomputer",
                description: Text("Windows appear here while Codex uses your computer.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16)], spacing: 16) {
                    ForEach(items) { item in
                        ComputerUseWindowCard(item: item, onChooseWindow: onChooseWindow) {
                            onSelect(item.id)
                            dismiss()
                        }
                        .contextMenu { contextMenu(for: item) }
                    }
                }
                .padding(20)
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for item: ComputerUsePreviewItem) -> some View {
        Button("Show in Floating Preview", systemImage: "pip") {
            onSelect(item.id)
            dismiss()
        }
        if item.isRunningApp {
            Button("Bring App to Front", systemImage: "macwindow.on.rectangle", action: item.bringAppToFront)
        }
        if item.id == .manual {
            Divider()
            Button("Stop Window Preview", systemImage: "stop.circle", role: .destructive, action: onStopManualPreview)
        }
    }
}

private struct ComputerUseWindowCard: View {
    @State private var isHovered = false

    let item: ComputerUsePreviewItem
    let onChooseWindow: () -> Void
    let onSelect: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ComputerUsePreviewSurface(item: item, onChooseWindow: onChooseWindow)
                .aspectRatio(16 / 10, contentMode: .fit)
                .overlay(alignment: .topTrailing) {
                    ComputerUseLiveIndicator(item: item)
                        .padding(8)
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: onSelect)

            HStack(spacing: 10) {
                ComputerUseAppIcon(bundleID: item.bundleID, fallbackSymbol: item.fallbackSymbol, size: 24)
                    .foregroundStyle(ClaudeTheme.textSecondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(.system(size: ClaudeTheme.size(12.5), weight: .semibold))
                        .foregroundStyle(ClaudeTheme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let subtitle = item.subtitle {
                        Text(subtitle)
                            .font(.system(size: ClaudeTheme.size(11)))
                            .foregroundStyle(ClaudeTheme.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if item.isRunningApp {
                    Button("Bring App to Front", systemImage: "arrow.up.forward.app", action: item.bringAppToFront)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Bring App to Front")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .background(ClaudeTheme.surfaceElevated)
        .clipShape(.rect(cornerRadius: ClaudeTheme.cornerRadiusMedium))
        .overlay {
            RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusMedium)
                .strokeBorder(isHovered ? ClaudeTheme.accent.opacity(0.5) : ClaudeTheme.borderSubtle)
                .allowsHitTesting(false)
        }
        .shadow(color: ClaudeTheme.shadowColor, radius: isHovered ? 8 : 3, y: 2)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        .help("Click to show this window in the floating preview")
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Show in Floating Preview", onSelect)
    }
}
