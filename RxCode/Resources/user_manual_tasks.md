# Projects Dashboard

Select **Tasks** under **General** in the sidebar to open the all-projects overview. Each project card shows its recently active stories, progress on their tasks, and task counts by status. Click a story to see its tasks, or click the project name to open that project's full board. Use the search field to find stories by their own text or a child task's text. Drag a project name onto another project card to reorder the cards.

## Stories and Tasks

A story groups related tasks. Create one with **New Story** on the overview or from a project card. Open a story to review its progress and add tasks. In the story's **Describe a task…** field, what you type becomes the task description; RxCode generates a title or shortens the first line, depending on the setting in **Settings → Tasks**.

Use **New Task** to create a task directly. In its form, choose a project and optional story, then add a description, type, priority, target version, milestone, and tags. The sparkle button beside the title generates a title from the description. **Auto-fill** suggests values for empty properties.

You can also right-click an unlinked chat in the sidebar and choose **Create Task from Chat with AI**. The new task stays linked to its source chat. For a linked chat, choose **Jump to Task** to open it.

## Project Boards and Views

Open a project from the overview to see its task board. Use **New view** to save a board or table layout with its own visible statuses and story, version, or tag filters. The search field narrows the current view. A task created from a filtered view inherits its story, version, and tags.

Drag task cards between board columns to change status. The arrow beside **New Task** opens **Columns**, where you can reorder or edit statuses and their automation, and **Fields**, where you can manage types, tags, versions, and milestones.

## Running a Task

Assign a model in the task's **Agent** section. On the default board, moving an assigned task to **In Progress** starts a new agent chat. The task moves to **Pending Review** when the turn finishes. Column triggers can be changed in **Columns**. While the agent is working, the card shows activity and its status is controlled by the run.

Open the task's **Run** tab to review the conversation and follow up, or use **Open Chat** to jump to its thread. The original task description is locked after the run starts so it continues to match the prompt sent to the agent.
