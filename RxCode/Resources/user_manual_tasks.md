# Projects Dashboard

Select **Tasks** under **General** in the sidebar to open the all-projects overview. Each project card shows its recently active stories, progress on their tasks, and task counts by status. Click a story to see its tasks, or click the project name to open that project's full board. Use the search field to find stories by their own text or a child task's text. Drag a project name onto another project card to reorder the cards.

## Stories and Tasks

A story groups related tasks. The creation sheet writes either kind two ways: the **AI** and **Form** tabs at the top pick how, and the dropdown beside them picks whether you are creating a task or a story. Switching either one keeps what you have drafted so far, so a generated draft can always be finished by hand. The **New Story** and **New Task** menus on the overview, on a project card and on a project page open the sheet straight on **With AI** or **With Form**.

On the **AI** tab, describe the work or choose a text or PDF file, then choose **Generate Draft**. The description field takes pasted and dropped images and files, the same as the one on the **Form** tab: each one is written into the text as a Markdown link, and on a task it is also added to its attachments. For a story RxCode drafts the story and its child tasks for review, and links tasks that build on each other with **Starts after** so they run in sequence; edit their titles, descriptions and links, add or remove tasks, then choose **Create Story and Tasks**. For a task it writes the title from your description and suggests the type, priority, story, version, milestone and tags, shown as chips; switch to **Form** to change any of them before saving.

Open a story to review its progress and add tasks. In the story's **Describe a task…** field, what you type becomes the task description; RxCode generates a title or shortens the first line, depending on the setting in **Settings → Tasks**.

On the **Form** tab, choose a project and optional story, then add a description, type, priority, target version, milestone, and tags. The sparkle button beside the title generates a title from the description. **Auto-fill** suggests values for empty properties, including an existing task this one should start after when it builds on that work. Use **Starts after** to select multiple tasks, in this or any other project. Every selected task must reach **Pending Review** or a done column before this one moves to **In Progress**. Tasks from other projects are listed under their project's name. Select a task again or remove its chip to unlink it.

Autopilot currently stores one same-project **Starts after** link per cloud task. Additional links remain on this Mac; they do not appear on other devices through cloud sync. The iOS cloud editor allows one link until Autopilot supports multiple links.

You can also right-click an unlinked chat in the sidebar and choose **Create Task from Chat with AI**. The new task stays linked to its source chat. For a linked chat, choose **Jump to Task** to open it.

## Local and Cloud Projects

A project is local by default: its stories and tasks stay on this Mac. A cloud project also keeps its board in Autopilot, so its stories and tasks sync to every device signed in to your account. Cloud projects show a cloud icon next to their name.

To create one, choose **Project → New Cloud Project…** on the overview, or **New cloud project…** from the **+** menu in the toolbar. Pick the project's folder, then choose **Cloud** or **This Mac** under **Location**. You need to be signed in to Autopilot to create a cloud project. To change an existing project, click the **Local** or **Cloud** button on the project page (the cloud icon on a project card, or the project's menu in the sidebar). Choose **Sync to Cloud** to upload it, **Link to Autopilot Project…** to search for a project already in Autopilot and sync with it, or **Make Local Only**. **Make Local Only** keeps the board on this Mac and leaves the cloud copy and other devices untouched.

Cloud projects that aren't on this Mac yet appear as cards at the end of the overview. Choose **Open on This Mac…** to pick a folder for one, or **Link to Project** to sync it with a project you already have. To tidy the overview, click the hidden-eye icon on a card to hide it; the **Hidden** menu in the header lists hidden projects so you can show them again. Changes sync a moment after you make them and are checked every 30 seconds. When the same item changes on two devices, the most recent edit wins. Agent settings, runs, and attachments stay on the device that made them.

## Project Boards and Views

Open a project from the overview to see its task board. Use **New view** to save a board or table layout with its own visible statuses and story, version, or tag filters. The search field narrows the current view. A task created from a filtered view inherits its story, version, and tags.

Drag task cards between board columns to change status. The arrow beside **New Task** opens **Columns**, where you can reorder or edit statuses and their automation, and **Fields**, where you can manage types, tags, versions, and milestones.

## Running a Task

Assign a model in the task's **Agent** section. On the default board, moving an assigned task to **In Progress** starts a new agent chat. When the turn finishes, a separate check thread verifies the work before the task moves to **Pending Review**. If that check cannot reach a verdict, RxCode runs it again up to three times, then marks the task as needing attention with the reason so you can review it and continue its chat. RxCode sends a desktop notification, mirrored to paired mobile devices, when a task reaches **Pending Review**, when the check rejects its work, or when a code review fails and moves it back. Column triggers can be changed in **Columns**. While the agent is working, the card shows activity and its status is controlled by the run.

Open the task's **Run** tab to review the conversation and follow up, or use **Open Chat** to jump to its thread. The original task description is locked after the run starts so it continues to match the prompt sent to the agent.
