import SwiftUI
import RxCodeCore

// MARK: - Flow Layout

/// A layout that arranges views horizontally and wraps to the next line when needed.
struct BriefingFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        return layout(sizes: sizes, containerWidth: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let offsets = layout(sizes: sizes, containerWidth: bounds.width).offsets

        for (index, subview) in subviews.enumerated() {
            subview.place(
                at: CGPoint(x: bounds.minX + offsets[index].x, y: bounds.minY + offsets[index].y),
                proposal: ProposedViewSize(sizes[index])
            )
        }
    }

    private func layout(sizes: [CGSize], containerWidth: CGFloat) -> (offsets: [CGPoint], size: CGSize) {
        var offsets: [CGPoint] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var maxWidth: CGFloat = 0

        for size in sizes {
            if currentX + size.width > containerWidth && currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }

            offsets.append(CGPoint(x: currentX, y: currentY))
            lineHeight = max(lineHeight, size.height)
            currentX += size.width + spacing
            maxWidth = max(maxWidth, currentX - spacing)
        }

        return (offsets, CGSize(width: maxWidth, height: currentY + lineHeight))
    }
}

// MARK: - CI Status Chip

struct MobileCIStatusChip: View {
    let status: ProjectCIStatus
    var compact: Bool = false
    var linksFailingRun: Bool = false

    private var failingRunURL: URL? {
        guard status.overallState == .failure,
              let urlString = status.failing.first?.htmlUrl
        else { return nil }
        return URL(string: urlString)
    }

    var body: some View {
        if linksFailingRun, let url = failingRunURL {
            Link(destination: url) {
                label
            }
            .accessibilityLabel(Text("Open failing CI run", tableName: "Localizable"))
        } else {
            label
        }
    }

    private var label: some View {
        HStack(spacing: compact ? 3 : 4) {
            Image(systemName: status.overallState.mobileSFSymbolName)
                .font(.system(size: compact ? 9 : 10, weight: .semibold))
            Text(status.overallState.mobileLabel)
                .font(compact ? .system(size: 11, weight: .medium) : .caption.weight(.medium))
                .lineLimit(1)
        }
        .foregroundStyle(status.overallState.mobileDisplayColor)
        .padding(.horizontal, compact ? 0 : 8)
        .padding(.vertical, compact ? 0 : 4)
        .background {
            if !compact {
                Capsule()
                    .fill(status.overallState.mobileDisplayColor.opacity(0.12))
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private extension CIOverallState {
    var mobileDisplayColor: Color {
        switch self {
        case .success: .green
        case .failure: .red
        case .pending: .yellow
        case .unknown: .secondary
        }
    }

    var mobileSFSymbolName: String {
        switch self {
        case .success: "checkmark.circle.fill"
        case .failure: "xmark.circle.fill"
        case .pending: "clock.fill"
        case .unknown: "questionmark.circle"
        }
    }

    var mobileLabel: LocalizedStringKey {
        switch self {
        case .success: "Passing"
        case .failure: "Failing"
        case .pending: "Running"
        case .unknown: "No status"
        }
    }
}
