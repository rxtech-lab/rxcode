# Attachment Auto-Preview Settings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add four independently toggleable settings (URL, file path, image, long text) that control whether pasted content is auto-converted to an attachment preview chip in the chat input.

**Architecture:** `AttachmentAutoPreviewSettings` struct lives in `RxCodeCore`. `AppState` owns and persists it to UserDefaults. The existing `startBridgeObservation` loop pushes the value from `AppState` into each `ChatBridge`. `InputBarView` reads from `chatBridge.autoPreviewSettings` and skips attachment creation for disabled types.

**Tech Stack:** Swift, SwiftUI (`@Observable`, `@Bindable`), `UserDefaults` + `JSONEncoder`/`JSONDecoder`, `NSPasteboard`

---

## File Map

| File | Action | Responsibility |
|---|---|---|
| `Packages/Sources/RxCodeCore/Models/AttachmentAutoPreviewSettings.swift` | Create | Settings model — four Bool fields, Codable |
| `Packages/Sources/RxCodeChatKit/ChatBridge.swift` | Modify | Add `autoPreviewSettings` property for InputBarView to read |
| `RxCode/App/AppState.swift` | Modify | Add `autoPreviewSettings` property with UserDefaults persistence |
| `RxCode/App/AppState.swift` (`startBridgeObservation`) | Modify | Push settings into bridge inside observation loop |
| `Packages/Sources/RxCodeChatKit/InputBarView.swift` | Modify | Guard each attachment-creation path with the matching setting |
| `RxCode/Views/SettingsView.swift` | Modify | Add four Toggles in a new section inside `ChatSettingsTab` |

---

## Task 1: Create AttachmentAutoPreviewSettings model

**Files:**
- Create: `Packages/Sources/RxCodeCore/Models/AttachmentAutoPreviewSettings.swift`

- [ ] **Step 1: Create the file**

```swift
// Packages/Sources/RxCodeCore/Models/AttachmentAutoPreviewSettings.swift
import Foundation

public struct AttachmentAutoPreviewSettings: Codable, Sendable {
    public var url: Bool = true
    public var filePath: Bool = true
    public var image: Bool = true
    public var longText: Bool = true

    public init() {}
}
```

- [ ] **Step 2: Build RxCodeCore to verify**

```bash
cd /Users/jmlee/workspace/RxCode/Packages && swift build --target RxCodeCore 2>&1 | tail -5
```

Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Packages/Sources/RxCodeCore/Models/AttachmentAutoPreviewSettings.swift
git commit -m "feat(core): add AttachmentAutoPreviewSettings model"
```

---

## Task 2: Add autoPreviewSettings to ChatBridge

**Files:**
- Modify: `Packages/Sources/RxCodeChatKit/ChatBridge.swift`

- [ ] **Step 1: Add property to ChatBridge**

Open `Packages/Sources/RxCodeChatKit/ChatBridge.swift`. After the last `public var` in the "Streaming State" section (after `sessionStats`), add:

```swift
public var autoPreviewSettings: AttachmentAutoPreviewSettings = AttachmentAutoPreviewSettings()
```

The section will look like:
```swift
// MARK: - Streaming State (pushed by AppState)

public var messages: [ChatMessage] = []
public var isStreaming: Bool = false
public var isThinking: Bool = false
public var streamingStartDate: Date?
public var lastTurnContextUsedPercentage: Double?
public var modelDisplayName: String = ""
public var sessionStats: ChatSessionStats = ChatSessionStats()
public var autoPreviewSettings: AttachmentAutoPreviewSettings = AttachmentAutoPreviewSettings()
```

- [ ] **Step 2: Build RxCodeChatKit to verify**

```bash
cd /Users/jmlee/workspace/RxCode/Packages && swift build --target RxCodeChatKit 2>&1 | tail -5
```

Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Packages/Sources/RxCodeChatKit/ChatBridge.swift
git commit -m "feat(chatkit): add autoPreviewSettings to ChatBridge"
```

---

## Task 3: Add autoPreviewSettings to AppState

**Files:**
- Modify: `RxCode/App/AppState.swift`

- [ ] **Step 1: Add property to AppState**

Open `RxCode/App/AppState.swift`. After the `focusMode` property (around line 199), add a new MARK and property:

```swift
// MARK: - Attachment Auto-Preview Settings

var autoPreviewSettings: AttachmentAutoPreviewSettings = {
    guard let data = UserDefaults.standard.data(forKey: "attachmentAutoPreviewSettings"),
          let settings = try? JSONDecoder().decode(AttachmentAutoPreviewSettings.self, from: data) else {
        return AttachmentAutoPreviewSettings()
    }
    return settings
}() {
    didSet {
        if let data = try? JSONEncoder().encode(autoPreviewSettings) {
            UserDefaults.standard.set(data, forKey: "attachmentAutoPreviewSettings")
        }
    }
}
```

- [ ] **Step 2: Build to verify**

