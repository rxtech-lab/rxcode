#if os(macOS)
import ExtensionKit
import Foundation
import SwiftUI

/// Builds a detail scene whose broker client and card selection belong to this scene instance.
@MainActor public func extensionUsageDetailScene<Report: Sendable, Content: View>(
    load: @escaping @Sendable (RxCodeHost) async throws -> Report,
    @ViewBuilder content: @escaping (Report, String?) -> Content
) -> PrimitiveAppExtensionScene {
    let state = DetailConnection()
    return PrimitiveAppExtensionScene(id: "usage-detail") {
        ConnectedDetail(state: state, load: load, content: content)
    } onConnection: { connection in
        ExtensionSceneConnection.accept(connection) { context, host in
            Task { @MainActor in state.update(context, host: host) }
        }
    }
}

@MainActor @Observable
private final class DetailConnection {
    struct CardSelection: Decodable {
        let metricID: String?
        let metricIDs: [String]?
    }
    var host: RxCodeHost?
    var metricID: String?
    var revision = 0

    func update(_ context: ExtensionSceneContext, host: RxCodeHost) {
        let card = context.configuration.flatMap { try? JSONDecoder().decode(CardSelection.self, from: $0) }
        metricID = (card?.metricIDs ?? card?.metricID.map { [$0] } ?? []).first
        self.host = host
        revision += 1
    }
}

private struct ConnectedDetail<Report: Sendable, Content: View>: View {
    let state: DetailConnection
    let load: @Sendable (RxCodeHost) async throws -> Report
    let content: (Report, String?) -> Content
    @State private var report: Report?
    @State private var failed = false

    var body: some View {
        Group {
            if let report {
                content(report, state.metricID)
            } else if failed {
                ContentUnavailableView(sdkText("Usage unavailable"), systemImage: "chart.bar")
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: state.revision) {
            report = nil
            failed = false
            guard let host = state.host else { return }
            do {
                let result = try await load(host)
                try Task.checkCancellation()
                report = result
            } catch {
                if !Task.isCancelled { failed = true }
            }
        }
    }
}
#endif
