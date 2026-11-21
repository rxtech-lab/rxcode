import RxCodeCore
import SwiftUI

/// The lists a file row can fly between. `nil` stands for the footer's Amend control.
enum GitFlightPane: Hashable {
    case unstaged, staged, original
}

struct GitFlightItem: Identifiable {
    enum Label {
        case change(GitChangeFile)
        case commit(GitCommitFile)
    }

    /// Path of the row the item leaves, or the row it lands on when it comes from the footer.
    let id: String
    var label: Label
    /// Path of the row it lands on, when that differs from `id`.
    var landingPath: String?

    var destinationPath: String { landingPath ?? id }
}

/// A group of rows moving from one place to another, drawn above the native lists.
struct GitFileFlight: Identifiable {
    let id = UUID()
    let source: GitFlightPane?
    let destination: GitFlightPane?
    var items: [GitFlightItem]
    /// Set once the overlay has measured the rows and drawn their stand-ins.
    var lifted = false
    /// Set once the destination rows exist and the items can travel.
    var landing = false

    /// Hides the real row while its stand-in is in the air, so the file shows only once.
    func hides(_ path: String, in pane: GitFlightPane) -> Bool {
        items.contains { item in
            (lifted && pane == source && item.id == path) || (pane == destination && item.destinationPath == path)
        }
    }

    func tracks(_ path: String) -> Bool {
        items.contains { $0.id == path || $0.destinationPath == path }
    }

    static let maxItems = 24
}

struct GitTransferAnchors: PreferenceKey {
    enum Location: Hashable {
        case pane(staged: Bool)
        case row(GitFlightPane, String)
    }

    static var defaultValue: [Location: Anchor<CGRect>] { [:] }
    static func reduce(value: inout [Location: Anchor<CGRect>], nextValue: () -> [Location: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Lifts copies of the moving rows out of their list and carries each one to the
/// row it becomes, so a file reads as a single object crossing the split.
struct GitFileTransferOverlay: View {
    let flight: GitFileFlight
    let anchors: [GitTransferAnchors.Location: Anchor<CGRect>]
    let onCaptured: () -> Void
    let onFinish: () -> Void
    @State private var origins: [String: CGRect]?
    @State private var lifted = false
    @State private var arrived = false

    private static let stagger = 0.03
    private static let travel = Animation.spring(duration: 0.5, bounce: 0.2)

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                if let origins {
                    let items = flight.items.filter { origins[$0.id] != nil }
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        ghost(item, index: index, origin: origins[item.id] ?? .zero, in: geometry)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onAppear { capture(in: geometry) }
        }
        .onChange(of: flight.landing) { if flight.landing { land() } }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func ghost(_ item: GitFlightItem, index: Int, origin: CGRect, in geometry: GeometryProxy) -> some View {
        let target = arrived ? destination(for: item, origin: origin, in: geometry) : nil
        let frame = target?.frame ?? origin
        let fromFooter = flight.source == nil
        let scale: CGFloat = if let target { target.visible ? 1 : 0.6 } else if fromFooter { 0.6 } else if lifted { 1.03 } else { 1 }
        let opacity: Double = if let target { target.visible ? 1 : 0 } else if fromFooter { 0 } else { 1 }
        let delay = Double(min(index, 12)) * Self.stagger

        return GitFlightGhost(label: item.label, elevated: lifted || fromFooter)
            .frame(width: frame.width, height: frame.height)
            .scaleEffect(scale)
            .opacity(opacity)
            .position(x: frame.midX, y: frame.midY)
            .animation(.spring(duration: 0.18), value: lifted)
            .animation(Self.travel.delay(delay), value: arrived)
    }

    // MARK: - Geometry

    private func capture(in geometry: GeometryProxy) {
        var frames: [String: CGRect] = [:]
        for item in flight.items {
            if let source = flight.source {
                guard let anchor = anchors[.row(source, item.id)] else { continue }
                let row = geometry[anchor]
                if pane(source, in: geometry).map({ $0.minY...$0.maxY ~= row.midY }) ?? true { frames[item.id] = row }
            } else if let anchor = anchors[.row(flight.destination ?? .staged, item.destinationPath)] {
                // Rows from the footer only animate when their landing spot is on screen.
                let row = geometry[anchor]
                guard pane(flight.destination ?? .staged, in: geometry).map({ $0.minY...$0.maxY ~= row.midY }) ?? true else { continue }
                frames[item.id] = footer(size: row.size, in: geometry)
            }
        }
        origins = frames
        if flight.source != nil { lifted = true }
        onCaptured()
        if flight.landing { land() }
    }

    private func land() {
        guard let origins, !arrived else { return }
        guard !origins.isEmpty else { onFinish(); return }
        // Let the lifted frame render before travelling so SwiftUI has a start value.
        DispatchQueue.main.async {
            arrived = true
            let duration = 0.5 + Double(min(origins.count - 1, 12)) * Self.stagger
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { onFinish() }
        }
    }

    private func destination(for item: GitFlightItem, origin: CGRect, in geometry: GeometryProxy) -> (frame: CGRect, visible: Bool) {
        guard let destination = flight.destination else {
            return (footer(size: origin.size, in: geometry), false)
        }
        let paneFrame = pane(destination, in: geometry)
        if let anchor = anchors[.row(destination, item.destinationPath)] {
            let row = geometry[anchor]
            guard let paneFrame else { return (row, true) }
            if paneFrame.minY...paneFrame.maxY ~= row.midY { return (row, true) }
            // Scrolled out of view: head for the nearest edge of the list and fade.
            let y = row.midY < paneFrame.minY ? paneFrame.minY + origin.height : paneFrame.maxY - origin.height / 2
            return (CGRect(x: origin.minX, y: y - origin.height / 2, width: origin.width, height: origin.height), false)
        }
        guard let paneFrame else { return (origin, false) }
        let y = paneFrame.minY + 30
        return (CGRect(x: origin.minX, y: y, width: origin.width, height: origin.height), false)
    }

    private func pane(_ pane: GitFlightPane, in geometry: GeometryProxy) -> CGRect? {
        anchors[.pane(staged: pane != .unstaged)].map { geometry[$0] }
    }

    /// The Amend checkbox sits just below the staged list's leading edge.
    private func footer(size: CGSize, in geometry: GeometryProxy) -> CGRect {
        let staged = pane(.staged, in: geometry) ?? CGRect(origin: .zero, size: geometry.size)
        return CGRect(x: staged.minX + 10, y: staged.maxY - size.height / 2, width: size.width, height: size.height)
    }
}

/// A copy of a file row that floats above the lists while it moves.
private struct GitFlightGhost: View {
    let label: GitFlightItem.Label
    let elevated: Bool

    var body: some View {
        Group {
            switch label {
            case .change(let file): GitWorkingFileRow(file: file)
            case .commit(let file): GitCommitFileRow(file: file)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.regularMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(ClaudeTheme.accent.opacity(0.35))
                }
                .shadow(color: .black.opacity(elevated ? 0.18 : 0), radius: elevated ? 6 : 0, y: elevated ? 3 : 0)
                .padding(.horizontal, -6)
                .padding(.vertical, -1)
        }
    }
}