```bash
xcodebuild -project /Users/jmlee/workspace/RxCode/RxCode.xcodeproj -scheme RxCode -configuration Debug build 2>&1 | grep -E "error:|Build complete|BUILD SUCCEEDED|BUILD FAILED" | tail -5
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add RxCode/App/AppState.swift
git commit -m "feat(app): add autoPreviewSettings to AppState with UserDefaults persistence"
```

---

## Task 4: Sync settings into ChatBridge via observation loop

**Files:**
- Modify: `RxCode/App/AppState.swift` (the `startBridgeObservation` function, around line 489)

- [ ] **Step 1: Add sync line inside withObservationTracking**

Open `RxCode/App/AppState.swift`. In `startBridgeObservation`, inside the `withObservationTracking` closure, add one line after `bridge.sessionStats = ...`:

```swift
bridge.autoPreviewSettings = self.autoPreviewSettings
```

The full `withObservationTracking` block becomes:
```swift
withObservationTracking {
    let state = streamState(in: window)
    bridge.messages = state.messages
    bridge.isStreaming = state.isStreaming
    bridge.isThinking = state.isThinking
    bridge.streamingStartDate = state.streamingStartDate
    bridge.lastTurnContextUsedPercentage = state.lastTurnContextUsedPercentage
    bridge.modelDisplayName = modelDisplayName(for: window.sessionModel ?? selectedModel, in: window)
    bridge.sessionStats = ChatSessionStats(
        costUsd: state.costUsd,
        inputTokens: state.inputTokens,
        outputTokens: state.outputTokens,
        cacheCreationTokens: state.cacheCreationTokens,
        cacheReadTokens: state.cacheReadTokens,
        durationMs: state.durationMs,
        turns: state.turns
    )
    bridge.autoPreviewSettings = self.autoPreviewSettings
} onChange: {
    Task { @MainActor in observe() }
}
```

- [ ] **Step 2: Build to verify**

```bash
xcodebuild -project /Users/jmlee/workspace/RxCode/RxCode.xcodeproj -scheme RxCode -configuration Debug build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | tail -5
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add RxCode/App/AppState.swift
git commit -m "feat(app): sync autoPreviewSettings into ChatBridge via observation loop"
```

---

## Task 5: Guard attachment creation in InputBarView

**Files:**
- Modify: `Packages/Sources/RxCodeChatKit/InputBarView.swift`

### Step-by-step changes

The goal: before each attachment type is created, check the corresponding flag in `chatBridge.autoPreviewSettings`. If false, skip creation and let the content remain as plain text.

- [ ] **Step 1: Guard image attachment in handlePasteKey**

In `handlePasteKey` (around line 307), change:

```swift
if let attachment = imageAttachmentFromPasteboard(pb) {
    windowState.addAttachment(attachment)
    return .handled
}
```

to:

```swift
if imageAttachmentFromPasteboard(pb) != nil {
    if chatBridge.autoPreviewSettings.image,
       let attachment = imageAttachmentFromPasteboard(pb) {
        windowState.addAttachment(attachment)
    }
    return .handled
}
```

Rationale: if there is image data on the pasteboard, always return `.handled` (to prevent NSTextField from pasting raw image bytes). The `addAttachment` call is skipped when image preview is disabled, making the paste a no-op for input content.

- [ ] **Step 2: Guard file-URL attachment in handlePasteKey**

In `handlePasteKey`, change:

```swift
if let url = (pb.readObjects(forClasses: [NSURL.self]) as? [URL])?.first(where: \.isFileURL) {
    if let attachment = AttachmentFactory.fromFileURL(url) {
        windowState.addAttachment(attachment)
    } else {
        insertAtCursor(url.path)
    }
    return .handled
}
```

to:

```swift
if let url = (pb.readObjects(forClasses: [NSURL.self]) as? [URL])?.first(where: \.isFileURL) {
    if chatBridge.autoPreviewSettings.filePath,
       let attachment = AttachmentFactory.fromFileURL(url) {
        windowState.addAttachment(attachment)
    } else {
        insertAtCursor(url.path)
    }
    return .handled
}
```

Rationale: when `filePath` is disabled, always fall through to `insertAtCursor` regardless of whether the factory could create an attachment.

- [ ] **Step 3: Guard long text in handlePasteKey**

In `handlePasteKey`, change:

```swift
if text.count >= AttachmentFactory.longTextThreshold {
    windowState.addAttachment(AttachmentFactory.fromLongText(text))
    return .handled
}
```

to:

```swift
if chatBridge.autoPreviewSettings.longText,
   text.count >= AttachmentFactory.longTextThreshold {
    windowState.addAttachment(AttachmentFactory.fromLongText(text))
    return .handled
}
```

- [ ] **Step 4: Guard URL and file-path detection in attachmentFromPastedText**

In `attachmentFromPastedText` (around line 341), change:

```swift
private func attachmentFromPastedText(_ text: String) -> Attachment? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return nil }
    if let attachment = attachmentFromPathText(trimmed) {
        return attachment
    }
    if !trimmed.contains(" "), !trimmed.contains("\n"),
       let url = URL(string: trimmed),
       let scheme = url.scheme, ["http", "https"].contains(scheme),
       url.host != nil {
        return AttachmentFactory.fromURL(url)
    }
    return nil
}
```

