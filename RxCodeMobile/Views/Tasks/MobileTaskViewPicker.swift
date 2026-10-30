import RxCodeCore
import SwiftUI

/// Saved-view navigation and visibility actions stay available for read-only boards.
struct MobileTaskViewPicker: View {
    let views: [TaskSavedView]
    let currentView: TaskSavedView
    let defaultViewID: UUID
    let canReorderColumns: Bool
    let onSelect: (UUID) -> Void
    let onShowHidden: () -> Void
    let onHide: () -> Void
    let onReorderColumns: () -> Void
    let onCreate: () -> Void
    let onEdit: () -> Void
    let onSetDefault: () -> Void

    var body: some View {
        Menu {
            ForEach(views) { view in
                Button {
                    onSelect(view.id)
                    UISelectionFeedbackGenerator().selectionChanged()
                } label: {
                    Label(view.name, systemImage: view.id == currentView.id ? "checkmark" : view.layout.systemImage)
                }
            }
            Divider()
            Button("Hide View", systemImage: "eye.slash") { onHide() }
                .disabled(views.isEmpty)
            Button("Hidden Views", systemImage: "eye") {
                MobileHaptics.buttonTap()
                onShowHidden()
            }
            Divider()
            Button("Reorder Columns", systemImage: "arrow.left.arrow.right") {
                MobileHaptics.buttonTap()
                onReorderColumns()
            }
            .disabled(!canReorderColumns || views.isEmpty)
            Button {
                onCreate()
            } label: {
                Label("New View", systemImage: "plus")
            }
            Button {
                onEdit()
            } label: {
                Label("Edit View", systemImage: "pencil")
            }.disabled(currentView.hasFilterScript || views.isEmpty)
            Button {
                onSetDefault()
            } label: {
                Label("Set as Default View", systemImage: "star")
            }
            .disabled(views.isEmpty || currentView.hasFilterScript || currentView.id == defaultViewID)
        } label: {
            Label(views.isEmpty ? String(localized: "Views") : currentView.name, systemImage: currentView.layout.systemImage)
        }
        .contextMenu {
            Button("Hide View", systemImage: "eye.slash", action: onHide).disabled(views.isEmpty)
            Button("Hidden Views", systemImage: "eye") { MobileHaptics.buttonTap(); onShowHidden() }
        }
    }
}
