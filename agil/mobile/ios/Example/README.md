# AgilFrame iOS example

SwiftUI demo app for `AgilCallsSDK` (the package one directory up). It opens a
hosted `/embed.html` call, forwards events to a small log, and sends
mute/camera/chat/theme/leave commands through the native bridge.

## Run the AgilFrame server

From the repository root:

```bash
npm run seed
npm start
# server: http://localhost:8787 (see agil/core/docs/api.md)
```

## Generate/open the Xcode project

Requires macOS, Xcode 15+, and an iOS 14.3+ simulator/device.

Option A — XcodeGen:

```bash
cd agil/mobile/ios/Example
xcodegen generate
open AgilCallsExample.xcodeproj
```

Option B — manual Xcode project:

1. Xcode → File → New → Project → iOS App (SwiftUI, iOS 14.3+).
2. Delete the generated `ContentView.swift`/`App.swift` and add the files from
   `Sources/`.
3. File → Add Package Dependencies → Add Local… → select `agil/mobile/ios`.
4. Add `NSCameraUsageDescription` and `NSMicrophoneUsageDescription` to the app
   target's `Info.plist` (see this directory's `Info.plist`).
5. Keep the localhost ATS exception only for development.

Run on a simulator, enter `http://localhost:8787`, room `demo` (seeded by
`npm run seed`), optionally a join token, and press **Open call**.

## What to look for

| Action | Expected |
|---|---|
| Open call without a token | The hosted widget shows its own join screen |
| Join with a valid token | Widget joins; the app logs `ready`/`joined` |
| Top bar buttons | Native `agil:action` commands toggle mic/camera/chat; theme switches |
| Close call | Sends `agil:action leave` and dismisses the call screen |
| Camera/mic permission denied | `permission-denied` failure; the WebView cannot capture |

The example never logs tokens. In production, mint join tokens on your backend
(`POST /v1/rooms/:roomId/join`) and never ship an admin API key in the app.