to:

```swift
private func attachmentFromPastedText(_ text: String) -> Attachment? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return nil }
    if chatBridge.autoPreviewSettings.filePath,
       let attachment = attachmentFromPathText(trimmed) {
        return attachment
    }
    if chatBridge.autoPreviewSettings.url,
       !trimmed.contains(" "), !trimmed.contains("\n"),
       let url = URL(string: trimmed),
       let scheme = url.scheme, ["http", "https"].contains(scheme),
       url.host != nil {
        return AttachmentFactory.fromURL(url)
    }
    return nil
}
```

- [ ] **Step 5: Guard long text in handleInputTextChange**

In `handleInputTextChange` (around line 203), change:

```swift
if inserted.count >= AttachmentFactory.longTextThreshold {
    windowState.addAttachment(AttachmentFactory.fromLongText(inserted))
    windowState.inputText = oldValue
    return
}
```

to:

```swift
if chatBridge.autoPreviewSettings.longText,
   inserted.count >= AttachmentFactory.longTextThreshold {
    windowState.addAttachment(AttachmentFactory.fromLongText(inserted))
    windowState.inputText = oldValue
    return
}
```

- [ ] **Step 6: Build RxCodeChatKit to verify**

```bash
cd /Users/jmlee/workspace/RxCode/Packages && swift build --target RxCodeChatKit 2>&1 | tail -5
```

Expected: `Build complete!`

- [ ] **Step 7: Commit**

```bash
git add Packages/Sources/RxCodeChatKit/InputBarView.swift
git commit -m "feat(chatkit): guard attachment creation with autoPreviewSettings flags"
```

---

## Task 6: Add settings UI in ChatSettingsTab

**Files:**
- Modify: `RxCode/Views/SettingsView.swift`

- [ ] **Step 1: Add autoPreviewSection helper**

Open `RxCode/Views/SettingsView.swift`. Inside `ChatSettingsTab`, after `focusModeSection` (around line 443, before `effortDisplayName`), add a new helper:

```swift
// MARK: - Auto-Preview Attachments Section

private var autoPreviewSection: some View {
    @Bindable var appState = appState
    return VStack(alignment: .leading, spacing: 12) {
        Text("Auto-preview Attachments")
            .font(.system(size: ClaudeTheme.size(13), weight: .semibold))

        Text("When enabled, pasting the following content types automatically creates an attachment preview. When disabled, the content is inserted as plain text.")
            .font(.system(size: ClaudeTheme.size(11)))
            .foregroundStyle(.secondary)

        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $appState.autoPreviewSettings.url) {
                Text("URL links")
            }
            .toggleStyle(.switch)
            .fixedSize()

            Toggle(isOn: $appState.autoPreviewSettings.filePath) {
                Text("File paths")
            }
            .toggleStyle(.switch)
            .fixedSize()

            Toggle(isOn: $appState.autoPreviewSettings.image) {
                Text("Images")
            }
            .toggleStyle(.switch)
            .fixedSize()

            Toggle(isOn: $appState.autoPreviewSettings.longText) {
                Text("Long text (200+ characters)")
            }
            .toggleStyle(.switch)
            .fixedSize()
        }
    }
}
```

- [ ] **Step 2: Add section to ChatSettingsTab body**

In `ChatSettingsTab.body`, after `focusModeSection`, add a `Divider` and `autoPreviewSection`:

```swift
var body: some View {
    @Bindable var appState = appState
    ScrollView {
        VStack(alignment: .leading, spacing: 24) {
            modelSection(selectedModel: $appState.selectedModel)
            Divider()
            permissionModeSection
            Divider()
            effortSection
            Divider()
            focusModeSection
            Divider()
            autoPreviewSection
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
```

- [ ] **Step 3: Build to verify**

```bash
xcodebuild -project /Users/jmlee/workspace/RxCode/RxCode.xcodeproj -scheme RxCode -configuration Debug build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | tail -5
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 4: Commit**

```bash
git add RxCode/Views/SettingsView.swift
git commit -m "feat(settings): add auto-preview attachment toggles in Message tab"
```

---

## Verification Checklist

After all tasks are complete, verify the following manually:

1. Open Settings → Message tab → "Auto-preview Attachments" section is visible with 4 toggles
2. All 4 toggles default to ON (first launch or after clearing UserDefaults)
3. **URL test:** Disable "URL links" toggle. Paste `https://example.com` into chat input → stays as plain text
4. **File path test:** Disable "File paths" toggle. Paste `/Users/yourname/Desktop/file.txt` → stays as plain text
5. **Image test:** Disable "Images" toggle. Copy an image and paste into chat → no attachment chip appears, paste is a no-op
6. **Long text test:** Disable "Long text" toggle. Paste 200+ characters → stays as inline text in input
7. Re-enable each toggle → behavior reverts to attachment preview
8. Quit and relaunch app → toggle states are preserved from UserDefaults
