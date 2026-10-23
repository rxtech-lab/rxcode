import RxCodeCore
import RxCodeChatKit
import SwiftUI

/// Paginated account resources. Details use the shared Markdown renderer.
struct FlowcyResourceView: View {
    let title: String
    let path: String
    var repositoryFullName: String? = nil
    @State private var rows: [JSONValue] = []
    @State private var nextCursor: String?
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        Group {
            if rows.isEmpty {
                if loading { ProgressView("Loading…") }
                else if let error {
                    ContentUnavailableView {
                        Label("Unable to Load \(title)", systemImage: "exclamationmark.triangle")
                    } description: { Text(error) } actions: { Button("Retry") { Task { await load(reset: true) } } }
                } else {
                    ContentUnavailableView {
                        Label("No \(title)", systemImage: "tray")
                    } description: {
                        Text(nextCursor == nil ? "No items for this project." : "No matching items on this page.")
                    } actions: {
                        if nextCursor != nil {
                            Button("Load More") { Task { await load(reset: false) } }
                        }
                    }
                }
            } else {
                List {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, value in
                        NavigationLink {
                            if path.hasPrefix("sessions"), let id = value["id"]?.stringValue {
                                FlowcySessionDetailView(id: id)
                            } else if path == "issues" || path == "pull-requests" {
                                FlowcyGitHubDetailView(value: value, isPullRequest: path == "pull-requests")
                            } else {
                                ScrollView { MarkdownContentView(text: Self.markdown(value)).padding() }
                                    .navigationTitle(Self.label(value))
                            }
                        } label: {
                            if path == "issues" || path == "pull-requests" {
                                FlowcyGitHubRow(value: value, isPullRequest: path == "pull-requests")
                            } else {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(Self.label(value))
                                    if let subtitle = value["status"]?.stringValue ?? value["state"]?.stringValue {
                                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    if let error {
                        Text(error).foregroundStyle(.red)
                        Button("Retry") { Task { await load(reset: false) } }
                    }
                    if nextCursor != nil {
                        Button("Load More") { Task { await load(reset: false) } }.disabled(loading)
                    }
                }
                .refreshable { await load(reset: true) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(title)
        .task { await load(reset: true) }
    }

    private func load(reset: Bool) async {
        guard !Task.isCancelled, !loading else { return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            var cursor = reset ? nil : nextCursor
            var visited = Set<String>()
            var collected: [JSONValue] = []
            repeat {
                if let cursor, !visited.insert(cursor).inserted {
                    throw FlowcyError.message("Could not finish loading this project's items. Please try again.")
                }
                var target = path
                if let cursor {
                    let encoded = cursor.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
                    target += (path.contains("?") ? "&" : "?") + "cursor=" + encoded
                }
                let result = try await FlowcyAPI().read(target)
                try Task.checkCancellation()
                let page = result.arrayValue ?? result["items"]?.arrayValue ?? result["sessions"]?.arrayValue ?? (result.isNull ? [] : [result])
                let matching = page.filter { value in
                    guard let repositoryFullName else { return true }
                    let repository = value["repositoryFullName"]?.stringValue
                        ?? value["repository"]?["fullName"]?.stringValue
                        ?? value["repository"]?["full_name"]?.stringValue
                    return repository?.caseInsensitiveCompare(repositoryFullName) == .orderedSame
                }
                collected += matching
                cursor = result["pagination"]?["nextCursor"]?.stringValue ?? result["nextCursor"]?.stringValue
                // Account-wide pages may contain only other projects. Keep searching
                // before displaying an empty state for the selected project.
            } while repositoryFullName != nil && collected.isEmpty && cursor != nil
            rows = reset ? collected : rows + collected
            nextCursor = cursor
        } catch is CancellationError { }
        catch let error as URLError where error.code == .cancelled { }
        catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    private static func label(_ value: JSONValue) -> String {
        for key in ["title", "name", "workflowName", "repositoryFullName", "id"] {
            if let text = value[key]?.stringValue, !text.isEmpty { return text }
        }
        return "Details"
    }

    private static func markdown(_ value: JSONValue) -> String {
        if let text = value["body"]?.stringValue ?? value["content"]?.stringValue { return text }
        guard let fields = value.objectValue else { return value.stringValue ?? "" }
        let displayFields = ["title", "name", "status", "state", "conclusion", "repositoryFullName", "fullName", "description", "createdAt", "updatedAt", "tier", "currentPeriodEnd", "active", "url"]
        return displayFields.compactMap { key in
            guard let item = fields[key], !item.isNull else { return nil }
            let label = key.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression).capitalized
            return "**\(label)**: \(item.stringValue ?? item.description)"
        }.joined(separator: "\n\n")
    }
}
