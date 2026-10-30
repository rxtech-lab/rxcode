import AppKit
import RxCodeCore
import SwiftUI

/// Rating entry point shown at the end of the transcript, next to where a
/// message's copy button sits. The icon reflects the saved rating.
struct CodingSessionRatingButton: View {
    @Environment(WindowState.self) private var windowState
    @State private var showRating = false
    @State private var rating: CodingSessionRating?

    var body: some View {
        if CodingAnalyticsRecorder.shared.enabled, let id = windowState.currentSessionId {
            Button { showRating = true } label: {
                Image(systemName: rating?.symbolName(filled: true) ?? "hand.thumbsup")
                    .font(.system(size: ClaudeTheme.messageSize(11), weight: .medium))
                    .foregroundStyle(rating?.tint ?? ClaudeTheme.textSecondary)
                    .frame(width: 26, height: 26)
                    .background(ClaudeTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(ClaudeTheme.border, lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)
            .help(rating.map { String(localized: "Rated \($0.title) — change rating") } ?? String(localized: "Rate this coding session"))
            .accessibilityLabel("Rate Session")
            .task(id: id) { await loadRating(id) }
            .sheet(isPresented: $showRating, onDismiss: { Task { await loadRating(id) } }) {
                CodingSessionRatingSheet(threadID: id)
            }
        }
    }

    private func loadRating(_ id: String) async {
        rating = (try? await CodingAnalyticsRecorder.shared.session(id))?.rating
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
                if loading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let session {
                    content(session)
                } else {
                    ContentUnavailableView("No Recorded Session", systemImage: "chart.bar.doc.horizontal",
                                           description: Text("Send a prompt with coding analytics enabled to record and rate this session."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .disabled(saving)
            .navigationTitle("Rate Session")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.disabled(saving)
                }
            }
            .overlay { statusOverlay }
        }
        .frame(width: 500, height: 440)
        .task {
            defer { loading = false }
            do { session = try await CodingAnalyticsRecorder.shared.session(threadID) }
            catch { self.error = error.localizedDescription }
        }
        .task(id: status) {
            guard status != nil else { return }
            try? await Task.sleep(for: .seconds(1.2))
            withAnimation { status = nil }
        }
        .alert("Unable to Save Rating", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func content(_ session: CodingAnalyticsSession) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("How did this session go?")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(ClaudeTheme.textPrimary)
                    Text("Ratings stay on this Mac and are included when you export coding analytics.")
                        .font(.callout)
                        .foregroundStyle(ClaudeTheme.textSecondary)
                }

                HStack(spacing: 12) {
                    ForEach(CodingSessionRating.allCases, id: \.self) { rating in
                        RatingOptionCard(rating: rating, isSelected: session.rating == rating) {
                            save(session.rating == rating ? nil : rating)
                        }
                    }
                }

                summary(session)

                if session.rating != nil {
                    Button(role: .destructive) { save(nil) } label: {
                        Label("Clear Rating", systemImage: "xmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(ClaudeTheme.statusError)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func summary(_ session: CodingAnalyticsSession) -> some View {
        let models = session.models.map { $0.model ?? $0.provider }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
            summaryRow("Turns", value: "\(session.turns.count)")
            summaryRow("Active time", value: Duration.seconds(session.activeSeconds)
                .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated)))
            if let tokens = session.totalReportedTokens {
                summaryRow("Tokens", value: tokens.formatted(.number.notation(.compactName)))
            }
            if !models.isEmpty {
                summaryRow("Models", value: models.joined(separator: ", "))
            }
        }
        .font(.callout)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ClaudeTheme.surfacePrimary, in: RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall))
        .overlay(
            RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
                .strokeBorder(ClaudeTheme.border, lineWidth: 0.5)
        )
    }

    private func summaryRow(_ title: LocalizedStringKey, value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(ClaudeTheme.textSecondary)
            Text(value)
                .foregroundStyle(ClaudeTheme.textPrimary)
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var statusOverlay: some View {
        if saving {
            ProgressView("Saving rating…")
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        } else if let status {
            Label(status, systemImage: "checkmark.circle.fill")
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    private func save(_ rating: CodingSessionRating?) {
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        saving = true
        status = nil
        Task {
            defer { saving = false }
            do {
                try await CodingAnalyticsRecorder.shared.rate(threadID, rating: rating)
                session = try await CodingAnalyticsRecorder.shared.session(threadID)
                status = rating == nil ? String(localized: "Rating cleared") : String(localized: "Rating saved")
            } catch { self.error = error.localizedDescription }
        }
    }
}

private struct RatingOptionCard: View {
    let rating: CodingSessionRating
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: rating.symbolName(filled: isSelected))
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(isSelected ? rating.tint : ClaudeTheme.textSecondary)
                    .frame(height: 30)
                Text(rating.title)
                    .font(.callout.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(ClaudeTheme.textPrimary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(
                RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusMedium)
                    .fill(isSelected ? rating.tint.opacity(0.14) : (isHovering ? ClaudeTheme.surfaceSecondary : ClaudeTheme.surfacePrimary))
            )
            .overlay(
                RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusMedium)
                    .strokeBorder(isSelected ? rating.tint : ClaudeTheme.border, lineWidth: isSelected ? 1.5 : 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusMedium))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isSelected)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help(isSelected ? String(localized: "Click again to clear") : String(localized: "Rate as \(rating.title)"))
    }
}

private extension CodingSessionRating {
    var title: String {
        switch self {
        case .good: String(localized: "Good")
        case .neutral: String(localized: "Neutral")
        case .bad: String(localized: "Bad")
        }
    }

    func symbolName(filled: Bool) -> String {
        let base = switch self {
        case .good: "hand.thumbsup"
        case .neutral: "hand.raised"
        case .bad: "hand.thumbsdown"
        }
        return filled ? base + ".fill" : base
    }

    var tint: Color {
        switch self {
        case .good: ClaudeTheme.statusSuccess
        case .neutral: ClaudeTheme.statusWarning
        case .bad: ClaudeTheme.statusError
        }
    }
}
