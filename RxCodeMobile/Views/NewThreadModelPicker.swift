import OSLog
import RxCodeCore
import SwiftUI

/// Freeze the catalog for one presentation so sync traffic cannot reset scrolling.
struct NewThreadModelPickerSnapshot: Identifiable {
    let id = UUID()
    let sections: [AgentModelSection]
    let selectedProvider: AgentProvider?
    let selectedModelID: String?
}

struct NewThreadModelPicker: View {
    @Environment(\.dismiss) private var dismiss
    let snapshot: NewThreadModelPickerSnapshot
    let onSelect: (AgentModel) -> Void
    @State private var search = ""
    private static let logger = Logger(subsystem: "com.idealapp.RxCodeMobile", category: "ModelPicker")

    private var filteredSections: [AgentModelSection] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return snapshot.sections }
        return snapshot.sections.compactMap { section in
            let models = section.models.filter {
                section.title.localizedCaseInsensitiveContains(query)
                    || $0.displayName.localizedCaseInsensitiveContains(query)
                    || $0.id.localizedCaseInsensitiveContains(query)
            }
            guard !models.isEmpty else { return nil }
            return AgentModelSection(id: section.id, title: section.title, provider: section.provider,
                                     iconURL: section.iconURL, models: models)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(filteredSections) { section in
                    Section(section.title) {
                        ForEach(section.models, id: \.key) { model in
                            Button {
                                MobileHaptics.buttonTap()
                                onSelect(model)
                                dismiss()
                            } label: {
                                HStack {
                                    Text(model.displayName).foregroundStyle(.primary)
                                    Spacer()
                                    if snapshot.selectedProvider == model.provider,
                                       snapshot.selectedModelID == model.id {
                                        Image(systemName: "checkmark")
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                        }
                    }
                }
            }
            .accessibilityIdentifier("new-thread-model-list")
            .overlay {
                if filteredSections.allSatisfy({ $0.models.isEmpty }) {
                    ContentUnavailableView("No Models", systemImage: "cpu",
                                           description: Text("No models match the current selection."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .searchable(text: $search, prompt: "Search models")
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .navigationTitle("Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .onAppear {
            Self.logger.debug("PERFORMANCE: mobile model picker opened sections=\(snapshot.sections.count, privacy: .public) models=\(snapshot.sections.reduce(0) { $0 + $1.models.count }, privacy: .public)")
        }
    }
}
