import Foundation

extension IDEToolRegistry {
    static let searchHuggingFaceModelsTool = IDETool(
        name: "ide__search_huggingface_models",
        description: "Search Hugging Face model repositories in GGUF and MLX formats. Returns task metadata, repository URLs, and open_url links. Show each chosen open_url as a Markdown link so the user can open RxCode's model sheet with that model selected, review variants, and initiate a download. This tool does not download models. Catalog results do not guarantee local runtime support.",
        visibility: .alwaysIDEOnly,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "query": .object(["type": .string("string"), "description": .string("Model name or search text; empty lists popular models.")]),
                "format": .object(["type": .string("string"), "enum": .array([.string("gguf"), .string("mlx"), .string("all")]), "description": .string("Default: all.")]),
                "category": .object(["type": .string("string"), "description": .string("Optional Hugging Face pipeline tag, such as text-to-video or text-generation.")]),
                "limit": .object(["type": .string("integer"), "minimum": .number(1), "maximum": .number(30), "description": .string("Maximum total results. Default: 10.")]),
            ]),
            "required": .array([.string("query")]),
            "additionalProperties": .bool(false),
        ])
    )
}
