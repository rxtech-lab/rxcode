import SwiftUI

extension View {
    @ViewBuilder
    func mobileSheetPresentation() -> some View {
#if os(iOS)
        self
            .presentationDragIndicator(.hidden)
            .interactiveDismissDisabled(true)
#else
        self
#endif
    }
}
