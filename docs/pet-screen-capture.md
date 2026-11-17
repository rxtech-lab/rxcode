# Desktop pet screen photos

Ask the pet to look at its screen, another monitor, or a visible application window. The pet uses its own display by default. For another monitor it walks across the desktop before taking the photo. For a window it walks above the window where space permits, raises a camera, and captures that window independently of other windows. At the top edge of a display, its pose stays within the visible desktop. The pet panel and its child overlays are hidden during capture.

Screen Recording access is managed in **Pet & Voice Settings → Desktop & Reports → Screen Recording Access**. macOS owns the permission prompt; after a denial, use the System Settings button and retry. macOS may require reopening the app. Authorized photos do not add a confirmation prompt. There is no background capture or recording stream.

On a user-requested capture, a negative `CGPreflightScreenCaptureAccess` check invokes `CGRequestScreenCaptureAccess`; its return value is retained for diagnostics. macOS prompts only for an undetermined decision, and does not re-prompt a previously denied process. Capture then checks ScreenCaptureKit even when preflight still reports false, so a stale advisory check does not prevent the actual API from diagnosing the attempt. A native permission error opens a dedicated recovery alert whose **Open System Settings** action targets the Screen Recording privacy pane, rather than the pet's own settings. Other capture errors retain their native domain and code and are not mislabeled as permission failures.

The app includes `NSScreenCaptureUsageDescription`, following [Apple's ScreenCaptureKit setup guidance](https://developer.apple.com/documentation/screencapturekit). This purpose string describes the request; it does not grant access. The existing unsandboxed macOS target needs user authorization, not a made-up screen-capture entitlement. The persistent-content-capture entitlement is intended for VNC-style persistent access and is not used for one-shot photos.

If System Settings already lists RxCode as enabled, fully quit and reopen the same app copy. Check **App Requesting Access** in pet settings: the bundle ID, path and process identify the requester. An Xcode Debug app under DerivedData and an installed copy can have different signing requirements or identities; granting an installed copy is not proof that the running build has access. The inspected development build uses bundle ID `com.rxlab.RxCode`, team `P9KK452K8P`, and an Apple Development signing requirement. This inspection does not establish the live TCC decision. No TCC database edits or resets are performed by this feature.

The shared IDE tools are `ide__pet_list_capture_targets` and `ide__pet_capture`. Listing reports display IDs, names, AppKit bounds and the pet's current display; with permission it also reports visible window IDs, application names and titles. Capture accepts no target, `display_id`, `window_id`, or `window_query`. Ambiguous queries return candidates for a concise selection. Minimized, closed, or disconnected targets require a retry; they never silently fall back to another target.

The result contains a JPEG image block, capped at 2560 pixels on its longest edge. MCP clients receive that image directly; the local harness receives a real image attachment. The selected model must support vision to inspect it. Photos remain in the conversation's normal tool-result flow; this feature does not write screenshot files or upload them to a separate service.

Capture results explicitly report `structuredContent.status` and `image_available`. A capture without an image, including a target-selection response, is not a successful photo: it returns `isError: true`, `image_available: false`, and explicit instructions not to invent screen contents or reuse an earlier photo. Error results cannot carry image blocks through the capture validator or local harness. Realtime tool activity preserves nested MCP error status instead of marking every completion as successful. These contracts and session instructions reduce false vision claims; they do not by themselves verify a live model's response or guarantee that a model follows instructions.

Movement uses AppKit points and display IDs; screenshot sizing uses the capture filter's pixel scale. Window coordinates are converted from Quartz's primary-display top-left origin. Window geometry and display availability are checked again after arrival and before capture. New captures supersede earlier ones; interruption, stopping voice, hiding the pet, and dragging cancel capture. A superseding request waits for the previous request to restore hidden panels.

## Device verification

The unit tests cover IDs, coordinate conversion, destination placement, tool discovery for Claude Code/Codex/ACP/local agents, and local image delivery. They do not establish real Screen Recording permission behavior, screenshot contents, or visible animation quality.

To verify those behaviors on a running desktop build:

1. Deny Screen Recording access, request a photo, and verify the native permission flow and recovery link. Grant access and retry; subsequent photos should not add app confirmation prompts.
2. Put the pet on a secondary monitor and ask what is on its screen. Verify the returned image and answer concern that monitor, with no pet/caption/tool artifacts.
3. Ask for a named monitor to the left, right, above, and below the primary display. Include mixed Retina scaling and negative offsets. Verify visible walking, arrival before the camera pose, and the selected display's contents.
4. Request a particular app window, including two windows with similar titles. Verify selection when ambiguous, placement above the selected window when space permits, a visible camera pose, and an image of only that window, even if other windows overlap it.
5. Move, minimize, close, or move the target window to another display during travel; unplug a target monitor. Verify retry/availability errors or re-positioning without photographing the wrong target.
6. Interrupt, drag, hide the pet, stop voice, or issue another photo request during travel/pose/capture. Verify cancellation, panel restoration, no stale answer, and that only the latest request completes.
7. Exercise both realtime voice and the pipeline/general-agent conversation. Verify the assistant interprets the image rather than merely announcing that a photo was taken.
