# Pet presentation, desktop input, music, and status widgets

All tools are registered in the shared IDE catalog, including live voice flows for Codex, Claude, ACP and the local agent. Existing IDE access and destructive-action confirmation policy still apply. Input tools are for explicit user requests. Native authorization does not grant permission to act proactively.

## Images and interactive UI

`ide__pet_capture` returns image evidence to the model. It does **not** display an image to the user. A successful result includes `capture_id` and `displayed_to_user: false`. The latest successful photo stays in memory; starting another capture invalidates it. Use `ide__pet_show_image` with that ID (or omit ID for the latest photo) to display it. Alternatively pass an absolute local image `path` (regular file, at most 20 MB). Decoding creates a bounded 2560-pixel preview off the main actor. The user can collapse and reopen it from its persistent entry bubble, or enlarge it in a native sheet. Only the entry bubble’s explicit Remove control discards the image.

The agent chooses `presentation: "popover"` (default) or `"bubble"` on the image tool. For interactive UI use the existing `ide__show_ui` tool with `pet_presentation: "popover"` or `"bubble"`. Pet sessions strongly prefer a compact inline UI card directly below the speech caption (`bubble`). The speech caption stays visible above the UI, and the UI card fits its content height. A small Close button removes the inline UI card and its retained content without dismissing the speech caption. Agents should summarize and simplify first, using short Text, Stat or KeyValue elements and avoiding unnecessary controls or complex layouts that would force a popover. A dedicated popover is reserved for an explicitly requested expanded view, essential information that cannot reasonably fit a caption summary, or required interaction. Caption UI displays only essential read-only information in at most five visible rows, with no scrolling, controls, or collapse/reopen entry. Any interaction, complex content, or text needing more room automatically uses a `popover`, only when the whole caption exceeds its five-row height; ordinary line wrapping stays inline. This default applies even if `pet_presentation` is omitted or the shared `presentation` argument says inline or dialog. These requests never open the companion window or a companion sheet. A bubble is a larger speech-style surface attached above the pet. A popover uses the same native anchor as pet confirmations. Interactive content uses `JSONUIRenderer`, including its local input and presentation actions; it does not execute arbitrary code or automatically send form submissions back to the agent. Each image and popover view keeps a compact entry bubble beside the pet. Caption UI has no entry bubble. Collapse, Escape and outside-click dismissal keep that entry and its content; Remove on the entry permanently removes it. Entries have no expiration timer, and new content does not evict older entries. Interactive form values and local action state survive reopening during the app session. Confirmations retain priority; speech and tool-call bubbles keep their separate transient behavior. Images and interactive UI report `status: "presented"` only after the SwiftUI surface acknowledges appearing. A hidden, disabled, blocked or timed-out presentation fails instead of claiming the user saw it.

## Desktop actions

`ide__pet_list_desktop_targets` lists Quartz window IDs, applications, titles, bounds and connected displays without asking for authorization. Hidden/minimized windows are included when Quartz exposes them; window titles may require Screen Recording access. Choose exactly one `window_id`, unambiguous `window_query`, or `display_id`. Focus and typing require a window. Ambiguity returns candidate IDs rather than picking a window.

- `ide__pet_focus_window` restores, raises and focuses the specifically resolved window through public Accessibility APIs. The owning process plus unique title and frame must match one AX window. Unsupported/ambiguous mappings fail safely. Focus is checked against the actual AX focused window, app frontmost state and Quartz window ordering.
- `ide__pet_click` posts a real left-button down/up pair. `x` and `y` are required normalized fractions from the target's top-left.
- `ide__pet_scroll` accepts `direction: up|down|left|right`, `amount: 1...1200` points (default 400), and optional `x`/`y` (default center). The pet travels to the nearest window edge; directional animation accompanies incremental native scrolling over the chosen point.
- `ide__pet_type_text` accepts `text` (1...4000 characters). Focus/click the intended text field first. The pet travels, raises the exact window and animates typing while dispatching Unicode keyboard events. The field must expose a supported editable AX role. A field/focus change stops further typing. No Return key or submit command is added; the destination app determines how it interprets supplied text.

