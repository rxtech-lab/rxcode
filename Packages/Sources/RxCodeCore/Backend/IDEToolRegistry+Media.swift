import Foundation

extension IDEToolRegistry {
    static let mediaTools: [IDETool] = [
        IDETool(name: "ide__media_models", description: "List configured image, video, and audio generation providers, downloaded models and Flowcy models with capability labels.", visibility: .alwaysIDEOnly,
                inputSchema: .object(["type": .string("object"), "properties": .object([:])])),
        IDETool(name: "ide__generate_media", description: "Generate an image, video or audio using the configured media provider. Refine an image by passing source_path (Codex or local models). Returns durable local file paths, or a Flowcy video job_id; poll using job_id. Does not change provider preferences. Flowcy uses the signed-in account allowance. options supplies provider-specific generation settings. Image tools are independent of the conversation's chat model.", visibility: .alwaysIDEOnly,
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "kind": .object(["type": .string("string"), "enum": .array([.string("image"), .string("video"), .string("audio")])]),
                        "prompt": .object(["type": .string("string")]),
                        "source_path": .object(["type": .string("string"), "description": .string("Absolute path to an image to refine; local and Codex only.")]),
                        "provider": .object(["type": .string("string"), "enum": .array([.string("codex"), .string("local"), .string("flowcy")])]),
                        "model": .object(["type": .string("string")]),
                        "job_id": .object(["type": .string("string"), "description": .string("Poll a previously returned Flowcy video job instead of submitting again.")]),
                        "options": .object(["type": .string("object"), "description": .string("Flowcy video: aspect_ratio, duration_seconds, person_generation, resolution. Audio: voice, or speakers for Gemini. Image: size, quality, background. Files must use presigned uploads; base64 inputs are not accepted here.")]),
                    ]), "required": .array([.string("kind")])
                ])),
        IDETool(name: "ide__pet_draft", description: "Show or control the draft pet preview inside the pet creation sheet. Pass a completed pack path to show it before finalizing. Supports pose, play/pause and frame selection. Only available inside a pet-look creation session; never changes the live pet.", visibility: .alwaysIDEOnly,
                inputSchema: .object(["type": .string("object"), "properties": .object([
                    "path": .object(["type": .string("string")]),
                    "pose": .object(["type": .string("string"), "enum": .array(["idle", "working", "waiting", "resting", "waving", "walking", "celebration", "failure"].map(JSONValue.string))]),
                    "playing": .object(["type": .string("boolean")]),
                    "mouth": .object(["type": .string("string"), "enum": .array([.string("automatic"), .string("closed"), .string("open")])]),
                    "frame": .object(["type": .string("integer"), "minimum": .number(0)]),
                ])]))
    ]
}
