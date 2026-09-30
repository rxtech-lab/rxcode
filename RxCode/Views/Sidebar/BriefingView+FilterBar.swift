import SwiftUI
import Foundation
import RxCodeCore

// MARK: - Filter bar

extension BriefingView {
    var filterBar: some View {
        let projects = projectsWithData
        return HStack(spacing: 8) {
            kindFilterChip
            projectFilterMenu(projects: projects)
            Spacer(minLength: 0)
        }
    }

    var kindFilterChip: some View {
        Menu {
            ForEach(KindFilter.allCases, id: \.self) { kind in
                Button {
                    kindFilter = kind
                } label: {
                    menuSelectionLabel(kind.title, isSelected: kindFilter == kind)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: kindFilter.icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(kindFilter.title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(kindFilter == .all ? ClaudeTheme.textSecondary : ClaudeTheme.textOnAccent)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(kindFilter == .all ? ClaudeTheme.surfaceSecondary : ClaudeTheme.accent)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(
                        kindFilter == .all
                            ? ClaudeTheme.border.opacity(0.6)
                            : ClaudeTheme.accent.opacity(0.4),
                        lineWidth: 0.5
                    )
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Choose which kinds of briefing to show.")
    }

    @ViewBuilder
    func projectFilterMenu(projects: [Project]) -> some View {
        if projects.count > 1 || !selectedProjectIds.isEmpty {
            Menu {
                    Button {
                        selectedProjectIds.removeAll()
                    } label: {
                        menuSelectionLabel("All projects", isSelected: selectedProjectIds.isEmpty)
                    }
                    Divider()
                    ForEach(projects) { project in
                        Button {
                            toggleProject(project.id)
                        } label: {
                            menuSelectionLabel(project.name, isSelected: selectedProjectIds.contains(project.id))
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .font(.system(size: 11, weight: .semibold))
                        Text(filterMenuLabel(projects: projects))
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(selectedProjectIds.isEmpty ? ClaudeTheme.textSecondary : ClaudeTheme.textOnAccent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule(style: .continuous)
                            .fill(selectedProjectIds.isEmpty ? ClaudeTheme.surfaceSecondary : ClaudeTheme.accent)
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(
                                selectedProjectIds.isEmpty
                                    ? ClaudeTheme.border.opacity(0.6)
                                    : ClaudeTheme.accent.opacity(0.4),
                                lineWidth: 0.5
                            )
                    )
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
        }
    }

    @ViewBuilder
    func menuSelectionLabel(_ title: String, isSelected: Bool) -> some View {
        if isSelected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    @ViewBuilder
    func menuSelectionLabel(_ title: LocalizedStringKey, isSelected: Bool) -> some View {
        if isSelected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    func filterMenuLabel(projects: [Project]) -> String {
        if selectedProjectIds.isEmpty {
            return String(localized: "All projects")
        }
        if selectedProjectIds.count == 1, let id = selectedProjectIds.first {
            return projectsById[id]?.name ?? String(localized: "1 project")
        }
        return String(localized: "\(selectedProjectIds.count) projects")
    }

    func toggleProject(_ id: UUID) {
        if selectedProjectIds.contains(id) {
            selectedProjectIds.remove(id)
        } else {
            selectedProjectIds.insert(id)
        }
    }
}
