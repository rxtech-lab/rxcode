import SwiftUI

/// Shared column layout: a fixed header above independently scrolling, lazy cards.
/// Hosts supply their platform's controls and card actions.
public struct TaskKanbanColumnContent<Header: View, Cards: View>: View {
    private let headerSpacing: CGFloat
    private let cardInsets: EdgeInsets
    private let header: Header
    private let cards: Cards

    public init(
        headerSpacing: CGFloat = 10,
        cardInsets: EdgeInsets = EdgeInsets(top: 0, leading: 0, bottom: 8, trailing: 0),
        @ViewBuilder header: () -> Header,
        @ViewBuilder cards: () -> Cards
    ) {
        self.headerSpacing = headerSpacing
        self.cardInsets = cardInsets
        self.header = header()
        self.cards = cards()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: headerSpacing) {
            header
            ScrollView {
                LazyVStack(spacing: 8) { cards }
                    .padding(cardInsets)
            }
            .scrollContentBackground(.hidden)
        }
    }
}
