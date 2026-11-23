import RxCodeChatKit
import RxCodeCore
import SwiftUI

struct CodingPlanReviewersSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let room: CodingPlanRoom
    let addReviewer: (CodingPlan.Reviewer) throws -> Void
    @State private var addingReviewer = false

    var body: some View {
        NavigationStack {
            Group {
                if room.plan.configuration.reviewers.isEmpty {
                    ContentUnavailableView("No Reviewers", systemImage: "person.2")
                } else {
                    Form {
                        ForEach(Array(room.plan.configuration.reviewers.enumerated()), id: \.element.id) { index, reviewer in
                            Section {
                                LabeledContent("Provider", value: providerLabel(for: reviewer.model))
                                LabeledContent("Model", value: reviewer.model.displayName)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Review instructions").font(.headline)
                                    if reviewer.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        Text("No instructions provided.").foregroundStyle(.secondary)
                                    } else {
                                        MarkdownContentView(text: reviewer.prompt, style: .rxCodeCompact)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            } header: {
                                HStack {
                                    Text("Reviewer \(index + 1)")
                                    Spacer()
                                    Text(status(for: index)).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .formStyle(.grouped)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Reviewers")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                if room.canAddReviewer {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add Reviewer…", systemImage: "plus") { addingReviewer = true }
                            .accessibilityIdentifier("coding-plan-add-reviewer")
                    }
                }
            }
        }
        .frame(minWidth: 440, idealWidth: 520, minHeight: 360, idealHeight: 480, maxHeight: .infinity)
        .sheet(isPresented: $addingReviewer) {
            CodingPlanReviewerSheet(reviewer: .init(model: room.plan.configuration.planner, prompt: ""),
                                    title: "Add Reviewer", save: addReviewer)
        }
    }

    private func providerLabel(for model: AgentModel) -> String {
        let provider = model.provider.displayNameText
        guard model.provider == .acp, let clientID = AppState.splitACPModelKey(model.id)?.clientId else { return provider }
        let client = appState.acpClients.first { $0.id == clientID }?.displayName ?? clientID
        return "\(provider) · \(client)"
    }

    private func status(for index: Int) -> LocalizedStringKey {
        if index < room.plan.completedReviewerCount { return "Reviewed" }
        if room.runID != nil, room.plan.nextStep == .review(index) { return "Reviewing" }
        return "Queued"
    }
}
