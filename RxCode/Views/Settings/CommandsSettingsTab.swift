import RxCodeChatKit
import RxCodeCore
import SwiftUI

/// Settings tab that hosts both the slash command manager and the shortcut
/// manager behind a segmented control.
struct CommandsSettingsTab: View {
    private enum Segment: Hashable {
        case slashCommands
        case shortcuts
    }

    @State private var segment: Segment = .slashCommands

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $segment) {
                Text("Slash Commands").tag(Segment.slashCommands)
                Text("Shortcuts").tag(Segment.shortcuts)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            switch segment {
            case .slashCommands:
                SlashCommandManagerView(isEmbedded: true)
            case .shortcuts:
                ShortcutManagerView(isEmbedded: true)
            }
        }
    }
}
