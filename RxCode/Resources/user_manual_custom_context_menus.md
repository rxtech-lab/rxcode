# Custom Context Menus

Custom context menus let you add your own items to RxCode's right-click menus.
Each item runs an action — an HTTP request, or seeding a new / existing chat
thread — and can be scoped to specific projects, attached to one or more menu
surfaces, and gated by a Swift "show condition" that decides whether it appears.

You configure items on the Mac (the single source of truth). The desktop renders
them natively, and the mobile app fetches the same items over the relay and
renders them identically — so there's no separate mobile setup.

## Where to configure them

Open the editor from either:

- **Automation menu → Custom Context Menus** (top menu bar), or
- **Settings → General → Custom Context Menus**.

From there you can add, edit, reorder, enable/disable, and remove items. Each row
shows the item's title, the surfaces it attaches to, and whether it has a Swift
show-condition.

## Surfaces

A surface is *where* the item appears. An item can attach to any combination of
the three:

| Surface | Where it shows |
|---------|----------------|
| **Project** | The project row's context menu in the sidebar (right-click a project, or its `…` menu). |
| **Thread** | A chat thread's context menu in the sidebar. |
| **Briefing** | A branch-scoped briefing card's context menu. |

## Scope

- **All projects** — leave the project unset; the item appears in every project.
- **One project** — scope the item to a single project, and it appears only there.

## Actions

Each item performs exactly one action when tapped:

| Action | What it does |
|--------|--------------|
| **Call API** | Sends an HTTP request. Configure the method, URL, headers, and an optional body. A non-2xx response surfaces as an error. |
| **Create Thread** | Spawns a new chat thread in the project, seeded with your message template. The spawned thread is a utility run — it does **not** trigger lifecycle hooks such as code review or auto-continue. |
| **Continue Thread** | Adds your message to an existing thread (by target thread id). |

## Placeholders

URLs, headers, request bodies, and message templates can use placeholders that
are substituted with the current context when the menu is built:

| Placeholder | Value |
|-------------|-------|
| `{{projectName}}` | The project's display name |
| `{{projectPath}}` | Absolute path to the project on disk |
| `{{gitHubRepo}}` | The project's `owner/repo` (empty if none) |
| `{{branch}}` | The current branch (on briefing-card menus, the card's branch) |
| `{{sessionId}}` | The thread id (on thread menus) |

Example URL:

```
https://api.example.com/projects/{{projectName}}/build?branch={{branch}}
```

## Show conditions

By default every item is **always shown**. You can instead gate an item on a
Swift script that returns whether it should appear. It runs on the desktop when
the menu is built (and is warmed ahead of time for mobile).

Write a single async function:

```swift
func checkShowMenu(context: Context) async throws -> Bool {
    // Return true to show the menu item, false to hide it.
    let status = try await context.git("status", "--porcelain")
    return !status.isEmpty   // only show when there are uncommitted changes
}
```

`context` exposes the current project plus two helpers that run inside the
project directory:

| Member | Description |
|--------|-------------|
| `projectName`, `projectPath`, `gitHubRepo`, `branch`, `sessionId` | Same values as the placeholders above. |
| `shell(_:)` | Runs a shell command in the project directory and returns its trimmed stdout. |
| `git(_:)` | Convenience wrapper that runs `git` with the given arguments in the project directory. |

The editor refuses to save a script-gated item until it compiles, offers an
**AI generate** helper that writes the function from a plain-language
requirement, and an inline **Compile** button that surfaces diagnostics.

> **Fail-open by design.** Every failure mode — no toolchain, compile error,
> runtime crash, a timeout, or any non-`true` output — resolves to **show** the
> item. A broken condition never silently hides a menu entry you configured.
