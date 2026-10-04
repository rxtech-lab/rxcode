import Foundation

public extension TaskBoard {
    /// The views a project shows as tabs: its saved views, or the implicit
    /// default board when none have been created.
    var effectiveViews: [TaskSavedView] {
        savedViews.isEmpty ? [TaskSavedView.defaultView] : savedViews
    }

    /// The view-tab order after dropping `view` onto `target`'s tab: the
    /// dragged tab takes the target's slot, like `columnOrder(moving:to:)`.
    /// `nil` when the drop is a no-op or either id isn't a tab.
    func viewOrder(moving view: UUID, to target: UUID) -> [TaskSavedView]? {
        var order = effectiveViews
        guard view != target,
              let from = order.firstIndex(where: { $0.id == view }),
              let to = order.firstIndex(where: { $0.id == target })
        else { return nil }
        let moved = order.remove(at: from)
        order.insert(moved, at: to)
        return order
    }

    /// The view a project opens on and its dashboard card previews: the one
    /// marked default, else the first tab.
    var defaultView: TaskSavedView {
        let views = effectiveViews
        return views.first(where: \.isDefault) ?? views.first ?? .defaultView
    }

    /// Saves `view` as a tab. The implicit default tab exists only while no
    /// view is saved, so it is persisted before the first custom view to keep
    /// it from vanishing. A view saved as the default takes the mark from
    /// every other view.
    mutating func upsertSavedView(_ view: TaskSavedView) {
        if savedViews.isEmpty, view.id != TaskSavedView.defaultViewId {
            savedViews.append(.defaultView)
        }
        if view.isDefault {
            for idx in savedViews.indices { savedViews[idx].isDefault = false }
        }
        if let idx = savedViews.firstIndex(where: { $0.id == view.id }) {
            savedViews[idx] = view
        } else {
            savedViews.append(view)
        }
    }

    /// Marks `viewId` as the board's default view.
    mutating func setDefaultView(_ viewId: UUID) {
        guard var view = effectiveViews.first(where: { $0.id == viewId }) else { return }
        view.isDefault = true
        upsertSavedView(view)
    }

    /// Tasks `view`'s structured filters keep. A Swift filter script is not
    /// applied: it runs asynchronously, only on the project page.
    func tasks(matching view: TaskSavedView) -> [ProjectTask] {
        tasks.filter(view.matches)
    }

    /// Stories `view`'s structured filters keep, matched on their rolled-up
    /// status as on the board's story panel.
    func stories(matching view: TaskSavedView) -> [ProjectStory] {
        guard !view.isEmpty else { return stories }
        let rollups = storyRollups()
        return stories.filter { story in
            view.matches(story, rolledUpStatus: rollups[story.id]?.status ?? rolledUpStatus(for: story))
        }
    }
}
