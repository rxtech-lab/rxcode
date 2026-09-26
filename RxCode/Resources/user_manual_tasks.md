# Projects Dashboard

Select **Tasks** under **General** in the sidebar to open the all-projects overview. Each project card shows its recently active stories, progress on their tasks, and task counts by status. Click a story to see its tasks, or click the project name to open that project's full board. Use the search field to find stories by their own text or a child task's text. Drag a project name onto another project card to reorder the cards.

## Stories and Tasks

A story groups related tasks. The creation sheet writes either kind two ways: the **AI** and **Form** tabs at the top pick how, and the dropdown beside them picks whether you are creating a task or a story. Switching either one keeps what you have drafted so far, so a generated draft can always be finished by hand. The **New Story** and **New Task** menus on the overview, on a project card and on a project page open the sheet straight on **With AI** or **With Form**.

On the **AI** tab, describe the work or choose a text or PDF file, then choose **Generate Draft**. The description field takes pasted and dropped images and files, the same as the one on the **Form** tab: each one is written into the text as a Markdown link, and on a task it is also added to its attachments. For a story RxCode drafts the story and its child tasks for review; edit their titles and descriptions, add or remove tasks, then choose **Create Story and Tasks**. For a task it writes the title from your description and suggests the type, priority, story, version, milestone and tags, shown as chips; switch to **Form** to change any of them before saving.

Open a story to review its progress and add tasks. In the story's **Describe a task…** field, what you type becomes the task description; RxCode generates a title or shortens the first line, depending on the setting in **Settings → Tasks**.

On the **Form** tab, choose a project and optional story, then add a description, type, priority, target version, milestone, and tags. The sparkle button beside the title generates a title from the description. **Auto-fill** suggests values for empty properties.

You can also right-click an unlinked chat in the sidebar and choose **Create Task from Chat with AI**. The new task stays linked to its source chat. For a linked chat, choose **Jump to Task** to open it.

## Project Boards and Views

Open a project from the overview to see its task board. Use **New view** to save a board or table layout with its own visible statuses and story, version, or tag filters. The search field narrows the current view. A task created from a filtered view inherits its story, version, and tags.

Drag task cards between board columns to change status. The arrow beside **New Task** opens **Columns**, where you can reorder or edit statuses and their automation, and **Fields**, where you can manage types, tags, versions, and milestones.

## Running a Task

Assign a model in the task's **Agent** section. On the default board, moving an assigned task to **In Progress** starts a new agent chat. When the turn finishes, a separate check thread verifies the work before the task moves to **Pending Review**. If that check cannot reach a verdict, RxCode runs it again up to three times, then marks the task as needing attention with the reason so you can review it and continue its chat. Column triggers can be changed in **Columns**. While the agent is working, the card shows activity and its status is controlled by the run.

Open the task's **Run** tab to review the conversation and follow up, or use **Open Chat** to jump to its thread. The original task description is locked after the run starts so it continues to match the prompt sent to the agent.

## Syncing with Notion

RxCode can mirror a project's task status to a Notion database and import that database's pages as tasks. In **Settings → Tasks → Notion**, or in the Notion sheet, pick a **Relay server**, choose **Connect with Notion**, sign in, and select the pages and databases RxCode may access. The list shows the relay servers configured in **Settings → Mobile** plus RxLab's hosted relays; the relay you pick must have Notion sign-in configured, and RxCode keeps using it to renew the sign-in. You can instead choose **Use a token instead** and paste an internal integration token, then share your database with that integration from the database's **Connections** menu.

Choose **Notion** in the header of the Tasks overview or of a project page. In the sheet, pick the project and the Notion database from the dropdowns. Database properties are matched by name: Status, Priority, Tags, Version, Milestone, Type, Story, and Description. The first sync adds any that are missing, so every field, including the description, reaches Notion. When the Status property has no option named like a column, RxCode uses Notion's status groups instead: done columns go to **Complete** (for example “Done”), the column that starts the agent and later columns to **In progress**, and earlier columns to **To-do**.

Once a project is linked, its page header shows the database name. Click it to sync now, or open its menu to import, turn automatic sync on or off, or open the Notion sheet. A warning icon means the last sync failed; hover over it to see why.

- **Sync to Notion** writes every task as a page, with its column as the status, and moves pages of deleted tasks to the Notion trash. Turn on **Sync status automatically** to push a few seconds after each board change.
- **Import from Notion** adds pages that are not on the board yet. A page whose status matches a column name goes into that column, except columns that start an agent; those pages, and pages with an unknown status, go to the first column. Story names that don't match an existing story create a new story.
