import RxCodeChatKit
import RxCodeCore
import SwiftUI

struct CodingPlanVisibleKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

struct CodingPlanChatSurface<Chat: View>: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var window
    let chat: Chat
    @State private var room: CodingPlanRoom?
    @State private var viewingPlan = false
    @State private var fullPlan: CodingPlan.Version?

    private var implementationMessage: ImplementationPlanMessage? {
        guard let plan = room?.plan, let approved = plan.approvedVersionID,
              let index = plan.versions.firstIndex(where: { $0.id == approved }) else { return nil }
        let version = plan.versions[index]
        return ImplementationPlanMessage(prompt: CodingPlan.implementationPrompt(for: version), versionNumber: index + 1) {
            fullPlan = version
        }
    }

    var body: some View {
        Group {
            if let room, window.currentSessionId == room.plan.id.uuidString {
                CodingPlanWorkspace(room: room, returnToChat: nil).id(room.plan.id)
            } else if let room, viewingPlan {
                CodingPlanWorkspace(room: room) { viewingPlan = false }
            } else {
                VStack(spacing: 0) {
                    if room != nil {
                        HStack {
                            Label("Implementation", systemImage: "hammer").font(.subheadline.weight(.semibold))
                            Spacer()
                            Button("View Plan", systemImage: "doc.text") { viewingPlan = true }
                                .accessibilityIdentifier("implementation-view-plan")
                        }
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        Divider()
                    }
                    chat
                        .environment(\.implementationPlanMessage, implementationMessage)
                }
            }
        }
        .onChange(of: window.currentSessionId, initial: true) { old, new in
            let next = new.flatMap { appState.codingPlanRoom(for: $0) }
            // Retain the chosen pane when the implementation's placeholder
            // takes on the provider's permanent session ID.
            if old.map(appState.resolveCurrentSessionId) != new {
                viewingPlan = false
                fullPlan = nil
            }
            room = next
        }
        .environment(\.offersCodingPlan, true)
        .preference(key: CodingPlanVisibleKey.self, value: room.map { window.currentSessionId == $0.plan.id.uuidString || viewingPlan } ?? false)
        .sheet(item: Bindable(window).chatCreationIntent) { intent in
            ChatCreationSheet(intent: intent)
        }
        .sheet(item: $fullPlan) { version in
            NavigationStack {
                ScrollView {
                    MarkdownContentView(text: version.markdown)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(22)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle("Approved Plan")
                .navigationSubtitle(version.title)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { fullPlan = nil }
                    }
                }
            }
            .frame(minWidth: 500, idealWidth: 660, minHeight: 400, idealHeight: 560, maxHeight: .infinity)
            .accessibilityIdentifier("implementation-full-plan-sheet")
        }
    }
}
