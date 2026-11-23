extension IDEToolRegistry {
    public static let codingPlanBriefingInstructions = """
    For workspace or project briefings, use ide__list_coding_plans to find plan activity in the requested scope and period, including plans with no assistant chat replies. Use ide__list_coding_plan_versions and ide__get_coding_plan_version when you need the planned features. Identify each relevant plan once by title and ID in the user's requested sections. Report its planning status separately from its implementation status and cite the linked evidence. A ready or approved plan describes planned work.
    """

    static let briefingTools: [IDETool] = [
        IDETool(
            name: "ide__project_briefings",
            description: "List generated project briefing IDs, branches, and dates, including older briefings. Defaults to the current chat's project. Use ide__project_briefing_get for the full text.",
            visibility: .alwaysIDEOnly,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "project_id": .object(["type": .string("string"), "description": .string("Project UUID.")]),
                    "branch": .object(["type": .string("string"), "description": .string("Exact branch name. Defaults to all branches.")]),
                    "limit": .object(["type": .string("integer"), "minimum": .number(1), "maximum": .number(50), "default": .number(20)]),
                    "offset": .object(["type": .string("integer"), "minimum": .number(0), "default": .number(0)]),
                ]),
            ])
        ),
        IDETool(
            name: "ide__project_briefing_get",
            description: "Read a full generated project briefing by its ID from ide__project_briefings.",
            visibility: .alwaysIDEOnly,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(["id": .object(["type": .string("string")])]),
                "required": .array([.string("id")]),
            ])
        ),
        IDETool(
            name: "ide__briefing_list",
            description: "List document briefings stored in RxCode (agent-written reports shown on the briefing timeline), newest first. Includes drafts by default.",
            visibility: .alwaysIDEOnly,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "project_id": .object([
                        "type": .string("string"),
                        "description": .string("Optional project UUID to only list briefings for that project."),
                    ]),
                    "include_drafts": .object([
                        "type": .string("boolean"),
                        "description": .string("Include unpublished drafts. Default true."),
                    ]),
                ]),
            ])
        ),
        IDETool(
            name: "ide__briefing_get",
            description: "Get a document briefing's metadata, full content, and the files stored with it (images, videos, files).",
            visibility: .alwaysIDEOnly,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object([
                        "type": .string("string"),
                        "description": .string("Briefing UUID from ide__briefing_list or ide__briefing_create."),
                    ]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        IDETool(
            name: "ide__briefing_create",
            description: "Create a document briefing: a locally stored report written in Markdown or HTML, with its own folder for images, videos, and files. It starts as a draft hidden from the user's briefing timeline; add files with ide__briefing_add_file, then call ide__briefing_publish. Reference stored files from the content with relative paths such as `images/chart.png`. The title is displayed above the content, so do not repeat it as a heading in the content. Only create briefings when the user asks for a report or briefing. " + codingPlanBriefingInstructions,
            visibility: .alwaysIDEOnly,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "title": .object([
                        "type": .string("string"),
                        "description": .string("Briefing title."),
                    ]),
                    "content": .object([
                        "type": .string("string"),
                        "description": .string("Initial body in the chosen format. Can be filled in later with ide__briefing_update. The title is shown separately, so do not repeat it as a heading at the top of the content."),
                    ]),
                    "format": .object([
                        "type": .string("string"),
                        "enum": .array([.string("markdown"), .string("html")]),
                        "description": .string("Content format. Default markdown."),
                    ]),
                    "project_id": .object([
                        "type": .string("string"),
                        "description": .string("Optional project UUID. Defaults to the current chat's project."),
                    ]),
                    "publish": .object([
                        "type": .string("boolean"),
                        "description": .string("Publish immediately instead of creating a draft. Default false."),
                    ]),
                ]),
                "required": .array([.string("title")]),
            ])
        ),
        IDETool(
            name: "ide__briefing_update",
            description: "Update a document briefing's title and/or content. `content` replaces the whole body. Passing only `format` converts the content file without changing its text.",
            visibility: .alwaysIDEOnly,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object([
                        "type": .string("string"),
                        "description": .string("Briefing UUID from ide__briefing_list or ide__briefing_create."),
                    ]),
                    "title": .object([
                        "type": .string("string"),
                        "description": .string("New title."),
                    ]),
                    "content": .object([
                        "type": .string("string"),
                        "description": .string("New full body, replacing the existing content. Do not repeat the title as a heading at the top of the content."),
                    ]),
                    "format": .object([
                        "type": .string("string"),
                        "enum": .array([.string("markdown"), .string("html")]),
                        "description": .string("Switch the content format."),
                    ]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        IDETool(
            name: "ide__briefing_delete",
            description: "Permanently delete a document briefing and every file stored with it. Only do this when the user asks.",
            visibility: .alwaysIDEOnly,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object([
                        "type": .string("string"),
                        "description": .string("Briefing UUID from ide__briefing_list or ide__briefing_create."),
                    ]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        IDETool(
            name: "ide__briefing_add_file",
            description: "Add or replace a file stored with a briefing. Files go into `images/`, `videos/`, or `files/` (inferred from the extension unless `kind` is set). Pass exactly one source: `source_path` (copy a local file), `text`, or `base64`. Returns the relative `path` to reference from the briefing content. Set `overwrite` to update an existing file; otherwise a clashing name gets a numeric suffix.",
            visibility: .alwaysIDEOnly,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object([
                        "type": .string("string"),
                        "description": .string("Briefing UUID from ide__briefing_list or ide__briefing_create."),
                    ]),
                    "file_name": .object([
                        "type": .string("string"),
                        "description": .string("File name to store, e.g. `chart.png`. Required with `text` or `base64`; defaults to the source file's name."),
                    ]),
                    "source_path": .object([
                        "type": .string("string"),
                        "description": .string("Absolute path of a local file to copy into the briefing."),
                    ]),
                    "text": .object([
                        "type": .string("string"),
                        "description": .string("UTF-8 text content for the file."),
                    ]),
                    "base64": .object([
                        "type": .string("string"),
                        "description": .string("Base64-encoded binary content for the file."),
                    ]),
                    "kind": .object([
                        "type": .string("string"),
                        "enum": .array([.string("image"), .string("video"), .string("file")]),
                        "description": .string("Override the inferred file category."),
                    ]),
                    "overwrite": .object([
                        "type": .string("boolean"),
                        "description": .string("Replace an existing file with the same name. Default false."),
                    ]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        IDETool(
            name: "ide__briefing_delete_file",
            description: "Delete a file stored with a briefing.",
            visibility: .alwaysIDEOnly,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object([
                        "type": .string("string"),
                        "description": .string("Briefing UUID from ide__briefing_list or ide__briefing_create."),
                    ]),
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("Relative file path as returned by ide__briefing_get, e.g. `images/chart.png`."),
                    ]),
                ]),
                "required": .array([.string("id"), .string("path")]),
            ])
        ),
        IDETool(
            name: "ide__briefing_publish",
            description: "Publish a document briefing so it appears on the user's briefing timeline. Call again after later edits to re-publish; pass `unpublish` to return it to draft.",
            visibility: .alwaysIDEOnly,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object([
                        "type": .string("string"),
                        "description": .string("Briefing UUID from ide__briefing_list or ide__briefing_create."),
                    ]),
                    "unpublish": .object([
                        "type": .string("boolean"),
                        "description": .string("Move a published briefing back to draft instead. Default false."),
                    ]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        IDETool(
            name: "ide__send_notification",
            description: "Send the user a notification through the Flowcy notification service (delivered by email to their account email or a verified trusted email; counts against a small daily quota). Use it only when the user or a scheduled task's prompt asks to be notified, emailed, or sent a report. Pass `briefing_id` to send a document briefing; its local images are uploaded and embedded automatically, and RxCode won't send that briefing again. Published briefings may otherwise be sent automatically after your run ends, so don't send one just because you published it.",
            visibility: .alwaysIDEOnly,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "subject": .object([
                        "type": .string("string"),
                        "description": .string("Email subject (max 200 characters). Defaults to the briefing title when `briefing_id` is set."),
                    ]),
                    "body": .object([
                        "type": .string("string"),
                        "description": .string("Message body. Ignored when `briefing_id` is set. Local images referenced with absolute paths are uploaded and embedded."),
                    ]),
                    "format": .object([
                        "type": .string("string"),
                        "enum": .array([.string("text"), .string("markdown"), .string("html")]),
                        "description": .string("How `body` is rendered. Default markdown."),
                    ]),
                    "briefing_id": .object([
                        "type": .string("string"),
                        "description": .string("Optional briefing UUID to send as the notification content."),
                    ]),
                ]),
            ])
        ),
    ]
}