Coordinates are **points**, independent of screenshot pixels and Retina scale. Given a target frame `(left, top, width, height)` in global Quartz coordinates, the input point is `(left + x*width, top + y*height)`, inset one point at the maximum edge. AppKit travel coordinates flip y about the primary display's top, retaining negative/multiple-display offsets. A window that moves or disappears during travel causes failure rather than a stale click. Obscured window targets are raised before input. Input checks front-to-back Quartz occlusion immediately before posting; pet-owned surfaces ignore mouse events so the visible action animation cannot intercept input.

Native Accessibility onboarding is requested only for a requested action. Denial shows a native recovery alert with a System Settings link. Slow AX IPC and event dispatch run on a separate actor. Dragging, interruption, stopping voice, hiding the pet or cancelling the tool stops further input. Capture and desktop actions cancel and drain each other before travel. Scroll/typing can have already delivered partial input when cancelled or interrupted; do not retry blindly. Results distinguish verified focus from `input_dispatched`, which does not prove the app changed. A fresh requested screenshot can verify the effect. OS event targeting cannot provide an atomic guarantee against another app changing focus at the exact dispatch instant.

## Apple Music

`ide__pet_music` supports `search` (`query`), `play` (`song_id` from search, or an unambiguous query), `resume`, `pause`, `status`, `enable` and `off`. Ambiguous search results return candidates without starting playback. Real playback uses MusicKit's native `ApplicationMusicPlayer`, available on macOS; `SystemMusicPlayer` is unavailable on macOS. The app player has its own queue, so turning pet music off never stops Music.app's unrelated queue. Off cancels/drains a pending play request, stops the pet player, clears its queue and dismisses its surface. Hiding the player using the Music button does not stop playback. Disabling/hiding the pet turns its music off.

The compact player appears above the pet and shows actual queue title/artist and play/pause/off controls. A Music button stays below the control bar. MusicKit state and queue notifications synchronize external media-control changes without polling. Native Apple Music authorization, Music account sign-in, a playable catalog subscription, network availability and MusicKit registration for the signed App ID are required. `NSAppleMusicUsageDescription` explains access. Failures retain the native error and provide recovery guidance; search results, opening the panel, or tool completion never establish audible playback. Developer account configuration and actual playback must be verified on the signed app separately from a successful build.

