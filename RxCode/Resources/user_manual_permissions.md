# Permissions and Inspector

Permissions and the inspector help you keep control while agents work.

## Permission Requests

When an agent wants to edit files or run a command, RxCode can pause and show a permission request. You can allow the single action, allow similar actions for the current session, or deny it.

## Permission Modes

- **Ask**: request approval before edits and commands.
- **Accept Edits**: allow file edits in the workspace; commands still require approval.
- **Plan**: read-only planning mode.
- **Auto**: let the model approve safe operations and ask for risky ones.
- **Bypass**: skip permission checks. Use only in isolated, trusted environments.

## Inspector

Open the right inspector with **Command-4** or the toolbar button. The inspector includes review panes, terminal access, and project memo notes.

The terminal starts in the current project directory. The memo is saved per project.

## Reviewing Changes

Use the inspector to review generated edits, this-thread diffs, and command output before committing or pushing.
