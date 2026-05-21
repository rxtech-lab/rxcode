import SwiftUI
import UIKit

private struct MobileKeyboardDismissOnScrollModifier: ViewModifier {
    let mode: ScrollDismissesKeyboardMode
    @GestureState private var isDragging = false

    func body(content: Content) -> some View {
        content
            .scrollDismissesKeyboard(mode)
            .simultaneousGesture(
                DragGesture(minimumDistance: 2)
                    .updating($isDragging) { _, state, _ in
                        if !state {
                            UIApplication.shared.dismissKeyboard()
                        }
                        state = true
                    }
            )
    }
}

extension View {
    func mobileDismissesKeyboardOnScroll(
        _ mode: ScrollDismissesKeyboardMode = .interactively
    ) -> some View {
        modifier(MobileKeyboardDismissOnScrollModifier(mode: mode))
    }
}

private extension UIApplication {
    func dismissKeyboard() {
        sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }
}
