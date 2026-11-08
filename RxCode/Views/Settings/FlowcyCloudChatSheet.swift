import RxCodeCore
import RxCodeChatKit
import SwiftUI

struct FlowcyCloudChatSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var chat: FlowcyCloudChat
    @State private var prompt = ""
    @State private var confirmClear = false
    init(auth: RxAuthService) { _chat = State(initialValue: FlowcyCloudChat(auth: auth)) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if chat.messages.isEmpty {
                    ContentUnavailableView("Flowcy Cloud Chat", systemImage: "cloud", description: Text("Chat with enabled Flowcy models. This conversation does not access local project files or tools."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            ForEach(chat.messages) { message in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(message.role == "user" ? "You" : "Flowcy").font(.caption).foregroundStyle(.secondary)
                                    MarkdownContentView(text: message.text, style: .rxCodeCompact)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }.padding()
                    }
                }
                Divider()
                HStack {
                    TextField("Message", text: $prompt, axis: .vertical).lineLimit(1...5)
                        .onSubmit { send() }
                    if chat.streaming { Button("Stop") { chat.stop() } }
                    else { Button("Send") { send() }.disabled(chat.selectedModel == nil || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                }.padding()
            }
            .navigationTitle("Flowcy Cloud Chat")
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Picker("Model", selection: $chat.selectedModel) {
                        Text("Select a model").tag(String?.none)
                        ForEach(chat.models) { model in Text(model.alias).tag(Optional(model.id)) }
                    }.disabled(chat.streaming).frame(maxWidth: 250)
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await chat.load() } }.disabled(chat.loading || chat.streaming)
                    Button("New Chat", systemImage: "square.and.pencil") { confirmClear = true }
                    Button("Done") { dismiss() }
                }
            }
            .overlay { if chat.loading { ProgressView("Loading cloud models…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
            .alert("Flowcy", isPresented: Binding(get: { chat.error != nil }, set: { if !$0 { chat.error = nil } })) { Button("OK") { chat.error = nil } } message: { Text(chat.error ?? "") }
            .confirmationDialog("Clear this conversation?", isPresented: $confirmClear) { Button("Clear", role: .destructive) { chat.clear() } }
            .task { await chat.load() }
            .onDisappear { chat.stop() }
        }
        .frame(minWidth: 680, idealWidth: 760, minHeight: 560, idealHeight: 680)
    }
    private func send() {
        guard !chat.streaming, chat.selectedModel != nil else { return }
        chat.send(prompt)
        prompt = ""
    }
}