Apple references: [ApplicationMusicPlayer](https://developer.apple.com/documentation/musickit/applicationmusicplayer), [MusicKit automatic token generation](https://developer.apple.com/documentation/musickit/using-automatic-token-generation-for-apple-music-api).

### Volume

The agent and voice call use the same `ide__pet_music` tool and hardware controller as the playback card:

| Action | Arguments | Behavior |
| --- | --- | --- |
| `volume` | None | Read actual device volume, writable support, device name and mute state. |
| `set_volume` | `volume: 0...100` | Set an absolute percentage. |
| `increase_volume` | Optional `amount: 0...100` | Raise by percentage points, default 5 for “a little.” |
| `decrease_volume` | Optional `amount: 0...100` | Lower by percentage points, default 5. |

Relative changes clamp at 0 and 100. Invalid, missing absolute, nonnumeric or nonfinite inputs do not write. Volume actions do not start, pause, replace or enable the pet's music queue, and do not request MusicKit authorization. They can run during another music operation.

**Scope is the default output device, not pet-only gain.** The macOS MusicKit SDK exposes no volume property on `ApplicationMusicPlayer`. The implementation uses Core Audio's `AudioObject` property APIs and virtual main volume on the current default output device. It affects all audio routed through that device, including other apps and voice calls. MusicKit can use a different route such as AirPlay; changing the Mac's default device does not guarantee changing that route's playback level. The voice microphone/speaker preferences do not reroute MusicKit.

Every write rechecks support and pins the device ID to reject an output switch during adjustment. The result includes `volume_scope=default_output_device`, the actual readback in `volume`, `volume_settable`, `device`, `muted` and `applied`. Reading has `applied=null`; failed, unsupported or unconfirmed writes have `isError=true` and `applied=false`. Device quantization is reflected in the readback (confirmation tolerance is one percentage point). A device that settles asynchronously may initially report unconfirmed; read again for its current state. Mute is reported where available and never changed automatically. Devices without a readable/settable software main-volume property require hardware controls; the app does not substitute a stored slider value or claim success.

Hovering over the existing music card reveals a compact **Device volume** slider in an animated footer below the artwork, song title, artist and playback/close controls. Metadata and controls remain visible and accessible throughout hover. Its tooltip explains the output scope. The card animates between its compact content height and the expanded footer height over 0.2 seconds, with no empty volume space when idle. Its width remains stable. The slider stays mounted, becomes invisible when the pointer leaves, and collapses its space after any active drag finishes; it is hidden from accessibility and new pointer interactions when idle. While hovered and not dragging, it refreshes external device/volume changes every 500 ms. Errors appear in an overlay. Unsupported hardware disables the slider with an explanation. The card still appears only for pet-owned playback/loading.

Apple reference: [Changing the volume of audio devices](https://developer.apple.com/library/archive/qa/qa1016/) documents that device volume support must be checked and is not available on every device. The implementation uses modern `AudioObject` APIs rather than the sample's deprecated `AudioDeviceSetProperty` API.

## Compact status indicator

`ide__pet_status` controls a separate, unobtrusive native text indicator beside the sprite. Supply an emoji, a few words or a short sentence using a root Text or Badge. Markdown is rendered with the shared Markdown view. The surface fits its measured content; short sentences wrap at a modest maximum width. An opaque theme-adaptive rounded background, subtle border and native window shadow keep ordinary Text content readable over the desktop. A visible accessible X clears the current status card. There is no fixed panel size, scrolling dashboard or minimum width/height. Its native window is resized after SwiftUI layout, preserving the panel resize-loop safeguards.

- `operation: "set"` (default) replaces `spec: {"root":"id", "elements":{...}}`.
- `operation: "update"` replaces entries in `elements`; a null entry removes it. Optional `root` changes the root. The complete resulting tree is validated before replacement.
- `operation: "clear"` dismisses the indicator, as does its X button. Closing invalidates pending presentation rollback; live binding refreshes cannot reopen it. A subsequent explicit set can show it again, while update requires an existing card.

Existing composition payloads remain accepted for compatibility, but their readable text is combined into a compact indicator rather than rendering cards or dashboards. Use `ide__show_ui` for a full interactive surface. Existing validation bounds (16 elements, four levels, 12 KB JSON, 180 characters per string) remain unchanged; there is no new emoji-only or short-label restriction.

Optional `{"$ide":"running_tasks"}` and `{"$ide":"running_sessions"}` bindings resolve from observable IDE state as it changes, without polling. `running_tasks` counts running tasks in loaded project boards. Other values are agent-supplied snapshots.

```json
{"spec":{"root":"status","elements":{"status":{"type":"Text","props":{"text":"Checking the latest build."}}}}}
```

The indicator follows the sprite, chooses an available side and clamps to the display using its actual size. Status remains separate from retained UI/image entry bubbles, music and speech. Pet-owned panels are excluded/hidden during capture and ignore mouse input during desktop actions.

## Pet mute and settings

The phone button starts or ends a voice call. The mute button controls both the pet microphone and speaker, even while idle. It stops current speech and cues, discards queued announcements, and stays in effect across calls and app launches. Active calls stay connected. Captions, text chat, and report delivery continue while muted.

Pet & Voice Settings opens in its own resizable macOS window. In the **Voice** tab, **Choose Speech Voice** offers Apple voices, installed neural models, and speech models from the signed-in Flowcy account. **Manage Voices** opens this chooser directly. The selected voice speaks custom-agent replies and notifications outside calls. A live Codex Realtime call speaks its own replies and notifications using its separate call voice. Flowcy previews and speech use the account allowance.

The General Agent tab has an independent **Notification Model** for completed-work summaries and notification translations. Apple Intelligence is the default for new and existing preferences. The menu also includes Claude Code, Codex, enabled ACP clients, and installed local chat models (MLX / GGUF). Local notification requests are tool-free and use the managed inference lifecycle; a busy local model preserves the original event rather than interrupting ongoing work. Unavailable models or failed generation preserve the original notification text. During voice calls, the active voice assistant still receives the original result and announces it.

### CI failure announcements

For monitored projects, newly observed GitHub Actions failures use the existing pet notification flow. The announcement names the project and failing workflows supplied by the CI response, without guessing a cause. The pet's **View CI Run** action and the desktop notification open the failing run; the mobile notification retains its URL. Global notification settings, pet proactive mode, and mute apply. Persistent per-project event history suppresses repeated polls, relaunches, and revisits to the same failed run while allowing other workflows and later run attempts on the same commit to announce separately. Automatic CI fix threads retain their separate per-commit deduplication.
