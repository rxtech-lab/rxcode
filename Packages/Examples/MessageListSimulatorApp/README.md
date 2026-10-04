# MessageList Simulator App

Small iOS host app for manually testing `MessageList` in Simulator.

`MessageList` now ships in RxAgentSDK's `AgentMessageListUI` module, so this
app links the SDK rather than a local package.

Open:

```bash
open Packages/Examples/MessageListSimulatorApp/MessageListSimulatorApp.xcodeproj
```

Then select the `MessageListSimulatorApp` scheme and an iOS Simulator.

Command-line build example:

```bash
xcodebuild build \
  -project Packages/Examples/MessageListSimulatorApp/MessageListSimulatorApp.xcodeproj \
  -scheme MessageListSimulatorApp \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=26.0'
```

