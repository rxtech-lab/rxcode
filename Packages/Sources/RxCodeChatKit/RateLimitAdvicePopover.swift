import SwiftUI
import RxCodeCore

/// Popover behind the status-line usage-limit warning: why the selected model
/// needs attention and what to switch to.
struct RateLimitAdvicePopover: View {
    let advice: RateLimitAdvice
    /// Switches the session to another provider (raw `AgentProvider` value).
    let onSwitchProvider: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: advice.severity == .warning ? "exclamationmark.triangle.fill" : "lightbulb")
                    .foregroundStyle(advice.severity == .warning ? ClaudeTheme.statusWarning : ClaudeTheme.accent)
                Group {
                    if advice.severity == .warning {
                        Text("Usage limit running low", bundle: .module)
                    } else {
                        Text("Usage limit tip", bundle: .module)
                    }
                }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ClaudeTheme.textPrimary)
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(advice.reasons, id: \.self) { reason in
                    Text(verbatim: reason)
                        .font(.system(size: 12))
                        .foregroundStyle(ClaudeTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !advice.suggestions.isEmpty {
                Divider()
                Text("Suggestions", bundle: .module)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(ClaudeTheme.textTertiary)
                    .textCase(.uppercase)
                ForEach(advice.suggestions) { suggestion in
                    suggestionRow(suggestion)
                }
            }
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
    }

    private func suggestionRow(_ suggestion: RateLimitAdvice.Suggestion) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: suggestion.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(ClaudeTheme.textPrimary)
                Text(verbatim: suggestion.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(ClaudeTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if case .switchProvider(let providerRaw) = suggestion.action {
                Button {
                    onSwitchProvider(providerRaw)
                } label: {
                    Text("Switch", bundle: .module)
                }
                .controlSize(.small)
            }
        }
    }
}
