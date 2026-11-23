import SwiftUI
import TipKit

enum ChatFeatureTips {
    struct PlanModeTip: Tip {
        var title: Text {
            Text("Start in plan mode")
        }

        var message: Text? {
            Text("Choose Plan Mode in the Add menu to draft and review an implementation plan.")
        }

        var image: Image? {
            Image(systemName: "checklist")
        }

        var options: [any TipOption] {
            Tips.MaxDisplayCount(1)
        }
    }
}
