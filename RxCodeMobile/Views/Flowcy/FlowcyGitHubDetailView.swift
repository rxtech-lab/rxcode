import RxCodeCore
import RxCodeChatKit
import SwiftUI

/// Presentation of the GitHub metadata already included in project resources.
private struct GitHubResource {
    let value: JSONValue
    let isPullRequest: Bool

    func text(_ key: String) -> String? {
        guard let text = value[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }

    var title: String { text("title") ?? (isPullRequest ? "Pull Request" : "Issue") }
    var state: String { text("state") ?? "Unknown" }
    var number: String? {
        guard let value = value["number"], !value.isNull else { return nil }
        return value.stringValue ?? value.description
    }
    var repository: String? { text("repositoryFullName") }
    var color: Color {
        switch state.lowercased() {
        case "open": .green
        case "merged": .purple
        case "closed": isPullRequest ? .red : .purple
        default: .secondary
        }
    }
    var icon: String {
        if isPullRequest { return state.lowercased() == "merged" ? "arrow.triangle.merge" : "arrow.triangle.pull" }
        return state.lowercased() == "closed" ? "checkmark.circle" : "exclamationmark.circle"
    }
    var url: URL? {
        if let raw = text("htmlUrl"), let url = URL(string: raw),
           url.scheme == "https", url.host == "github.com" { return url }
        guard let repository, let number, Int(number) != nil else { return nil }
        let parts = repository.split(separator: "/")
        guard parts.count == 2, parts.allSatisfy({ part in
            part.allSatisfy { $0.isLetter || $0.isNumber || "-_.".contains($0) }
        }) else { return nil }
        return URL(string: "https://github.com/\(repository)/\(isPullRequest ? "pull" : "issues")/\(number)")
    }
    func date(_ key: String) -> Date? {
        guard let raw = text(key) else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }
}

struct FlowcyGitHubRow: View {
    let value: JSONValue
    let isPullRequest: Bool
    private var item: GitHubResource { .init(value: value, isPullRequest: isPullRequest) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.icon).font(.title3).foregroundStyle(item.color).padding(.top, 2)
            VStack(alignment: .leading, spacing: 7) {
                Text(item.title).font(.headline).lineLimit(3)
                Text([item.number.map { "#\($0)" }, item.state.capitalized, item.text("authorLogin")].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
                if let repository = item.repository {
                    Text(repository).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.vertical, 8)
    }
}

struct FlowcyGitHubDetailView: View {
    @Environment(\.openURL) private var openURL
    let value: JSONValue
    let isPullRequest: Bool
    private var item: GitHubResource { .init(value: value, isPullRequest: isPullRequest) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Label(item.state.capitalized, systemImage: item.icon)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(item.color)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(item.color.opacity(0.12), in: Capsule())
                        Spacer()
                        if let number = item.number {
                            Text("#\(number)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    Text(item.title).font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    if let author = item.text("authorLogin") {
                        Label(author, systemImage: "person.crop.circle").font(.subheadline).foregroundStyle(.secondary)
                    }
                }

                card {
                    if let repository = item.repository {
                        Label {
                            Text(repository).font(.subheadline.weight(.medium)).textSelection(.enabled)
                        } icon: { Image(systemName: "shippingbox").foregroundStyle(.secondary) }
                    }
                    if isPullRequest, item.text("headRef") != nil || item.text("baseRef") != nil {
                        Divider()
                        if let head = item.text("headRef") { branch("From", name: head) }
                        if let base = item.text("baseRef") { branch("Into", name: base) }
                    }
                    if let date = item.date("createdAt") { dateRow("Created", date: date) }
                    if let date = item.date("updatedAt") { dateRow("Updated", date: date) }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Description").font(.headline)
                    card {
                        if let body = item.text("body") {
                            MarkdownContentView(text: body)
                        } else {
                            Label("No description provided.", systemImage: "text.alignleft")
                                .font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 12)
                        }
                    }
                }
                if let labels = value["labels"]?.arrayValue?.compactMap(\.stringValue), !labels.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Labels").font(.headline)
                        ViewThatFits(in: .horizontal) {
                            labelList(labels)
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(labels, id: \.self) { label in labelPill(label) }
                            }
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(isPullRequest ? "Pull Request" : "Issue")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if let url = item.url {
                Button {
                    MobileHaptics.buttonTap()
                    openURL(url)
                } label: {
                    Label("Open on GitHub", systemImage: "arrow.up.right.square")
                        .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 20).padding(.vertical, 12)
                .background(.bar)
            }
        }
        .accessibilityIdentifier(isPullRequest ? "flowcy-pull-request-detail" : "flowcy-issue-detail")
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14, content: content)
            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }

    private func branch(_ title: LocalizedStringKey, name: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Label(name, systemImage: "arrow.triangle.branch")
                .font(.subheadline.monospaced()).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func dateRow(_ title: LocalizedStringKey, date: Date) -> some View {
        LabeledContent(title) {
            Text(date, format: .dateTime.month(.abbreviated).day().year())
        }.font(.subheadline)
    }

    private func labelList(_ labels: [String]) -> some View {
        HStack(spacing: 8) { ForEach(labels, id: \.self) { label in labelPill(label) } }
    }

    private func labelPill(_ label: String) -> some View {
        Text(label).font(.caption.weight(.medium))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}
