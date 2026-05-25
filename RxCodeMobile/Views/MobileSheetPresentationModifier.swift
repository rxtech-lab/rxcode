import SwiftUI

private struct MobileSheetPresentationModifier: ViewModifier {
    let detents: Set<PresentationDetent>?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let detents {
            content
                .presentationDetents(detents)
                .presentationDragIndicator(.hidden)
                .interactiveDismissDisabled(true)
        } else {
            content
                .presentationDragIndicator(.hidden)
                .interactiveDismissDisabled(true)
        }
    }
}

extension View {
    func mobileSheetPresentation() -> some View {
        modifier(MobileSheetPresentationModifier(detents: nil))
    }

    func mobileSheetPresentation(_ detents: Set<PresentationDetent>) -> some View {
        modifier(MobileSheetPresentationModifier(detents: detents))
    }
}
