import RxCodeCore
import SwiftUI

/// Restore saved views without changing their filters, defaults, or tab order.
public struct TaskHiddenViewsSheet: View {
    let views: [TaskSavedView]
    let isSaving: Bool
    let feedback: String?
    let onRestore: (TaskSavedView) -> Void
    let onDone: () -> Void

    public init(views: [TaskSavedView], isSaving: Bool = false, feedback: String?,
                onRestore: @escaping (TaskSavedView) -> Void, onDone: @escaping () -> Void) {
        self.views = views
        self.isSaving = isSaving
        self.feedback = feedback
        self.onRestore = onRestore
        self.onDone = onDone
    }

    public var body: some View {
        NavigationStack {
            Group {
                let hidden = views.filter(\.isHidden)
                if hidden.isEmpty {
                    ContentUnavailableView("No Hidden Views", systemImage: "eye")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(hidden) { view in
                        HStack {
                            Label(view.name, systemImage: view.layout.systemImage)
                            Spacer()
                            Button("Restore") { onRestore(view) }.disabled(isSaving)
                        }
                    }
                }
            }
            .navigationTitle("Hidden Views")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", action: onDone) } }
            .overlay(alignment: .top) {
                TaskViewSaveFeedback(isSaving: isSaving, feedback: feedback)
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 440, maxHeight: .infinity)
        #endif
    }
}

/// Transient status shared by saved-view actions and their restore sheet.
public struct TaskViewSaveFeedback: View {
    let isSaving: Bool
    let feedback: String?

    public init(isSaving: Bool, feedback: String?) {
        self.isSaving = isSaving
        self.feedback = feedback
    }

    public var body: some View {
        if isSaving || feedback != nil {
            Group {
                if isSaving {
                    ProgressView("Saving view…")
                } else if let feedback {
                    Label(feedback, systemImage: "checkmark.circle.fill")
                }
            }
            .padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)).padding()
        }
    }
}
