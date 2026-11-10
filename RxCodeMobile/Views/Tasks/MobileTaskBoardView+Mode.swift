import SwiftUI

extension MobileTaskBoardView {
    enum Mode: String, CaseIterable, Identifiable {
        case tasks
        case stories

        var id: String { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .tasks: "Tasks"
            case .stories: "Stories"
            }
        }
    }
}
