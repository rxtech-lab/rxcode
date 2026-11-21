import RxCodeCore
import SwiftUI

// MARK: - Add Git Source

struct AddSkillGitSourceSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var gitURL = ""
    @State private var ref = ""
    @State private var isAdding = false
    @State private var localError: String?

    private var canAdd: Bool {
        !gitURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isAdding
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Add Git Skill Source")
                        .font(.system(size: ClaudeTheme.size(16), weight: .semibold))
                    Text("Use a GitHub repository that exposes .claude-plugin/marketplace.json.")
                        .font(.system(size: ClaudeTheme.size(12)))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: ClaudeTheme.size(12), weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            ClaudeThemeDivider()

            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("GitHub Repository")
                        .font(.system(size: ClaudeTheme.size(12), weight: .medium))
                    TextField("https://github.com/owner/repo", text: $gitURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: ClaudeTheme.size(13)))
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("Branch or Ref")
                        .font(.system(size: ClaudeTheme.size(12), weight: .medium))
                    TextField("main", text: $ref)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: ClaudeTheme.size(13)))
                }

                if let error = localError ?? appState.marketplaceSourceError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: ClaudeTheme.size(12)))
                        .foregroundStyle(ClaudeTheme.statusError)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Button("Cancel") {
                        dismiss()
                    }

                    Spacer()

                    Button {
                        Task { await addSource() }
                    } label: {
                        if isAdding {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Add Source")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canAdd)
                }
            }
            .padding(20)

            ClaudeThemeDivider()

            VStack(alignment: .leading, spacing: 10) {
                Text("Custom Sources")
                    .font(.system(size: ClaudeTheme.size(13), weight: .semibold))

                if appState.marketplaceCustomSources.isEmpty {
                    Text("No custom Git sources added.")
                        .font(.system(size: ClaudeTheme.size(12)))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(appState.marketplaceCustomSources) { source in
                                HStack(spacing: 10) {
                                    Image(systemName: "point.3.connected.trianglepath.dotted")
                                        .font(.system(size: ClaudeTheme.size(12)))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 16)

                                    Text(source.displayName)
                                        .font(.system(size: ClaudeTheme.size(12), weight: .medium))
                                        .lineLimit(1)
                                        .textSelection(.enabled)

                                    Spacer()

                                    Button(role: .destructive) {
                                        Task { await appState.removeMarketplaceGitSource(source) }
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                    .buttonStyle(.borderless)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                }
            }
            .padding(20)
            // Fill the remaining vertical space so the list scrolls internally
            // instead of pushing the pinned header off the top of the sheet.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 520, height: 560)
    }

    private func addSource() async {
        isAdding = true
        localError = nil
        let ok = await appState.addMarketplaceGitSource(
            url: gitURL,
            ref: ref.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : ref
        )
        isAdding = false
        if ok {
            gitURL = ""
            ref = ""
        } else {
            localError = appState.marketplaceSourceError
        }
    }
}
