import RxCodeCore
import RxCodeChatKit
import SwiftUI

struct FlowcyToolsView: View {
    @Environment(FlowcyToolsState.self) private var tools
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("Connection") {
                    Label(tools.isConnected ? "Connected · Tools discovered" : "Disconnected", systemImage: tools.isConnected ? "checkmark.circle.fill" : "network.slash")
                    Text("Tools use your signed-in Flowcy account.").font(.caption)
                    Button("Reconnect") { Task { await tools.connect(); MobileHaptics.buttonTap() } }.disabled(tools.isBusy)
                    if let error = tools.error { Text(error).foregroundStyle(.red) }
                }
                Section("Available Tools") {
                    ForEach(tools.tools) { tool in
                        NavigationLink(tool.name) {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 16) {
                                    MarkdownContentView(text: tool.description ?? tool.name)
                                    Text(tool.isReadOnly ? "Read access" : "Confirmation required before execution").font(.caption)
                                }.padding()
                            }
                            .navigationTitle(tool.name)
                        }
                    }
                }
            }
            .navigationTitle("Flowcy Tools")
            .task { if !tools.isConnected { await tools.connect() } }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .overlay { if tools.isBusy { ProgressView("Connecting…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) } }
        }
    }
}
