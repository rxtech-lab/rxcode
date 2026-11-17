# Pet looks

Open **Pet & Voice Settings → Looks** to switch appearances immediately, create a variant, edit a saved look, or import a pack. The selection and custom looks persist across launches. Chat history and active calls continue when the appearance changes. Built-in looks can be duplicated; removing an active custom look returns to Robot.

The editor previews hue, saturation and accessories before **Save & Use**. Use the pet's existing chat or voice conversation to request changes such as “Make a new look called Mint with a crown.” All agent providers receive the shared `ide__pet_look` tool. Agents should list available looks before selecting one by ID.

## Data-only packs

A pack is a folder containing `look.json` and `atlas.png`. No executable code is loaded. Import copies the atlas into Application Support, assigns a fresh ID, saves the look and selects it without restarting the pet. Reimport an edited pack to load another version while keeping the previous look available.

Example `look.json`:

```json
{
  "version": 1,
  "id": "example-robot",
  "name": "Example Robot",
  "hue": 0,
  "saturation": 1,
  "accessory": "none",
  "columns": 6,
  "rows": 8
}
```

The atlas is an evenly divided PNG grid with 1–24 columns and exactly 8 rows, ordered: idle, working, waiting, resting, waving, walking, celebration, failure. Each row has the same number of frames. Transparent backgrounds work best. The renderer uses each motion's default frame duration; speech pairs are selected using the actual playback audio envelope. Each image must be at most 32 MB and 8192 × 8192 pixels; manifests must be at most 16 KB. Pack-supplied IDs and asset paths are ignored.

Hue is 0–360 degrees, saturation is 0–2, and accessories are `none`, `star`, `heart` or `crown`. Names must contain 1–80 characters. Custom look metadata is stored separately from existing voice preferences, so older installations default to Robot. Removing a look removes its library entry; copied atlas files are retained to support other variants referencing them.

## Agent tool

- `action: "list"` returns `selected_id` and available looks.
- `action: "set", id` selects an existing look.
- `action: "save", name` creates and selects a new variant of the current look. Supply `id` to choose another source, plus optional `hue`, `saturation`, and `accessory`.
- `action: "import", path` imports a pack at an absolute local folder path.

Library calls return the selected ID and updated library; guide returns the bundled skill. Invalid customization leaves the current selection intact. Agents do not remove or overwrite saved looks.

## Create and revise with chat

Regular project chat includes the built-in `rxcode-pet-look` skill for Claude, Codex, ACP clients and local agents. `ide__pet_look` action `guide` returns the full skill, including the atlas contract and creation workflow. Ask the agent to create a character, import it, and export it to Desktop. Action `export` accepts an optional saved look ID and returns the actual `exported_path`. Every export creates a fresh folder; existing exports are preserved. Image creation uses the selected agent's available tools and reports missing capabilities instead of claiming success.

In Settings → Looks, **Create with Prompt** opens a dedicated design conversation. Describe a new character, inspect its validated draft, and send further prompts to revise it. **Revise with Prompt** in a look's menu starts from that look's metadata and atlas. The conversation reuses the regular chat list and composer, including file attachments, image paste, and queued messages. Choose a chat model from Claude, Codex, ACP clients, or installed local chat models, and independently choose an image model. The initial chat selection follows the General Agent setting. The draft preview appears inline beside the chat; agents can use `ide__pet_draft` to show and control it. Draft preparation does not change the library or active pet; **Save & Use** commits the preview. Closing or stopping generation preserves the previous draft and leaves the live pet unchanged.

The creation sheet shows the draft preview inline beside the conversation, with Close and Save & Use at the top and no usage status bar. **Preview Poses** and the editor preview offer all eight poses, replay, play/pause, and frame scrubbing. The frame label identifies the current sheet when paused.

## Four-sheet animation

The presets are Robot, Dog, Cat and Puff, an original rounded pink character. All four use detailed dimensional artwork. An imported Dog or Detailed Dog with the exact same sheets and default styling as the bundled Dog is consolidated into Dog on launch, preserving selection; customized and different packs remain available. Source files are retained. Each uses four animation sheets. A pack may set `"sheetCount": 4` and include `atlas.png`, `atlas-2.png`, `atlas-3.png`, and `atlas-4.png`. Every sheet has the same column count and eight motion rows. For each motion, frames play left to right across sheet 1, then sheets 2, 3 and 4. Six frames per sheet provide 24 frames per pose. Use distinct continuation frames with consistent character size and baseline.

`sheetCount` is optional for older single-sheet packs and defaults to 1. The total image budget is 64 megapixels across all sheets, with the same per-image size limits. Cell coordinates are normalized to each sheet's dimensions, so generated artwork does not need destructive resizing before import. Exports include all sheets and portable metadata, without app-local asset paths or preset references.

Multi-sheet pets play at 12.5 frames per second. Working, waiting and resting animations repeat while those states remain active; wave, celebration and failure reactions play through once. Accessibility Reduce Motion still shows a static pose.

## Paired speech frames

New packs set `hasSpeechFrames: true`. For every body sheet, include a `-closed.png` and `-open.png` companion: `atlas-closed.png`, `atlas-open.png`, `atlas-2-closed.png`, `atlas-2-open.png`, and so on. Each companion must match its body sheet's exact dimensions and grid. Keep the body and head identical in each pair, changing only the mouth. All eight poses and every animation frame need both variants, so speech remains aligned while walking or gesturing. The pack's 64 megapixel budget includes these companions.

Robot, Dog, Cat, and Puff each bundle paired artwork for all 192 body frames (768 body frames and 1,536 speech variants in total). Audio selects the current frame's open or closed variant, with a 140 ms silence hold, a minimum 180 ms open interval, and a minimum 120 ms closed interval to avoid rapid chatter. Silent gaps, mute, and cancellation close the mouth; no live mouth overlay is drawn. Older packs remain compatible through pairs baked into the sprite cache. They can optionally supply a normalized `mouth: {"x":0.45,"y":0.50,"width":0.10,"height":0.025}` anchor; without one the legacy face position is approximate. Revise an older pack to author aligned speech sheets for the best result. Preview provides Automatic, Closed, and Open controls for inspecting every pose and frame.

## Media providers and tools

**RxCode Settings → Media** saves independent image, video, and audio models. Images can use Codex's native image tool, a downloaded image model, or Flowcy. Video and audio use downloaded models or enabled Flowcy models, grouped by their catalog labels. Flowcy uses the signed-in account; no provider API key is required in RxCode. Both Debug and Release use `https://www.flowcy.dev/api/v1`.

All chat providers receive `ide__media_models` and `ide__generate_media`. Call the former to discover current choices. Generate with `kind`, `prompt`, and optional `provider`, `model`, and `options`; image refinement accepts `source_path` with Codex or downloaded image models. The Flowcy image API currently accepts text prompts only. Image and audio results return durable local paths. Flowcy video submission returns a job ID, which can be polled with `kind: "video", job_id`. File uploads are not embedded into these JSON requests; cloud file inputs require a presigned S3 upload flow.
