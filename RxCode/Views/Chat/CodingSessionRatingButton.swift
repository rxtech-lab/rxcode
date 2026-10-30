import RxCodeCore
import SwiftUI

struct CodingSessionRatingButton: View {
    @Environment(WindowState.self) private var windowState
    @State private var showRating = false

    var body: some View {
        if CodingAnalyticsRecorder.shared.enabled, let id = windowState.currentSessionId {
            Button { showRating = true } label: { Label("Rate Session", systemImage: "hand.thumbsup") }
                .labelStyle(.iconOnly)
                .help("Rate this coding session")
                .sheet(isPresented: $showRating) { CodingSessionRatingSheet(threadID: id) }
        }
    }
}

private struct CodingSessionRatingSheet: View {
    let threadID: String
    @Environment(\.dismiss) private var dismiss
    @State private var session: CodingAnalyticsSession?
    @State private var loading = true
    @State private var saving = false
    @State private var status: String?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if loading { ProgressView() }
                else if let session {
                    Form {
                        Section("How was this session?") {
                            ForEach(CodingSessionRating.allCases, id: \.self) { rating in
                                Button {
                                    save(rating)
                                } label: {
                                    HStack {
                                        Text(rating.rawValue.capitalized)
                                        Spacer()
                                        if session.rating == rating { Image(systemName: "checkmark") }
                                    }
                                }
                            }
                            if session.rating != nil { Button("Clear Rating") { save(nil) } }
                        }
                    }
                    .formStyle(.grouped)
                } else {
                    ContentUnavailableView("No Recorded Session", systemImage: "chart.bar.doc.horizontal",
                                           description: Text("Send a prompt with coding analytics enabled to record and rate this session."))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .disabled(saving)
            .navigationTitle("Rate Session")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() }.disabled(saving) } }
            .overlay {
                if saving { ProgressView("Saving rating…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) }
                else if let status { Text(status).padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)).allowsHitTesting(false) }
            }
        }
        .frame(width: 440, height: 360)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            defer { loading = false }
            do { session = try await CodingAnalyticsRecorder.shared.session(threadID) }
            catch { self.error = error.localizedDescription }
        }
        .alert("Unable to Save Rating", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func save(_ rating: CodingSessionRating?) {
        saving = true
        status = nil
        Task {
            defer { saving = false }
            do {
                try await CodingAnalyticsRecorder.shared.rate(threadID, rating: rating)
                session = try await CodingAnalyticsRecorder.shared.session(threadID)
                status = rating == nil ? "Rating cleared." : "Rating saved."
            } catch { self.error = error.localizedDescription }
        }
    }
}
