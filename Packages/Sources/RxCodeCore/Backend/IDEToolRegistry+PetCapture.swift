import Foundation

extension IDEToolRegistry {
    public static let petCaptureTools: [IDETool] = [
        IDETool(name: "ide__pet_list_capture_targets",
                description: "List connected displays with IDs, names, positions and the pet's current display, plus available windows. Returns Screen Recording permission status without prompting. Use to resolve other displays or ambiguous windows.",
                visibility: .alwaysIDEOnly,
                inputSchema: .object(["type": .string("object"), "properties": .object([:])])),
        IDETool(name: "ide__pet_capture",
                description: "Take one screenshot only when requested by the user. Defaults to the display where the pet sits. For another display, pass display_id from list_capture_targets; for a window, pass window_id or an unambiguous window_query (app/title). The pet walks to the target and takes a photo after arrival. Returns actual image content to inspect. Ambiguity returns candidates: ask a concise selection then retry by ID. Uses native Screen Recording onboarding without per-capture confirmation.",
                visibility: .alwaysIDEOnly,
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "display_id": .object(["type": .string("integer")]),
                        "window_id": .object(["type": .string("integer")]),
                        "window_query": .object(["type": .string("string")])
                    ])
                ]))
    ]
}
