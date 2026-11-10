# Task views MCP tool

`ide__task_views` manages project task-view tabs for Claude Code, Codex, and ACP agents. It uses the current saved chat's project unless `project_id` is supplied, and persists through the same local, mobile, and cloud sync path as the view editor.

Call `list` first. The response includes `project_id`, `default_view_id`, available `columns` (IDs and names), and all `views` in tab order, including hidden views and the implicit Board tab. View objects use the saved model's camelCase fields; tool arguments use snake_case.

| Operation | Required fields | Behavior |
| --- | --- | --- |
| `list` | `operation` | Read views without saving changes. |
| `create` | `operation`, `name` | Add a view and return all views. |
| `update` | `operation`, `view_id` | Change supplied fields and preserve omitted settings. |
| `delete` | `operation`, `view_id` | Remove a view while keeping its tasks. The last view cannot be deleted. |
| `reorder` | `operation`, `view_ids` | Supply every view ID exactly once, in the desired order, including hidden tabs. |

Create and update accept `name`, `layout` (`board` or `table`), `tags`, `versions`, `milestones`, `story_ids`, `statuses`, `story_panel_statuses`, `is_default`, `is_hidden`, `filter_script`, and `column_sorts`. Empty arrays clear filters. Story IDs must belong to the project board; use `ide__get_stories` to discover them. Status and column-sort keys must be existing column IDs.

Setting `is_default: true` removes the default mark from other views. If no view is marked default, the first tab is used. Setting `is_hidden` keeps a view's filters and position. `column_sorts` replaces the saved sort dictionary; each column maps to `{ "field": "priority", "descending": false }`. Fields are `manual`, `priority`, `title`, `createdAt`, `updatedAt`, `version`, and `milestone`. Device-local column filters are unaffected.

`filter_script` uses the existing Swift filter runner; `null` clears the script and its cached snapshot. Invalid requests fail before any board change is persisted.

```json
{
  "operation": "create",
  "name": "v2 MCP work",
  "layout": "table",
  "tags": ["mcp"],
  "versions": ["v2.0.0"],
  "is_default": true
}
```
