import RxCodeCore
import SwiftUI

/// Asks which paired Mac runs a task before it enters a chat column. The
/// choice is remembered on the task, so its card can open the session there.
struct MobileTaskRunDeviceSheet: View {
    @EnvironmentObject private var state: MobileAppState
    @Environment(\.dismiss) private var dismiss
    let request: MobileTaskRunRequest

    @State private var selectedID: String?
    @State private var progressMessage: String?
    @State private var errorMessage: String?

    private var board: TaskBoard { state.taskBoard(for: request.task.projectId) }

    private var selectedDesktop: PairedDesktop? {
        state.pairedDesktops.first { $0.id == selectedID && state.canRunTasks(on: $0) }
    }

    private var isWorking: Bool { progressMessage != nil }

    var body: some View {
        List {
            Section {
                LabeledContent("Task", value: request.task.title.isEmpty ? String(localized: "Untitled Task") : request.task.title)
                LabeledContent("Column", value: board.column(for: request.status).name)
            }

            Section {
                ForEach(state.pairedDesktops) { desktop in
                    desktopRow(desktop)
                }
            } header: {
                Text("Paired Macs")
            } footer: {
                Text(state.usesCloudTasks
                     ? "The Mac must have this project open. Tap the card later to open its session on that Mac."
                     : "Tasks on this board run on the Mac it belongs to. Tap the card later to open its session.")
            }

            if state.usesCloudTasks {
                Section {
                    Button("Move Without Running") {
                        moveOnly()
                    }
                    .accessibilityIdentifier("task-run-device-move-only")
                }
            }
        }
        .navigationTitle("Run on Mac")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    MobileHaptics.buttonTap()
                    dismiss()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Run") { run() }
                    .disabled(selectedDesktop == nil)
                    .accessibilityIdentifier("task-run-device-confirm")
            }
        }
        .disabled(isWorking)
        .overlay {
            if let progressMessage {
                ProgressView(progressMessage)
                    .padding(16)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .interactiveDismissDisabled(isWorking)
        .onAppear {
            if selectedID == nil { selectedID = state.defaultRunDesktop()?.id }
        }
        .mobileTaskErrorAlert($errorMessage)
    }

    private func desktopRow(_ desktop: PairedDesktop) -> some View {
        let canRun = state.canRunTasks(on: desktop)
        return Button {
            selectedID = desktop.id
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "desktopcomputer")
                    .font(.title3)
                    .foregroundStyle(canRun ? Color.accentColor : .secondary)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(desktop.displayName)
                        .foregroundStyle(canRun ? .primary : .secondary)
                    subtitle(for: desktop, canRun: canRun)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if selectedID == desktop.id && canRun {
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canRun)
        .accessibilityIdentifier("task-run-device-\(desktop.pubkeyHex.prefix(12))")
    }

    private func subtitle(for desktop: PairedDesktop, canRun: Bool) -> Text {
        if desktop.id == state.activePairedDesktop?.id {
            return state.isDesktopTaskSyncReady ? Text("Connected") : Text("Current Mac")
        }
        if !canRun {
            return Text("Has its own task board")
        }
        if let lastSeen = desktop.lastSeen {
            return Text("Last seen \(lastSeen, style: .relative) ago")
        }
        return Text("Switches to this Mac")
    }

    private func run() {
        guard let desktop = selectedDesktop else { return }
        MobileHaptics.buttonTap()
        progressMessage = String(localized: "Starting on \(desktop.displayName)…")
        Task {
            defer { progressMessage = nil }
            do {
                try await state.runTask(request.task, to: request.status, sortIndex: request.sortIndex, on: desktop)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }

    private func moveOnly() {
        MobileHaptics.buttonTap()
        progressMessage = String(localized: "Moving task…")
        Task {
            defer { progressMessage = nil }
            do {
                try await state.moveTask(request.task, to: request.status, sortIndex: request.sortIndex)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }
}

/// Presents the Mac picker while `request` is non-nil.
struct MobileTaskRunDevicePicker: ViewModifier {
    @EnvironmentObject private var state: MobileAppState
    @Binding var request: MobileTaskRunRequest?

    func body(content: Content) -> some View {
        content.sheet(item: $request) { request in
            NavigationStack {
                MobileTaskRunDeviceSheet(request: request)
                    .environmentObject(state)
            }
            .mobileSheetPresentation([.medium])
        }
    }
}

extension View {
    func mobileTaskRunDevicePicker(_ request: Binding<MobileTaskRunRequest?>) -> some View {
        modifier(MobileTaskRunDevicePicker(request: request))
    }
}
