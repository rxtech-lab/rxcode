# Project Hooks

Hooks run a command automatically at key points in a chat session's lifecycle.
Use them to inject context when a thread starts (for example, the current git
status, open TODOs, or environment notes) and to run cleanup or notification
commands when a turn finishes. Hooks are configured **per project**.

## Where to configure

Open **Settings → General → Hooks**, choose a project, and click **Manage
Hooks…**. The editor works like Run Configurations: a list of hooks on the left
(grouped by trigger) and a detail form on the right. Each hook has a name, an
**Enabled** toggle, a **trigger**, a shell **command**, an optional **working
directory**, and reusable **environment presets** (manual key/value pairs or a
loaded `.env` file).

Commands run with `/bin/zsh -lc`, so your login `PATH` (bun, pnpm, pyenv, …) is
available, just like the integrated terminal.

## Triggers

There are three triggers:

- **Before Session Start** — fires once, only when a brand-new thread begins its
  first turn. The command's standard output is **injected into the agent's
  context** for that turn, so the agent can use it as background information.
- **Before Session Stop** — fires when streaming stops (the agent finishes
  responding, or you cancel). Its output is **shown in the chat and saved** with
  the thread as a context block. It does not start a new agent turn.
- **After Session Stop** — fires after streaming stops, once the thread has been
  finalized. Its output is **shown only** — nothing is passed back to the
  session.

## Status in chat

Every hook run appears inline in the message list on both desktop and mobile as
a card: a spinner while it runs, then a success or error badge. Expand the card
to see the command's output. A non-zero exit code is marked as an error but does
not block the session.

## Notes

- Disabled hooks never run.
- "Before Session Start" only runs for new threads — sending more messages in an
  existing thread does not re-run it, while the stop hooks run every time a turn
  ends.
- For Claude Code threads, hook cards are shown during the live session; thread
  history for Claude is owned by the CLI, so reopened Claude threads may not
  display past hook cards. The start-hook context injection still applies to
  every provider.
