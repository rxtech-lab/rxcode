# Chat and Attachments

The chat view is where prompts, agent responses, tool calls, plans, questions, and queued messages appear.

## Sending Messages

Type a message and press **Return** to send. Use **Shift-Return** for a line break. If an agent is already responding, new messages are queued and sent after the active response finishes.

## Session Controls

Use the toolbar to choose:

- **Agent**: Claude Code, Codex, or an ACP client.
- **Model**: the model used by the current session.
- **Effort**: how much reasoning the agent should apply.
- **Permission mode**: how file edits and command execution are approved.

## Coding Plans

Open **Add (+) → Plan Mode** in the composer. Enter the goal, choose a planner, and give each reviewer a model and review instructions. The planner hosts by default. You can choose another host in the setup sheet.

The debate appears beside the live Markdown plan. Dots beside an agent’s name show who is responding. The host sets an agenda, gives each reviewer one turn, and produces a final plan. Click a plan chip or use the version menu to open a draft. Changed passages are underlined. Click one to read the original wording and its comments, or choose **Add Comment** to leave a note. A ⌫ marks a deletion. Use **Revise** to edit the latest plan and optionally explain the change, or ask the host for another version.

Use **Message the debate** to ask a question or add a constraint. The next speaker sees your message. Once the review round ends, the host answers follow-ups and can update the plan. Sending a message in a paused debate also resumes the pending turn. **Resume Debate** retries that turn using the saved draft and completed reviews.

Choose the version you want and click **Implement**. The model picker starts with the planner. Implementation opens in a fresh chat with the selected plan. Use **View Plan** to reopen the debate and version history.

In an existing chat, **Create from Chat** or the chat’s context menu lets you turn the conversation into a plan, task, or story. Choose an agent to draft it. For tasks and stories, review the board item before saving.

## Attachments

Attach files with the paperclip button or drag files onto the input area. Pasting is smart: URLs, file paths, images, and long text can become preview chips automatically.

Configure attachment preview behavior in **Settings -> Message**.

## Mentions

Type **@** to find project files or saved shortcuts. File mentions insert context into the prompt, while shortcuts can insert reusable text or run terminal commands.
