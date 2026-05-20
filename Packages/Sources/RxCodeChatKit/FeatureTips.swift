import SwiftUI
import TipKit

enum ChatFeatureTips {
    struct PlanModeTip: Tip {
        var title: Text {
            Text("Start in plan mode")
        }

        var message: Text? {
            Text("Use the Add menu or Shift-Tab to ask the agent for a read-only plan before edits begin.")
        }

        var image: Image? {
            Image(systemName: "checklist")
        }

        var options: [any TipOption] {
            Tips.MaxDisplayCount(1)
        }
    }
}
