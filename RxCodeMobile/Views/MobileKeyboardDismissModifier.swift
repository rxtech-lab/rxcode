import SwiftUI

extension View {
    func mobileDismissesKeyboardOnScroll(
        _ mode: ScrollDismissesKeyboardMode = .interactively
    ) -> some View {
        scrollDismissesKeyboard(mode)
    }
}
