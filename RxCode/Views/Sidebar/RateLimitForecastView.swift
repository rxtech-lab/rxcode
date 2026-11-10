import SwiftUI
import RxCodeCore

/// A dedicated read-only forecast surface shared by briefing and usage cards.
struct RateLimitForecastView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Form {
            ForEach(AppState.rateLimitedProviders.filter { $0 != .codex || appState.codexInstalled }, id: \.self) { provider in
                let forecast = appState.rateLimitProviderStats[provider]?.weeklyForecast ?? RateLimitWeeklyForecast()
                Section(provider.displayNameText) {
                    LabeledContent("7-day allowance", value: Self.status(forecast))
                    if forecast.outcome != .insufficientData, forecast.observedDays > 0 {
                        LabeledContent("Average daily tokens", value: forecast.dailyTokens.formatted(.number.notation(.compactName).precision(.fractionLength(0...1))))
                        LabeledContent("Average daily session time", value: Duration.seconds(forecast.dailySessionSeconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)))
                        LabeledContent("Average daily limit use", value: (forecast.dailyPercent / 100).formatted(.percent.precision(.fractionLength(1))))
                        Text("Based on \(forecast.observedDays) completed calendar days, including idle days.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let reset = appState.cachedRateLimitUsage(for: provider)?.sevenDayResetsAt {
                        LabeledContent("Resets", value: reset.formatted(date: .abbreviated, time: .shortened))
                    }
                }
            }
            Section {
                Text("Estimates use recent daily activity and measured limit costs for each model. Cache reads are excluded. Session time is used when token measurements are unavailable. Work outside RxCode and provider accounting changes can affect the result.")
                    .foregroundStyle(.secondary)
                Text("A forecast needs two completed days of activity and at least three isolated cost measurements for each active model. Partial days and overlapping task costs are excluded.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    static func status(_ forecast: RateLimitWeeklyForecast) -> String {
        switch forecast.outcome {
        case .insufficientData: String(localized: "Not enough daily activity yet")
        case .exhausted: String(localized: "Allowance used up")
        case .lastsUntilReset: String(localized: "Expected to last until reset")
        case .depletes(let date): String(localized: "May run out \(date.formatted(date: .abbreviated, time: .shortened))")
        }
    }
}

struct RateLimitForecastSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            RateLimitForecastView()
                .navigationTitle("7-day usage forecast")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 620, height: 600)
    }
}
