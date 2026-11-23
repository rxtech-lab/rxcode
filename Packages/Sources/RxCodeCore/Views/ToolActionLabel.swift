import SwiftUI

/// Displays an action immediately, then refines external tool names on device.
public struct ToolActionLabel<Content: View>: View {
    private let identifier: String
    private let systemLabel: String?
    private let content: (String) -> Content
    @State private var generated: (identifier: String, label: String)?

    public init(_ identifier: String, @ViewBuilder content: @escaping (String) -> Content) {
        self.identifier = identifier
        self.systemLabel = ToolActionName.systemLabel(for: identifier)
        self.content = content
    }

    public init(_ call: ToolCall, @ViewBuilder content: @escaping (String) -> Content) {
        identifier = call.actionNameIdentifier
        systemLabel = call.namedTodoActionLabel ?? ToolActionName.systemLabel(for: identifier)
        self.content = content
    }

    public var body: some View {
        if let label = systemLabel {
            content(label)
        } else {
            content(externalLabel)
                .task(id: identifier) {
                    guard let label = await ToolNameHumanizer.shared.label(for: identifier),
                          !Task.isCancelled else { return }
                    generated = (identifier, label)
                }
        }
    }

    private var externalLabel: String {
        if let generated, generated.identifier == identifier { return generated.label }
        return ToolActionName.fallbackLabel(for: identifier)
    }
}

extension ToolActionLabel where Content == Text {
    public init(_ identifier: String) {
        self.init(identifier) { Text(verbatim: $0) }
    }

    public init(_ call: ToolCall) {
        self.init(call) { Text(verbatim: $0) }
    }
}
