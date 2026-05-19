# RxCodeMobile — Xcode setup

This directory holds the source files for the **iOS / iPadOS companion app**
and its Notification Service Extension. Adding new app + extension targets
safely is best done in the Xcode UI rather than by editing
`project.pbxproj` by hand. This file walks you through the steps once.

## Prerequisites

- Xcode 26+
- Apple Developer account
- The desktop app (`RxCode` scheme) already builds cleanly.

## Step 1 — Add the iOS app target

1. Open `RxCode.xcodeproj` in Xcode.
2. File → New → Target… → **App** (iOS).
3. Product Name: **`RxCodeMobile`**
4. Bundle Identifier: **`com.idealapp.RxCode.Mobile`**
5. Interface: SwiftUI · Language: Swift · Storage: None · Tests: optional
6. Deployment target: **iOS 26.0** (or whatever you confirmed in the plan)
7. After creation, **delete** the generated `ContentView.swift`,
   `RxCodeMobileApp.swift` and `Assets.xcassets` stub — we ship our own.

## Step 2 — Add the source files

In Project Navigator, right-click the new `RxCodeMobile` group →
**Add Files to "RxCode"…** and select:

```
RxCodeMobile/RxCodeMobileApp.swift
RxCodeMobile/AppDelegate.swift
RxCodeMobile/Info.plist          (replace the auto-generated one)
RxCodeMobile/RxCodeMobile.entitlements
RxCodeMobile/State/MobileAppState.swift
RxCodeMobile/Views/RootView.swift
RxCodeMobile/Views/OnboardingView.swift
RxCodeMobile/Views/QRScannerView.swift
RxCodeMobile/Views/ProjectsSidebar.swift
RxCodeMobile/Views/SessionsList.swift
RxCodeMobile/Views/MobileChatView.swift
RxCodeMobile/Views/MobileMessageBubble.swift
RxCodeMobile/Views/MobileInputBar.swift
RxCodeMobile/Views/PermissionApprovalSheet.swift
RxCodeMobile/Views/MobileSettingsView.swift
```

Make sure **"Add to targets"** has **only** `RxCodeMobile` checked, not
`RxCode` (macOS).

## Step 3 — Link Swift package products

`RxCodeMobile` → **General** → **Frameworks, Libraries, and Embedded
Content** → **+** → add:

- `RxCodeCore`
- `RxCodeChatKit`
- `RxCodeSync`

The local `Packages` reference should already be visible — these are the
same products the macOS app links.

## Step 4 — Add the Notification Service Extension

1. File → New → Target… → **Notification Service Extension**.
2. Product Name: **`RxCodeMobileNotificationService`**
3. Bundle Identifier: **`com.idealapp.RxCode.Mobile.NotificationService`**
   (must be `<app-id>.<extension-suffix>` for iOS to load it)
4. Embed in Application: **`RxCodeMobile`**
5. After creation, delete the auto-generated `NotificationService.swift` and
   add ours from `RxCodeMobileNotificationService/`. Same for the Info.plist
   and entitlements files. Link `RxCodeSync` to this target as well (no
   need for `RxCodeCore` / `RxCodeChatKit`).

## Step 5 — Configure capabilities

For **`RxCodeMobile`**:

- Signing & Capabilities → **+ Capability** → **Push Notifications**
- **+ Capability** → **Background Modes** — check
  *Remote notifications* and *Background processing*
- **+ Capability** → **Keychain Sharing** — add group
  `com.idealapp.RxCode.Mobile.shared` (Xcode prepends the team prefix
  at sign time)

For **`RxCodeMobileNotificationService`**:

- **+ Capability** → **Keychain Sharing** — add the same group
  `com.idealapp.RxCode.Mobile.shared`

The Keychain group lets the extension read the device's long-term
Curve25519 private key written by the main app, so it can decrypt the
`enc` blob carried in incoming APNs payloads.

## Step 6 — APNs key on the relay server

Configure the relay server with an APNs auth key (`.p8`) for the topic
`com.idealapp.RxCode.Mobile`. See `relay-server/README.md`.

## Step 7 — First run

1. Build + run `RxCode` (macOS) on your Mac.
2. Run the relay: `cd relay-server && go run . -addr :8787 …` (see relay
   README for APNs flags).
3. In the Mac app, **Settings → Mobile**, set the relay URL (e.g.
   `ws://your-mac.local:8787` for LAN dev), then tap **Pair new device**
   to show the QR.
4. Build + run `RxCodeMobile` on a device or iPad simulator. On the
   onboarding screen, tap **Scan QR** and point at the Mac's screen.
5. The Mac shows a confirmation modal — tap **Accept** — and the mobile
   transitions to the root split view.
6. Open a project on Mac and start a session — the mobile mirrors it.

## Known limitations (v1)

- The relay drops envelopes on offline by design; mobile re-syncs via
  `requestSnapshot` on every reconnect.
- The main app currently only fans notifications out over the live
  WebSocket channel. The desktop-side APNs `POST /push` integration that
  packages encrypted alerts and submits them to the relay is wired into
  the protocol and NSE but the desktop submitter is left as a follow-up
  patch — see `MobileSyncService.broadcastNotification`.
- The desktop `MobileSyncService` listens for inbound `userMessage` /
  `newSessionRequest` / `requestSnapshot` events but the AppState bridge
  that actually routes those into `ClaudeService.send()` and emits
  `snapshot` payloads is left as a follow-up patch — the
  `NotificationCenter` posts (`.mobileSync*`) are the seam to wire up.
- iOS app's snapshot rendering covers projects, sessions, and chat
  messages, but session-level streaming-state mirroring (token usage,
  status chips) is not surfaced yet — those land via `sessionUpdate`
  payloads but the iOS UI doesn't display them.
