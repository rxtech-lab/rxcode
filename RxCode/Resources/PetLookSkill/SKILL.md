---
name: rxcode-pet-look
description: Create or revise RxCode desktop pet sprite packs from a prompt, preview their poses, and export portable packs to the Desktop. Use for RxCode pet appearance requests.
---

# RxCode pet look creation

Use `ide__pet_look` action `list` to inspect available looks. For color/accessory variants, use `save` with a name and optional source ID, hue 0–360, saturation 0–2 and accessory none/star/heart/crown. This preserves the source and selects the new variant. For a new character or silhouette, author a sprite pack instead of just recoloring the robot.

A pack is a folder with `look.json` and four transparent animation sheets: `atlas.png`, `atlas-2.png`, `atlas-3.png`, `atlas-4.png`. Single-sheet legacy packs also work with `sheetCount: 1`. The manifest is:

```json
{"version":1,"id":"draft","name":"My Pet","hue":0,"saturation":1,"accessory":"none","columns":6,"rows":8,"sheetCount":4,"hasSpeechFrames":true}
```

Every new pack must also include matching closed-mouth and open-mouth artwork for every body frame: `atlas-closed.png`, `atlas-open.png`, `atlas-2-closed.png`, `atlas-2-open.png`, and so on through sheet 4. Set `hasSpeechFrames: true`. Companion sheets must have exactly the same dimensions, grid, transparency, pose, head position, and body artwork as their body sheet; change only the mouth. Cover all eight poses and all continuation frames, including walking, working, and gestures. Generate paired artwork together or refine the closed version to preserve alignment. Inspect both variants in several poses before finishing. Playback chooses the pair for the current body frame using actual speech audio; never create a separate live mouth overlay. Older packs without speech sheets remain compatible through a cached fallback pair.

Use 1–24 equally sized frames per row on each sheet and exactly eight rows: idle, working, waiting, resting, waving, walking, celebration, failure. For each motion, frames run left to right on sheet 1, then sheet 2, sheet 3, sheet 4. Produce distinct continuation frames, not four copies. Keep the character's identity, size and baseline consistent across frames and sheets. Animate each state distinctly. Keep the whole character inside every cell. Use a uniform grid with ample transparent cell padding. Each PNG must be at most 8192×8192 pixels and 32 MB, with at most 64 megapixels across the pack. Manifest limit: 16 KB. Never put executable code in a pack. No absolute asset paths are needed in its manifest.

Use `ide__media_models` to inspect configured providers and `ide__generate_media` with `kind: "image"` to generate or refine artwork independently of the chat model. Codex, downloaded image models, and Flowcy are supported. Pass `source_path` to refine with Codex or a downloaded model. Flowcy currently accepts text image prompts only. Returned local paths can be used as source artwork for atlas authoring. Use available image-generation tools when suitable; use a transparent vector/procedural illustration rasterized with available local tools when image generation is unavailable. Inspect the generated atlas and several cropped poses with available image tools before reporting success. If the environment cannot generate or inspect images, explain the limitation rather than claim a new character was generated.

In regular chat, import a completed pack using `ide__pet_look` action `import`, path set to the absolute pack folder. The returned selected_id identifies the new look. Then call action `export`, id set to that ID, to write a portable copy to the user's Desktop. Export also works for saved color/accessory variants. Report the tool's actual exported_path; do not invent a path or claim success after an error. Export creates a fresh folder and never overwrites an existing pack. Users can inspect poses in Settings → Looks → Preview.

For revisions to a saved character, call export first to obtain its current source sheets. Preserve the source pack, work in a fresh folder, keep unrequested details and animation states, and import/export the revised pack. Do not edit unrelated project files.

Settings creation mode supplies its own output directory and requires a draft preview before Save & Use. In this mode, create the pack only in that directory, do not call save/import/set/export, and finish with exactly {"path":"/absolute/pack/folder"}. Use `ide__pet_draft` with the pack's `path` to show the preview in the creation sheet. Control `pose`, `playing`, `frame` (zero-based), and `mouth` (`automatic`, `closed`, `open`) to inspect it with the user. The app validates the pack and displays the draft. Each revision must use a new subfolder so the previous preview stays intact.
