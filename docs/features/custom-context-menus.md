---
slug: features/custom-context-menus
title: Custom Context Menus
description: Define your own right-click menu items in RxCode — call an API or spawn a thread, scoped to projects and gated by Swift show-conditions, on desktop and mobile.
---

# Custom Context Menus

Custom context menus let you add your own items to RxCode's right-click menus.
Each item runs an action — an HTTP request, or seeding a new / existing chat
thread — and can be scoped to specific projects, attached to one or more menu
surfaces, and gated by a Swift "show condition" that decides whether the item
appears.

Items are configured on the Mac (the single source of truth) and persisted with
SwiftData. The desktop renders them natively; **mobile fetches the same items
over the relay and renders them identically**, so there is no separate mobile
setup.

## Where to configure them

Open the editor from either:

- **Top menu bar → Automation → Custom Context Menus**, or
- **Settings → General → Custom Context Menus** section.

From there you can add, edit, reorder, enable/disable, and remove items. Each
row shows the item's title, the surfaces it attaches to, and whether it has a
Swift show-condition.

## Surfaces

A surface is *where* the item appears. An item can attach to any combination of
the three:

| Surface | Where it shows |
|---------|----------------|
| **Project** | The project row's context menu in the sidebar (right-click a project, or its `…` menu). |
| **Thread** | A chat thread's context menu in the sidebar. |
| **Briefing** | A branch-scoped briefing card's context menu. |

Surfaces are stored comma-separated (e.g. `project,thread`), so an item can live
on several menus at once.

## Scope

- **All projects** — leave the project unset; the item appears in every project.
- **One project** — scope the item to a single project, and it only appears
  there.

## Actions

Each item performs exactly one action when tapped:

| Action | What it does |
|--------|--------------|
| **Call API** | Sends an HTTP request. Configure the method, URL, headers (a name→value map), and an optional request body. A non-2xx response surfaces as an error. |
| **Create Thread** | Spawns a new chat thread in the project, seeded with your message template. The spawned thread is a utility run — it does **not** trigger lifecycle hooks such as code review or auto-continue. |
| **Continue Thread** | Adds your message to an existing thread (by target thread id). |

## Placeholders

URLs, headers, request bodies, and message templates can use placeholders that
are substituted at menu-build time with the current context:

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
Swift script that returns whether it should appear. This is evaluated on the
desktop at menu-build time (and warmed ahead of time for mobile so the phone's
first fetch is already accurate).

Write a single async function:

```swift
func checkShowMenu(context: Context) async throws -> Bool {
    // Return true to show the menu item, false to hide it.
    let status = try await context.git("status", "--porcelain")
    return !status.isEmpty   // only show when there are uncommitted changes
}
```

The `context` parameter exposes the current project and two helpers that run
inside the project directory:

| Member | Description |
|--------|-------------|
| `projectName`, `projectPath`, `gitHubRepo`, `branch`, `sessionId` | Same values as the placeholders above. |
| `shell(_ command: String) async throws -> String` | Runs a shell command in the project directory and returns its trimmed stdout. Started with no startup files; `PATH` is injected so your tools still resolve; stderr is discarded. |
| `git(_ args: String...) async throws -> String` | Convenience wrapper that runs `git` with the given arguments in the project directory. |

### How conditions are compiled and run

The script is wrapped in a generated harness that defines `Context`, compiled
with `xcrun swiftc`, and the resulting binary is cached by a SHA-256 of its
source — so a given script compiles only once. Evaluation then just runs the
cached binary with the context passed through the environment.

The editor refuses to save a script-gated item until it compiles, and offers an
**AI generate** helper that writes a `checkShowMenu` function from a
natural-language requirement, plus an inline **Compile** button that surfaces
compiler diagnostics.

> **Fail-open by design.** Every failure mode — no toolchain, compile error,
> runtime crash, a 3-second timeout, or any non-`true` output — resolves to
> **show** the item. A broken condition never silently hides a menu entry you
> configured.

Because synchronous menu building can't wait on a subprocess, a script result
that isn't cached yet shows the item *and* schedules a background evaluation;
the next time the menu opens it reflects the real result.

## Desktop ↔ mobile

You configure items once on the Mac. The desktop's `CustomMenuHook` turns each
enabled record into a serializable menu item for the matching surface, and the
mobile app fetches the same items over the relay and renders them identically.
When an item is tapped — on either side — the action is dispatched on the Mac
through a single shared entry point, so the work runs the same way regardless of
which device initiated it.
